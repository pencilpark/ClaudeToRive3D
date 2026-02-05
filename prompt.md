# Blender to Rive 3D Animation - AI Agent Prompt

> **For Claude Code with Blender MCP**: This prompt enables AI-assisted conversion of Blender 3D models to Rive-compatible Luau code.

---

## ⚠️ STOP! Before You Start

**Read these 9 rules or face hours of debugging:**

1. **DON'T require Mesh3DUtil for static models** - Inline the math functions
2. **USE `c=index` format** - NOT RGB colors (60% file size reduction)
3. **SORT faces by avgZ** - At export time, then table.sort at runtime
4. **STORE `context`** - Required for `markNeedsUpdate()` (auto-rotation)
5. **BLENDER Z-UP**: Yaw = XY rotation, NOT Y-axis rotation
6. **FACTORIZE SKINNING** - Use patterns table + index array (~40% smaller files)
7. **USE ANTI-FLICKERING METHOD** - table.sort + index tiebreaker + Z_EPSILON (0.001)
8. **USE `depthBias`** - On processFaces: 0/10/20 for object-based parts, 0 for Z-sliced parts, 99/100 for wall overlays
9. **ProjectedFace needs `index` field** - For stable sort tiebreaker
10. **WALL-MOUNTED SURFACES** - Remove from Blender, hardcode in Node Script, use depthBias=100

---

## Your Task

Convert Blender 3D models into functional Rive Node Script Luau code with:
- Automatic polygon-based fragmentation (>1900 faces per file with indexed colors)
- Skeletal animation support (if Armature present)
- Material-to-color category conversion
- Vertex index optimization per fragment
- **Factorized skinning data** (patterns + index array)
- **Anti-flickering system**: table.sort + index tiebreaker + depthBias
- **Wall-mounted surfaces**: hardcoded in Node Script + depthBias for guaranteed draw order

---

## File Size Limits

| Parameter | Value | Notes |
|-----------|-------|-------|
| Max faces/file | **~1900** | Using `c=index` instead of RGB |
| Max vertices/file | **~2500** | With vertex optimization per part |

**Key insight**: Using category index `c=1` instead of `color={r,g,b}` reduces file size by ~60%.

**NEW**: Factorized skinning reduces file size by additional ~40% for animated models.

---

---

## Prerequisites

### Required MCP Tools
- **Blender MCP** - For direct Blender scene access

### Reference Files
- **CLAUDE.md** - Complete Rive Luau documentation
- **Mesh3DUtil.luau** - 3D math utilities
- **SkeletalAnimUtil.luau** - Skeletal animation system
- **Robot.luau** - Example animated model with factorized skinning
- **blender_to_rive.py** - Standalone export script (alternative to MCP)

---

## Anti-Flickering System (CRITICAL - 3 Techniques Combined)

### Problem
Faces with nearly equal depth cause z-fighting flickering during rotation, especially between Parts from different files.

### Solution: 3 Techniques Combined

#### 1. ProjectedFace Type with Index
```luau
-- Include index field for stable sorting
export type ProjectedFace = {
    path: Path,
    depth: number,
    color: Color,
    index: number,  -- Original insertion index for stable sort tiebreaker
}
```

#### 2. depthBias on processFaces
```luau
-- Add optional depthBias parameter to processFaces
local function processFaces(
    self: Model3D,
    vertices: { { x: number, y: number, z: number } },
    faces: { { verts: { number }, c: number } },
    -- ... other parameters ...
    depthBias: number?  -- Shifts depth for sort order without moving geometry
)
    local bias = depthBias or 0
    -- Apply bias when calculating depth:
    local avgZ = (sumZ / #transformed) + bias

    -- Insert with index for stable sorting:
    table.insert(self.projectedFaces, {
        path = facePath,
        depth = avgZ,
        color = litColor,
        index = #self.projectedFaces + 1,  -- Stable sort index
    })
end
```

**Usage depends on how parts are split:**

```luau
-- Case A: Parts = separate objects (robot body/head) → large bias
processFaces(self, vertsA, facesA, ..., 0)   -- Part A: reference
processFaces(self, vertsB, facesB, ..., 10)  -- Part B: offset 10
processFaces(self, vertsC, facesC, ..., 20)  -- Part C: offset 20

-- Case B: Parts = Z-sorted slices of mixed objects (room) → no bias
processFaces(self, vertsA, facesA, ...)       -- Part A: bias=0 (default)
processFaces(self, vertsB, facesB, ...)       -- Part B: bias=0

-- Case C: Wall-mounted overlay (screen, panel) → force to front
processFaces(self, borderVerts, borderFaces, ..., 99)   -- Border behind
processFaces(self, screenVerts, screenFaces, ..., 100)   -- Screen on top
```

#### 3. Stable Sort with table.sort
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
    -- Sort back to front (smaller depth = further = drawn first)
    return a.depth < b.depth
end)
```

### Recommended Values (Tested)
| Parameter | Value | When |
|-----------|-------|------|
| Z_EPSILON | 0.001 | Always |
| depthBias (separate objects) | 0, 10, 20 | Parts = distinct mesh objects |
| depthBias (Z-sliced parts) | 0 for all | Parts = mixed objects sorted by avgZ |
| depthBias (wall overlay) | 99, 100 | Surfaces that must draw on top of wall |
| faceExpansion | 0.05 | Always |
| brightness | 50 | Always |

### Key Insight: depthBias decouples position from sort order
Moving geometry further from a wall to avoid Z-fighting causes visible "detachment" during rotation. Instead, keep geometry close (1-2 normalized units) and use a large depthBias to force sort order. The bias only affects the painter's algorithm depth sort, not the visual position of the polygons.

---

## Wall-Mounted Surfaces (Screens, Panels, Signs)

**Problem:** Flat surfaces on walls Z-fight at rotation angles. Geometric offsets either fail (too small) or cause visible detachment (too large).

**Solution:**
1. Remove the surface mesh from Blender
2. Re-export Part files without it
3. Hardcode vertices/faces directly in the Node Script (`advance()`)
4. Position close to wall (1-2 normalized units from wall surface)
5. Use `depthBias=99/100` to force draw order

```luau
-- Hardcoded TV screen in advance() — positioned flush with wall
local screenVerts: { { x: number, y: number, z: number } } = {
    {x=-51, y=48.66, z=-8.82},   -- 4 corners of the rectangle
    {x=-51, y=83.91, z=-8.82},
    {x=-51, y=83.91, z=17.61},
    {x=-51, y=48.66, z=17.61},
}
local screenFaces: { { verts: { number }, c: number } } = {
    {verts = {1, 2, 3}, c = 12},  -- 2 tris = 1 quad
    {verts = {1, 3, 4}, c = 12},
}
-- depthBias=100 → always draws on top of wall, any angle
processFaces(self, screenVerts, screenFaces, ..., 100)
```

**Why this works:** depthBias adds to the depth sort value, not to the visual position. The screen looks flush with the wall but always sorts in front. No rotation angle can overcome a +100 depth advantage when wall faces have real depths in the [-100, +100] range.

---

## Skinning Data Format (CRITICAL for Animated Models)

### ❌ OLD Format (causes typecheck errors on large models)
```luau
ModelData.skinning = {
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Repeated 100s of times!
  {j = {6, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  -- ... thousands of lines
}
```

### ✅ NEW Factorized Format
```luau
-- Skinning patterns (one entry per bone, max 11-15 entries)
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Root
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Head
  [2] = {j = {2, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Shoulder.L
  [3] = {j = {3, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- UpperArm.L
  -- ... one per bone
}

ModelData.skinningPatterns = S

-- Just the bone index per vertex (compact!)
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, 2, 9, 9, 5, 5, ...}
```

### Export Code for Factorized Skinning
```python
# In Blender export script
bone_count = len(armature.data.bones)

# Generate patterns table (one per bone)
patterns = {}
for i in range(bone_count):
    patterns[i] = {"j": [i, 0, 0, 0], "w": [1.0, 0.0, 0.0, 0.0]}

# Store just the primary bone index per vertex
skinning_index = [skin["j"][0] for skin in all_skinning]

# Generate Luau output
lines.append("local S = {")
for i in range(bone_count):
    lines.append(f"  [{i}] = {{j = {{{i}, 0, 0, 0}}, w = {{1.0, 0.0, 0.0, 0.0}}}},")
lines.append("}")
lines.append("ModelData.skinningPatterns = S")
lines.append("ModelData.skinningIndex = {" + ", ".join(str(i) for i in skinning_index) + "}")
```

### Node Script Usage
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
        local skinIdx = skinningIndex[i]
        local skin = skinningPatterns[skinIdx]
        -- ... transform vertex with skin matrices
    end
    return result
end

-- In advance():
local skinPatterns = (PartAData :: any).skinningPatterns :: { [number]: SkinEntry }
local skinIndex = (PartAData :: any).skinningIndex :: { number }
self.skinnedVerts = skinVertices(skeleton, vertices, skinPatterns, skinIndex)
```

---

## Coordinate System (Blender Z-up)

For Blender Z-up models, rotation mapping:
- `rotationY` (Yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (Pitch) → Tilt forward/back
- `rotationZ` (Roll) → Tilt left/right

```luau
-- Transform for Z-up model (CORRECT implementation)
local function transformVertex(vx, vy, vz, ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ)
    local x, y, z = vx - ax, vy - ay, vz - az

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

---

## Rive Luau Restrictions

### 1. table.sort with Typed Comparator (WORKS!)
```luau
-- ✅ CORRECT: table.sort with TYPED comparator function
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local depthDiff = a.depth - b.depth
    if math.abs(depthDiff) < Z_EPSILON then
        return a.index < b.index  -- Stable tiebreaker
    end
    return a.depth < b.depth
end)
```
**Note:** The comparator MUST have type annotations (`: ProjectedFace`) and return type (`: boolean`).

### 2. Type Casting for Untyped Data
```luau
-- ❌ WRONG
local clip = PartAData.animations["swim"]

-- ✅ CORRECT
local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
if animations then
  local clip = animations["swim"]
end
```

### 3. Path Modification in draw() FORBIDDEN
```luau
-- ❌ WRONG: "Path was modified between draws"
function draw(self, renderer)
  self.path:reset()  -- ERROR!
end

-- ✅ CORRECT: Build paths in advance()
function advance(self, seconds)
  for _, face in ipairs(faces) do
    local facePath = Path.new()
    facePath:moveTo(...)
    facePath:close()
    table.insert(self.projectedFaces, { path = facePath, ... })
  end
end
```

---

## Output Data Structure

### Static Model
```luau
ModelData.vertices = { {x=0, y=0, z=0}, ... }
ModelData.faces = { {verts={1,2,3}, c=1}, ... }
return ModelData
```

### Animated Model (with Factorized Skinning)
```luau
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  -- ...
}

ModelData.vertices = { ... }
ModelData.faces = { ... }
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}

ModelData.skeleton = {
  jointCount = N,
  jointParents = { nil, 1, 2, ... },
  inverseBindMatrices = { {16 floats}, ... },
  restPose = { { translation={...}, rotation={...}, scale={1,1,1} }, ... },
}

ModelData.animations = {
  ["Armature|Idle"] = {
    name = "Armature|Idle",
    duration = 1.5,
    channels = { { jointIndex=1, path="rotation", times={...}, values={...} }, ... },
  },
}

return ModelData
```

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| Faces flickering | Z-fighting from coplanar faces | Use 3-technique anti-flickering |
| Flickering between Parts (objects) | Parts compete for same depth | Use depthBias 0, 10, 20 |
| Flickering between Parts (Z-sliced) | Bias corrupts mixed Z-ordering | Use depthBias=0 for all parts |
| Screen/panel flickers on wall | Coplanar with wall | Hardcode + depthBias=100 (see Wall-Mounted Surfaces) |
| Screen detaches from wall during rotation | Geometric offset too large | Use small offset + large depthBias instead |
| Model twisted when animated | Coordinate space mismatch | Use SAME normalize_mat for ALL data |
| Animation explodes | Armature scale ≠ 1 | Force scale=1 on bone matrices |
| Animation doesn't play | Wrong animation name | Check console for available names |
| "Code too complex" / typecheck error | Too many skinning entries | Use factorized skinning format |
| "Path modified between draws" | path:reset() in draw() | Build paths in advance() |
| Model tilts instead of turns | Wrong rotation axis | Yaw = XY rotation for Z-up models |
| rotationSpeed does nothing | Missing markNeedsUpdate | Store context, call markNeedsUpdate() |

---

## Pre-Export Checklist

Before running any export:

- [ ] Analyzed model (vertex count, polygon count, materials)
- [ ] Identified coordinate system (Z-up for Blender)
- [ ] Mapped materials to category indices
- [ ] Will use `c=index` format (NOT RGB)
- [ ] Will sort faces by avgZ before fragmenting
- [ ] Will extract only used vertices per part
- [ ] **Will use factorized skinning** (patterns + index)
- [ ] Main script will store `context` for `markNeedsUpdate()`
- [ ] For Z-up: Yaw rotates in XY plane (cosY/sinY on x,y)
- [ ] **Anti-flickering implemented:**
  - [ ] ProjectedFace type has `index` field
  - [ ] processFaces has optional `depthBias` parameter
  - [ ] depthBias: 0 for Z-sliced parts, 0/10/20 for object-based parts
  - [ ] table.sort with typed comparator + Z_EPSILON (0.001) + index tiebreaker
  - [ ] faceExpansion = 0.05, brightness = 50
- [ ] **Wall-mounted surfaces** (if model has screens, panels, signs):
  - [ ] Removed from Blender, hardcoded in Node Script
  - [ ] Positioned close to wall (1-2 normalized units)
  - [ ] depthBias=99/100 to force draw order

---

## Common Mistakes Summary

| What You Did | What Went Wrong | What To Do |
|--------------|-----------------|------------|
| Used Mesh3DUtil for static model | Unnecessary import | Inline the math functions |
| Used RGB `color={r,g,b}` | Files too large | Use `c=1` category index |
| Used full skinning entries | Typecheck error / huge files | Use factorized skinning |
| Sorted by maxZ | Objects behind terrain | Sort by avgZ (centroid) |
| Forgot `context:markNeedsUpdate()` | rotationSpeed does nothing | Store context, call markNeedsUpdate |
| Used untyped table.sort comparator | May not work | Use TYPED comparator (`: ProjectedFace, : boolean`) |
| Yaw rotated around Y axis | Model tilts instead of turns | For Z-up: rotate in XY plane |
| Shared all vertices across parts | "Code too complex" error | Extract only used vertices per part |
| Used geometric offset for wall screen | Screen detaches at rotation | Use depthBias=100 + small geometric offset |
| Used depthBias on Z-sliced parts | Objects appear behind walls | Use depthBias=0 for Z-sliced parts |
| No index field in ProjectedFace | Unstable sort order | Add `index` field for tiebreaker |

---

## Auto-Rotation Implementation (CRITICAL)

**Problem:** `rotationSpeed` does nothing without waking the render loop.

```luau
export type Model3D = {
  context: Context?,  -- MUST store context reference
  -- ...
}

local function init(self: Model3D, context: Context): boolean
  self.context = context  -- Store it!
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
