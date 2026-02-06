# Blender to Rive 3D Export

> **Quick Start:** Run `blender_to_rive.py` in Blender OR use Claude Code + Blender MCP → Copy generated `.luau` files to Rive

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
10. **Multi-zone coloring** - Assign Blender materials per zone, expose Input<Color> per zone in Node Script

## Project Structure (Generic Template)

```
YOUR_MODEL/
├── Model.luau               # Main Node Script (rendering + Property Group)
├── ModelPartAData.luau      # Part A: ~1900 faces max + skeleton data
├── ModelPartBData.luau      # Part B: ~1900 faces max
├── ModelPartCData.luau      # Part C: remaining faces (optional)
├── ModelAnim1Data.luau      # Animation data file 1 (split by size)
├── ModelAnim2Data.luau      # Animation data file 2 (optional)
├── ModelAnim3Data.luau      # Animation data file 3 (optional)
├── Mesh3DUtil.luau          # 3D math utilities (for animated models)
├── SkeletalAnimUtil.luau    # Skeletal animation system
├── blender_to_rive.py       # Standalone export script
├── prompt.md                # AI agent prompt for Claude Code
└── CLAUDE.md                # This documentation
```

**Note on animations:** Animation data is stored separately from Part data files. Each animation file can contain multiple animation clips. Split across multiple files if total size exceeds Rive limits.

---

## Animation System Format (CRITICAL)

### Data Format (from blender_to_rive.py)

**All data is in the SAME normalized coordinate space:**
- **Vertices:** Centered, scaled to ~200 units max dimension
- **IBMs:** Calculated in the same normalized space, scale forced to 1
- **Rest pose:** Local transforms in normalized space, scale always `{1, 1, 1}`
- **Animations:** **ABSOLUTE** local transforms per keyframe (NOT deltas)

**Quaternion format:** WXYZ in data files (Blender native: `{w, x, y, z}`).
`SkeletalAnimUtil` converts to XYZW internally in `buildSkeleton()` and `sampleQuat()`.

**Joint indices:** 1-based in data files (Luau array convention). No `+1` needed in `sampleAnimation()`.

**Skinning patterns:** 0-based bone indices in the patterns table. The `+1` conversion to Luau 1-based is done in `skinVerticesFact()` at runtime.

### Why ABSOLUTE transforms (not deltas)

The export script samples the full evaluated pose at each keyframe frame in Blender, computes the local transform relative to parent (in normalized space), and stores that directly. This means:

- Each keyframe contains the **final** local TRS for that bone at that time
- The runtime just writes these values directly to `localTransforms[jointIdx]`
- No delta composition, no `matrix_basis`, no rest-pose multiplication needed
- Avoids all complexity of FCurve delta interpretation

### SkeletalAnimUtil Pipeline

```
sampleAnimation()  →  writes absolute local transforms to skeleton.localTransforms
updateSkeleton()   →  computes worldMatrices (parent chain) and skinMatrices (world * IBM)
skinVerticesFact() →  transforms each vertex by its bone's skinMatrix
```

---

## Critical Lessons Learned

### 1. NEVER Patch Data Files — Re-Export Instead
When data files come from an unknown pipeline and don't match the expected format, do NOT try to reverse-engineer and patch. Instead use `blender_to_rive.py` (or reproduce its logic via Blender MCP) to re-export everything. This ensures all data is in the SAME coordinate space.

### 2. File Size Limits
- **Maximum ~1900 polygons** per Luau script file
- **Maximum ~2500 vertices** per Luau script file
- Using category index `c` instead of RGB colors reduces data size significantly
- **Factorized skinning** reduces file size by ~40% for animated models
- **Animations stored separately** from part data to avoid exceeding file limits

### 3. Face Data Format (Compact)
```luau
-- ❌ WRONG: Verbose RGB colors
{ verts = { 1, 2, 3 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Category index (much smaller)
{ verts = { 1, 2, 3 }, c = 1 }
```

### 4. Skinning Data Format (Factorized)
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
  -- ... one entry per bone
}

ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, 2, 9, 9, ...}  -- Just bone indices!
```

**File size reduction:**
| Before | After | Savings |
|--------|-------|---------|
| 228 KB | 139 KB | **-39%** |
| 102 KB | 65 KB | **-36%** |

### 5. Multi-Zone Coloring

**Problem:** You want different body parts to have independently controllable colors.

**Solution:**
1. **In Blender:** Create one material per zone (e.g., M_Body, M_Head, M_Jaw, M_Ears, M_FrontLegs, M_HindLegs, M_Tail)
2. **Assign materials** to faces via vertex groups or manual selection
3. **Export** with `blender_to_rive.py` — each material becomes a category index `c=1..N`
4. **In Node Script:** Expose one `Input<Color>` per zone and build a colorMap

```luau
-- In processFaces:
local colorMap: { [number]: Color } = {
    [1] = self.bodyColor,
    [2] = self.headColor,
    [3] = self.jawColor,
    [4] = self.earColor,
    [5] = self.frontLegColor,
    [6] = self.hindLegColor,
    [7] = self.tailColor,
}
local faceColor = colorMap[face.c] or self.bodyColor
```

### 6. Anti-Flickering System (CRITICAL - 3 Techniques Combined)

**Problem:** Faces with nearly equal depth cause z-fighting flickering during rotation.

**Solution:** Combine 3 techniques for complete anti-flickering:

#### 6.1 ProjectedFace Type with Index
```luau
export type ProjectedFace = {
    path: Path,
    depth: number,
    color: Color,
    index: number,  -- Original insertion index for stable sort tiebreaker
}
```

#### 6.2 depthBias Parameter on processFaces
```luau
local function processFaces(
    self: Model3D,
    vertices: { { x: number, y: number, z: number } },
    faces: { { verts: { number }, c: number } },
    -- ... other parameters ...
    depthBias: number?  -- Shifts depth for sort order without moving geometry
)
    local bias = depthBias or 0
    local avgZ = (sumZ / #transformed) + bias

    table.insert(self.projectedFaces, {
        path = facePath,
        depth = avgZ,
        color = litColor,
        index = #self.projectedFaces + 1,
    })
end
```

**depthBias use cases:**

```luau
-- Case A: Parts = separate objects (robot body/head) → large bias
processFaces(self, vertsA, facesA, ..., 0)   -- Part A
processFaces(self, vertsB, facesB, ..., 10)  -- Part B
processFaces(self, vertsC, facesC, ..., 20)  -- Part C

-- Case B: Parts = Z-sorted slices (single mesh) → no bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 0)
processFaces(self, vertsC, facesC, ..., 0)

-- Case C: Wall-mounted overlay → force to front
processFaces(self, screenVerts, screenFaces, ..., 100)
```

#### 6.3 Stable Sort with table.sort and Index Tiebreaker
```luau
local Z_EPSILON = 0.001
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local depthDiff = a.depth - b.depth
    if math.abs(depthDiff) < Z_EPSILON then
        return a.index < b.index  -- Stable tiebreaker
    end
    return a.depth < b.depth  -- Back to front
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

### 7. Coordinate System (Blender Z-up to Rive)
**Blender uses Z-up, Rive screen is X-right, Y-down, Z-into-screen.**

Rotation mapping:
- `rotationY` (yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (pitch) → Tilt forward/backward
- `rotationZ` (roll) → Tilt left/right

```luau
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

### 8. Mesh3DUtil - Optional for Static Models
**For static (non-animated) models, Mesh3DUtil is NOT required.**

Only require Mesh3DUtil if using:
- Matrix operations (mat4)
- Quaternion math
- Skeletal animation

### 9. Wall-Mounted Surfaces (Screens, Panels, Signs)

**Problem:** Flat surfaces on walls cause Z-fighting regardless of geometric offset.

**Solution: Decouple visual position from sort order using `depthBias`.**

1. **Remove the surface from Blender** (delete the mesh)
2. **Re-export Part files** (without the surface)
3. **Hardcode the surface as vertices/faces directly in the Node Script** (`advance()`)
4. **Position close to wall** (1-2 normalized units offset — visually flush)
5. **Use large `depthBias`** (99-100) to force it to always draw IN FRONT of everything

```luau
local tvScreenVerts: { { x: number, y: number, z: number } } = {
    {x=-51, y=48.66, z=-8.82},
    {x=-51, y=83.91, z=-8.82},
    {x=-51, y=83.91, z=17.61},
    {x=-51, y=48.66, z=17.61},
}
local tvScreenFaces: { { verts: { number }, c: number } } = {
    {verts = {1, 2, 3}, c = 12},
    {verts = {1, 3, 4}, c = 12},
}
processFaces(self, tvScreenVerts, tvScreenFaces, ..., 100)
```

---

## Export Workflow

### Option A: blender_to_rive.py (Standalone Script)
1. Open your `.blend` file
2. Configure `MODEL_NAME` and settings at top of script
3. Run script (`Alt+P` in Text Editor)
4. Copy generated `.luau` files to your Rive project

### Option B: Claude Code + Blender MCP
1. Connect Blender MCP
2. Claude analyzes the model (bones, materials, vertex count)
3. Claude runs the export logic step-by-step via Python in Blender
4. Claude generates the `.luau` files directly

Both produce the same output format: normalized space, absolute transforms, WXYZ quaternions, 1-based joint indices.

### Export Steps (both methods)

#### Step 1: Analyze Model
```python
obj = bpy.data.objects.get("ModelName")
# Check: vertex count, polygon count, materials, armature
```

#### Step 2: Normalize Coordinates
```python
# Center and scale to ~200 units
center = (min_coord + max_coord) / 2
scale_factor = 200 / max_dimension
normalize_mat = Scale(scale_factor) @ Translate(-center)
```

#### Step 3: Export Skeleton (in normalized space)
```python
# For each bone:
bone_world = arm_world @ bone.matrix_local
bone_normalized = normalize_mat @ bone_world
loc, rot, _ = bone_normalized.decompose()
bone_mat = LocRotScale(loc, rot, (1,1,1))  # Force scale=1
ibm = bone_mat.inverted()
# Local transform = parent_mat.inv @ bone_mat
```

#### Step 4: Export Animations (ABSOLUTE local transforms)
```python
# For each frame, for each bone:
bpy.context.scene.frame_set(frame)
pose_world = arm_world @ pose_bone.matrix
pose_normalized = normalize_mat @ pose_world
loc, rot, _ = pose_normalized.decompose()
pose_mat = LocRotScale(loc, rot, (1,1,1))
local_mat = parent_mat.inv @ pose_mat  # This IS the final local transform
# Store translation + rotation as WXYZ
```

#### Step 5: Categorize Materials
```python
material_categories = {mat.name: i + 1 for i, mat in enumerate(materials)}
```

#### Step 6: Sort Faces by Depth
```python
all_faces.sort(key=lambda f: avg_z(f))
```

#### Step 7: Fragment with Vertex Optimization
```python
# Each part gets ONLY its used vertices (remapped indices)
def extract_part_data(faces_slice, all_vertices):
    used_indices = set(vi for f in faces_slice for vi in f['verts'])
    index_map = {old: new+1 for new, old in enumerate(sorted(used_indices))}
```

#### Step 8: Factorize Skinning
```python
patterns = {}
for i in range(bone_count):
    patterns[i] = {"j": [i, 0, 0, 0], "w": [1.0, 0.0, 0.0, 0.0]}
skinning_index = [primary_bone_per_vertex]
```

---

## Output Data Structure

### Part Data File (e.g., ModelPartAData.luau)
```luau
-- Skeleton (first part only)
ModelData.skeleton = {
  jointCount = N,
  jointParents = { nil, 1, 2, ... },         -- 1-based, nil for roots
  inverseBindMatrices = { {16 floats}, ... }, -- Column-major, scale=1
  restPose = {
    { translation = {x, y, z}, rotation = {w, x, y, z}, scale = {1, 1, 1} },
    ...
  },
}

-- Vertices and faces
ModelData.vertices = { {x=0, y=0, z=0}, ... }
ModelData.faces = { {verts={1,2,3}, c=1}, ... }

-- Factorized skinning
ModelData.skinningPatterns = S  -- {[0]={j={0,0,0,0},w={1,0,0,0}}, ...}
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}  -- Bone index per vertex
```

### Animation Data File (e.g., ModelAnim1Data.luau)
```luau
ModelData.animations = {
  ["idle_Root_00"] = {
    name = "idle_Root_00",
    duration = 1.5,
    channels = {
      { jointIndex = 1, path = "rotation", times = {...}, values = {w,x,y,z,...} },
      { jointIndex = 1, path = "translation", times = {...}, values = {x,y,z,...} },
      ...
    },
  },
  ...
}
```

**Key format details:**
- `jointIndex` is **1-based** (Luau arrays)
- Rotation values are **WXYZ** (Blender native)
- Translation/scale values are `{x, y, z}`
- All transforms are **ABSOLUTE** (not deltas from rest pose)

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| Faces flickering | Z-fighting from coplanar faces | Use 3-technique anti-flickering: index + depthBias + table.sort |
| Flickering between Parts (separate objects) | Parts from different files compete | Use LARGE depthBias (10, 20) per part |
| Flickering between Parts (Z-sliced) | Parts overlap in Z range | Use depthBias=0 for all parts |
| Screen/panel flickers on wall | Coplanar surface competes with wall | Hardcode in Node Script + depthBias=100 |
| Screen "detaches" from wall | Geometric offset too large | Use small geometric offset + large depthBias instead |
| Model disappears when animated | Data format mismatch | Re-export with blender_to_rive.py (see lesson 1) |
| Animation looks wrong | Delta vs absolute confusion | Ensure data has ABSOLUTE transforms (not FCurve deltas) |
| Quaternion corruption | WXYZ vs XYZW mismatch | Data files: WXYZ. SkeletalAnimUtil converts internally |
| `localTransforms[0]` is nil | 0-based jointIndex | Ensure jointIndex is 1-based in data files |
| `{x=1}[1]` returns nil | Named keys vs ordered arrays | Use ordered arrays `{v1, v2, v3}` in data files |
| Objects behind terrain | Wrong depth sort direction | Use `depth < depth` for back-to-front |
| Model rotates wrong axis | Y-up vs Z-up confusion | Yaw rotates in XY plane for Z-up models |
| Faces disappear | Wrong backface culling | Check normal direction `nz < 0` |
| Colors all same | Not using category index | Use `c = index` format with colorMap |
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
  -- Also wake for animation
  if self.animationEnabled and self.context then
    self.context:markNeedsUpdate()
  end
  return true
end
```

---

## Skinning in Node Script (Factorized Format)

```luau
type SkinEntry = { j: { number }, w: { number } }

local function skinVerticesFact(
    skeleton: SkelAnim.Skeleton,
    vertices: { { x: number, y: number, z: number } },
    skinningPatterns: { [number]: SkinEntry },
    skinningIndex: { number }
): { { x: number, y: number, z: number } }
    local result = {}
    for i, v in ipairs(vertices) do
        local skinIdx = skinningIndex[i]
        local skin = skinningPatterns[skinIdx]
        local sx, sy, sz = 0.0, 0.0, 0.0

        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- 0-based pattern → 1-based Luau
            local weight = skin.w[k]
            if weight > 0 and jointIdx >= 1 and jointIdx <= skeleton.jointCount then
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
```

---

## Quick Checklist (Before Starting Export)

- [ ] Model analyzed (vertex/polygon count, materials)
- [ ] Coordinate system identified (Z-up = Blender default)
- [ ] Materials mapped to category indices (one per color zone)
- [ ] Using `c=index` format (NOT RGB)
- [ ] Faces will be sorted by avgZ
- [ ] Each part will have only its used vertices
- [ ] Skinning data will be factorized (patterns + index)
- [ ] Animations exported as ABSOLUTE local transforms (not deltas)
- [ ] Quaternions in WXYZ format in data files
- [ ] Joint indices are 1-based in data files
- [ ] `context:markNeedsUpdate()` for auto-rotation/animation
- [ ] For Z-up: Yaw rotates in XY plane (cosY/sinY on x,y)
- [ ] **Anti-flickering implemented:**
  - [ ] ProjectedFace type has `index` field
  - [ ] processFaces has optional `depthBias` parameter
  - [ ] depthBias: 0 for Z-sliced parts, 0/10/20 for object-based parts
  - [ ] table.sort with typed comparator + Z_EPSILON (0.001) + index tiebreaker
  - [ ] faceExpansion = 0.05, brightness = 50
- [ ] **Multi-zone coloring** (if applicable):
  - [ ] Materials assigned in Blender (one per zone)
  - [ ] Input<Color> per zone in Node Script
  - [ ] colorMap in processFaces
- [ ] **Wall-mounted surfaces** (if any screens, panels, signs):
  - [ ] Removed from Blender, hardcoded in Node Script
  - [ ] Positioned close to wall (1-2 normalized units)
  - [ ] depthBias=99/100 to force draw order

---

## Performance Notes

- **4928 faces** renders smoothly with table.sort
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
rotationSpeed = 10,       -- Visible rotation for testing
brightness = 50,          -- Base lighting 50%
faceExpansion = 0.05,     -- Visual gap between faces
backfaceCulling = true,   -- Cull back-facing polygons
animationSpeed = 1,       -- Normal playback speed
```

## Workflow Orchestration

### 1. Plan Mode Default
Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions). If something goes sideways, STOP and re-plan immediately - don't keep pushing. Use plan mode for verification steps, not just building. Write detailed specs upfront to reduce ambiguity.

### 2. Subagent Strategy to keep main context window clean
Offload research, exploration, and parallel analysis to subagents. For complex problems, throw more compute at it via subagents. One task per subagent for focused execution.

### 3. Self-Improvement Loop
After ANY correction from the user: update `tasks/lessons.md` with the pattern. Write rules for yourself that prevent the same mistake. Ruthlessly iterate on these lessons until mistake rate drops. Review lessons at session start for relevant project.

### 4. Verification Before Done
Never mark a task complete without proving it works. Diff behavior between main and your changes when relevant. Ask yourself: "Would a staff engineer approve this?" Run tests, check logs, demonstrate correctness.

### 5. Demand Elegance (Balanced)
For non-trivial changes: pause and ask "is there a more elegant way?" If a fix feels hacky: "Knowing everything I know now, implement the elegant solution." Skip this for simple, obvious fixes - don't over-engineer. Challenge your own work before presenting it.

### 6. Autonomous Bug Fixing
When given a bug report: just fix it. Don't ask for hand-holding. Point at logs, errors, failing tests -> then resolve them. Zero context switching required from the user. Go fix failing CI tests without being told how.

## Task Management
**Plan First**: Write plan to `tasks/todo.md` with checkable items. **Verify Plan**: Check in before starting implementation. **Track Progress**: Mark items complete as you go. **Explain Changes**: High-level summary at each step. **Document Results**: Add review to `tasks/todo.md`. **Capture Lessons**: Update `tasks/lessons.md` after corrections.

## Core Principles
**Simplicity First**: Make every change as simple as possible. Impact minimal code. **No Laziness**: Find root causes. No temporary fixes. Senior developer standards. **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.
