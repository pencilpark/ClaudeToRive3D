# Blender to Rive 3D Export

> **Quick Start:** Run Blender MCP export script → Copy generated `.luau` files to Rive

## ⚠️ IMPORTANT: Read Before Exporting

1. **Static models DON'T need Mesh3DUtil** - All math can be inline
2. **Use category index `c=1`** instead of RGB colors - 60% smaller files
3. **Sort faces by avgZ** at export time for painter's algorithm
4. **Extract only used vertices per part** - Prevents typecheck errors
5. **Blender Z-up**: Yaw rotates in XY plane, NOT around Y axis
6. **Factorize skinning data** - Use index references to reduce file size by ~40%
7. **Use anti-flickering method** - table.sort + index tiebreaker + depthBias
8. **Use depthBias per Part file** - Large offsets (0, 10, 20) when parts are separate objects
9. **Wall-mounted surfaces (screens, panels)** - Hardcode in Node Script + depthBias to force draw order

## Project Structure (Generic Template)

```
YOUR_MODEL/
├── Model.luau               # Main Node Script (rendering + Property Group)
├── ModelPartAData.luau      # Part A: ~1900 faces max + skeleton + animations
├── ModelPartBData.luau      # Part B: ~1900 faces max
├── ModelPartCData.luau      # Part C: remaining faces (optional)
├── Mesh3DUtil.luau          # 3D math utilities (for animated models)
├── SkeletalAnimUtil.luau    # Skeletal animation system
├── blender_to_rive.py       # Standalone export script
├── prompt.md                # AI agent prompt for Claude Code
└── CLAUDE.md                # This documentation
```

---

---

## Critical Lessons Learned

### 1. File Size Limits
- **Maximum ~1900 polygons** per Luau script file
- **Maximum ~2500 vertices** per Luau script file
- Using category index `c` instead of RGB colors reduces data size significantly
- **Factorized skinning** reduces file size by ~40% for animated models

### 2. Face Data Format (Compact)
```luau
-- ❌ WRONG: Verbose RGB colors
{ verts = { 1, 2, 3 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Category index (much smaller)
{ verts = { 1, 2, 3 }, c = 1 }
```

### 3. Skinning Data Format (Factorized)
```luau
-- ❌ WRONG: Repeated full entries (huge files)
ModelData.skinning = {
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Repeated 100s of times!
  {j = {6, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
}

-- ✅ CORRECT: Factorized with patterns table + index array
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Root
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Head
  [2] = {j = {2, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Shoulder.L
  -- ... one entry per bone (11 max)
}

ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, 2, 9, 9, ...}  -- Just bone indices!
```

**File size reduction:**
| Before | After | Savings |
|--------|-------|---------|
| 228 KB | 139 KB | **-39%** |
| 102 KB | 65 KB | **-36%** |

### 4. Anti-Flickering System (CRITICAL - 3 Techniques Combined)

**Problem:** Faces with nearly equal depth cause z-fighting flickering during rotation.

**Solution:** Combine 3 techniques for complete anti-flickering:

#### 4.1 ProjectedFace Type with Index
```luau
-- Include index field for stable sorting
export type ProjectedFace = {
    path: Path,
    depth: number,
    color: Color,
    index: number,  -- Original insertion index for stable sort tiebreaker
}
```

#### 4.2 depthBias Parameter on processFaces
```luau
-- Add optional depthBias parameter to processFaces function
local function processFaces(
    self: Model3D,
    vertices: { { x: number, y: number, z: number } },
    faces: { { verts: { number }, c: number } },
    -- ... other parameters ...
    depthBias: number?  -- Optional: shifts depth for sort order without moving geometry
)
    local bias = depthBias or 0
    -- ...
    -- Apply bias when calculating depth:
    local avgZ = (sumZ / #transformed) + bias
    -- ...
    -- Insert with index for stable sorting:
    table.insert(self.projectedFaces, {
        path = facePath,
        depth = avgZ,
        color = litColor,
        index = #self.projectedFaces + 1,  -- Stable sort index
    })
end
```

**depthBias has two distinct use cases:**

**Case A — Parts represent separate objects** (e.g., robot body / robot head):
```luau
-- Each part has non-overlapping geometry → use large bias to separate
processFaces(self, vertsA, facesA, ..., 0)   -- Part A: reference
processFaces(self, vertsB, facesB, ..., 10)  -- Part B: offset 10
processFaces(self, vertsC, facesC, ..., 20)  -- Part C: offset 20
```

**Case B — Parts are Z-sorted slices of mixed objects** (e.g., room with walls, bed, ceiling all sliced together):
```luau
-- Parts overlap in Z range → bias=0 to preserve true Z-ordering
processFaces(self, vertsA, facesA, ..., 0)   -- Part A: no bias
processFaces(self, vertsB, facesB, ..., 0)   -- Part B: no bias
processFaces(self, vertsC, facesC, ..., 0)   -- Part C: no bias
```

**How to decide:** If Part files are split by sorting ALL faces by avgZ and taking slices → use bias=0. If Part files correspond to distinct mesh objects → use large bias (10, 20).

#### 4.3 Stable Sort with table.sort and Index Tiebreaker
```luau
-- Sort faces by depth with stable tiebreaker
local Z_EPSILON = 0.001  -- Threshold for using index as tiebreaker
local faces = self.projectedFaces

table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local depthDiff = a.depth - b.depth
    if math.abs(depthDiff) < Z_EPSILON then
        -- Depths essentially equal: use stable index ordering
        return a.index < b.index
    end
    -- Sort back to front (smaller depth = further from camera = drawn first)
    return a.depth < b.depth
end)
```

#### Recommended Values (Tested and Validated)
| Parameter | Value | Effect |
|-----------|-------|--------|
| Z_EPSILON | 0.001 | Threshold for index tiebreaker |
| depthBias (separate objects) | 0, 10, 20 | Large separation between distinct parts |
| depthBias (Z-sliced parts) | 0, 0, 0 | No bias — preserves true Z-ordering |
| depthBias (wall overlays) | 99, 100 | Forces overlay to always draw on top |
| faceExpansion | 0.05 | Visual gap between faces |
| brightness | 50 | Base lighting level (%) |

### 5. Coordinate System (Blender Z-up to Rive)
**Blender uses Z-up, Rive screen is X-right, Y-down, Z-into-screen.**

Rotation mapping:
- `rotationY` (yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (pitch) → Tilt forward/backward
- `rotationZ` (roll) → Tilt left/right

```luau
-- Transform for Z-up Blender model
local function transformVertex(vx, vy, vz, ...)
  -- Yaw: rotate in XY plane (turntable around Blender Z axis)
  local rx = x * cosY - y * sinY
  local ry = x * sinY + y * cosY
  x, y = rx, ry
  -- Pitch: rotate in YZ plane (tilt forward/back)
  local ry2 = y * cosX - z * sinX
  local rz = y * sinX + z * cosX
  y, z = ry2, rz
  -- Roll: rotate in XY plane (screen-space tilt around camera Z axis)
  local rx2 = x * cosZ - y * sinZ
  local ry2b = x * sinZ + y * cosZ
  return rx2, ry2b, z
end
```

### 6. Mesh3DUtil - Optional for Static Models
**For static (non-animated) models, Mesh3DUtil is NOT required.**

Only require Mesh3DUtil if using:
- Matrix operations (mat4)
- Quaternion math
- Skeletal animation

### 7. Wall-Mounted Surfaces (Screens, Panels, Signs)

**Problem:** Flat surfaces on walls (TV screens, info panels, signs) cause Z-fighting with the wall behind them, regardless of geometric offset. Small offsets fail at rotation angles because projected Z-difference shrinks. Large offsets cause the surface to visually "detach" from the wall during rotation.

**Solution: Decouple visual position from sort order using `depthBias`.**

1. **Remove the surface from Blender** (delete the mesh)
2. **Re-export Part files** (without the surface)
3. **Hardcode the surface as vertices/faces directly in the Node Script** (`advance()`)
4. **Position close to wall** (1-2 normalized units offset — visually flush)
5. **Use large `depthBias`** (99-100) to force it to always draw IN FRONT of everything

```luau
-- Example: TV Screen hardcoded in Node Script
-- Wall at x≈-52.5. Screen at x=-51 (visually flush, 1.5 units from wall).
-- depthBias=100 forces screen to sort AFTER all wall faces at any angle.
local tvScreenVerts: { { x: number, y: number, z: number } } = {
    {x=-51, y=48.66, z=-8.82},
    {x=-51, y=83.91, z=-8.82},
    {x=-51, y=83.91, z=17.61},
    {x=-51, y=48.66, z=17.61},
}
local tvScreenFaces: { { verts: { number }, c: number } } = {
    {verts = {1, 2, 3}, c = 12},  -- 2 triangles = 1 rectangle
    {verts = {1, 3, 4}, c = 12},
}
-- Process with depthBias=100 (drawn last = in front)
processFaces(self, tvScreenVerts, tvScreenFaces, ..., 100)
```

**Why this works:** `depthBias` adds +100 to the depth used for sorting, but does NOT move the geometry. The screen is visually at x=-51 (flush with wall) but sorts as if it were 100 units closer to camera. No rotation angle can overcome a 100-unit depth advantage.

**When to use:** Any surface that must always render on top of the surface behind it, at all rotation angles. Typical examples:
- TV screens on walls
- Emissive borders/bezels around screens
- Wall-mounted info panels or signs
- Decals that must never flicker with the wall

**Layering multiple overlays:** Use incrementing bias values to control stacking order:
```luau
processFaces(self, borderVerts, borderFaces, ..., 99)   -- Border: behind screen
processFaces(self, screenVerts, screenFaces, ..., 100)   -- Screen: on top
```

---

## Export Workflow (Blender MCP)

### Step 1: Analyze Model
```python
obj = bpy.data.objects.get("ModelName")
# Check: vertex count, polygon count, materials
```

### Step 2: Normalize Coordinates
```python
# Center and scale to ~200 units
center = (min_coord + max_coord) / 2
scale_factor = 200 / max_dimension
normalized = (world_coord - center) * scale_factor
```

### Step 3: Categorize Materials
```python
# Map materials to category indices 1-N
material_categories = {mat.name: i + 1 for i, mat in enumerate(materials)}
```

### Step 4: Sort Faces by Depth
```python
# Sort by avgZ BEFORE splitting into files
all_faces.sort(key=lambda f: avg_z(f))
```

### Step 5: Fragment with Vertex Optimization
```python
# Each part gets ONLY its used vertices (remapped indices)
def extract_part_data(faces_slice, all_vertices):
    used_indices = set(vi for f in faces_slice for vi in f['verts'])
    index_map = {old: new+1 for new, old in enumerate(sorted(used_indices))}
    # Extract and remap...
```

### Step 6: Factorize Skinning (for animated models)
```python
# Create patterns table (one per bone)
patterns = {}
for i in range(bone_count):
    patterns[i] = {"j": [i, 0, 0, 0], "w": [1.0, 0.0, 0.0, 0.0]}

# Store just the bone index per vertex
skinning_index = [skin["j"][0] for skin in all_skinning]
```

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| Faces flickering | Z-fighting from coplanar faces | Use 3-technique anti-flickering: index + depthBias + table.sort |
| Flickering between Parts (separate objects) | Parts from different files compete | Use LARGE depthBias (10, 20) per part |
| Flickering between Parts (Z-sliced) | Parts overlap in Z range | Use depthBias=0 for all parts |
| Screen/panel flickers on wall | Coplanar surface competes with wall | Hardcode in Node Script + depthBias=100 (see section 7) |
| Screen "detaches" from wall | Geometric offset too large | Use small geometric offset + large depthBias instead |
| Objects behind terrain | Wrong depth sort direction | Use `depth < depth` for back-to-front |
| Model rotates wrong axis | Y-up vs Z-up confusion | Yaw rotates in XY plane for Z-up models |
| Faces disappear | Wrong backface culling | Check normal direction `nz < 0` |
| Colors all same | Not using category index | Use `c = index` format |
| File too large / typecheck error | Too many repeated skinning entries | Use factorized skinning format |
| Rotation doesn't work | rotationSpeed on wrong axis | Apply to Yaw (XY rotation) |
| Animation doesn't update | Missing markNeedsUpdate | Store context, call `context:markNeedsUpdate()` |

---

## Auto-Rotation Pattern (CRITICAL)

**Problem:** `rotationSpeed` does nothing without waking the render loop.

**Solution:** Store context and call `markNeedsUpdate()`:

```luau
export type Model3D = {
  context: Context?,  -- REQUIRED for auto-rotation
  -- ...
}

local function init(self: Model3D, context: Context): boolean
  self.context = context  -- Store reference
  return true
end

local function advance(self: Model3D, seconds: number): boolean
  if self.rotationSpeed ~= 0 then
    self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
    if self.context then
      self.context:markNeedsUpdate()  -- Wake render loop
    end
  end
  return true
end
```

---

## Skinning in Node Script (Factorized Format)

```luau
type SkinEntry = { j: { number }, w: { number } }

local function skinVertices(
    skeleton: SkelAnim.Skeleton,
    vertices: { { x: number, y: number, z: number } },
    skinningPatterns: { [number]: SkinEntry },
    skinningIndex: { number }
): { { x: number, y: number, z: number } }
    local result = {}

    for i, v in ipairs(vertices) do
        local skinIdx = skinningIndex[i]        -- Get bone index
        local skin = skinningPatterns[skinIdx]  -- Get pattern from table
        local sx, sy, sz = 0.0, 0.0, 0.0

        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1
            local weight = skin.w[k]
            if weight > 0 and jointIdx >= 1 then
                local skinMat = skeleton.skinMatrices[jointIdx]
                if skinMat then
                    local tx, ty, tz = M.mat4TransformPoint(skinMat, v.x, v.y, v.z)
                    sx = sx + tx * weight
                    sy = sy + ty * weight
                    sz = sz + tz * weight
                end
            end
        end
        table.insert(result, { x = sx, y = sy, z = sz })
    end
    return result
end

-- Usage in advance():
local skinPatterns = (PartAData :: any).skinningPatterns :: { [number]: SkinEntry }
local skinIndex = (PartAData :: any).skinningIndex :: { number }
self.skinnedVerts = skinVertices(skeleton, vertices, skinPatterns, skinIndex)
```

---

## Quick Checklist (Before Starting Export)

- [ ] Model analyzed (vertex/polygon count, materials)
- [ ] Coordinate system identified (Z-up = Blender default)
- [ ] Materials mapped to category indices
- [ ] Using `c=index` format (NOT RGB)
- [ ] Faces will be sorted by avgZ
- [ ] Each part will have only its used vertices
- [ ] Skinning data will be factorized (patterns + index)
- [ ] `context:markNeedsUpdate()` for auto-rotation/animation
- [ ] For Z-up: Yaw rotates in XY plane (cosY/sinY on x,y)
- [ ] **Anti-flickering implemented:**
  - [ ] ProjectedFace type has `index` field
  - [ ] processFaces has optional `depthBias` parameter
  - [ ] depthBias: 0 for Z-sliced parts, 0/10/20 for object-based parts
  - [ ] table.sort with typed comparator + Z_EPSILON (0.001) + index tiebreaker
  - [ ] faceExpansion = 0.05, brightness = 50
- [ ] **Wall-mounted surfaces** (if any screens, panels, signs):
  - [ ] Removed from Blender, hardcoded in Node Script
  - [ ] Positioned close to wall (1-2 normalized units)
  - [ ] depthBias=99/100 to force draw order

---

## Performance Notes

- **4544 faces** renders smoothly with table.sort
- table.sort with typed comparator works well for <10k faces
- Each frame: transform → cull → light → project → sort → draw
- Paths created in `advance()`, only drawn in `draw()`
- Factorized skinning has minimal runtime overhead (one table lookup per vertex)
- Index tiebreaker ensures stable sort order between frames
- depthBias on processFaces decouples visual position from sort order (zero runtime cost)
- Wall-mounted overlays with depthBias=100 never flicker regardless of rotation angle

---

## Default Values (Optimized)

```luau
-- Recommended defaults for new 3D models
rotationSpeed = 10,       -- Visible rotation for testing
brightness = 50,          -- Base lighting 50%
faceExpansion = 0.05,     -- Visual gap between faces
backfaceCulling = true,   -- Cull back-facing polygons
```

## Workflow Orchestration

### 1. Plan Mode Default
Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)If something goes sideways, STOP and re-plan immediately - don't keep pushingUse plan mode for verification steps, not just buildingWrite detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy to keep main context window clean
Offload research, exploration, and parallel analysis to subagentsFor complex problems, throw more compute at it via subagentsOne task per subagent for focused execution

### 3. Self-Improvement Loop
After ANY correction from the user: update 'tasks/lessons.md' with the patternWrite rules for yourself that prevent the same mistakeRuthlessly iterate on these lessons until mistake rate dropsReview lessons at session start for relevant project

### 4. Verification Before Done
Never mark a task complete without proving it worksDiff behavior between main and your changes when relevantAsk yourself: "Would a staff engineer approve this?"Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
For non-trivial changes: pause and ask "is there a more elegant way?"If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"Skip this for simple, obvious fixes - don't over-engineerChallenge your own work before presenting it

### 6. Autonomous Bug Fixing
When given a bug report: just fix it. Don't ask for hand-holdingPoint at logs, errors, failing tests -> then resolve themZero context switching required from the userGo fix failing CI tests without being told how

## Task Management
**Plan First**: Write plan to 'tasks/todo.md' with checkable items**Verify Plan**: Check in before starting implementation**Track Progress**: Mark items complete as you go**Explain Changes**: High-level summary at each step**Document Results**: Add review to 'tasks/todo.md'**Capture Lessons**: Update 'tasks/lessons.md' after corrections

## Core Principles
**Simplicity First**: Make every change as simple as possible. Impact minimal code.**No Laziness**: Find root causes. No temporary fixes. Senior developer standards.**Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.