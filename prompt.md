# Blender to Rive 3D Animation - AI Agent Prompt

> **For Claude Code with Blender MCP**: This prompt enables AI-assisted conversion of Blender 3D models to Rive-compatible Luau code.

---

## ⚠️ STOP! Before You Start

**Read these 11 rules or face hours of debugging:**

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
11. **ANIMATIONS = ABSOLUTE transforms** - NOT deltas from rest pose. Export final local TRS per keyframe.

---

## Your Task

Convert Blender 3D models into functional Rive Node Script Luau code with:
- Automatic polygon-based fragmentation (>1900 faces per file with indexed colors)
- Skeletal animation support (if Armature present)
- Material-to-color category conversion (multi-zone coloring)
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

**Factorized skinning** reduces file size by additional ~40% for animated models.

**Animations** are stored in separate files from Part data (ModelAnim1Data, ModelAnim2Data, etc.).

---

## Animation System (CRITICAL)

### Data Format

**All data is in the SAME normalized coordinate space:**
- **Vertices:** Centered, scaled to ~200 units max dimension
- **IBMs:** Calculated in normalized space, scale forced to 1
- **Rest pose:** Local transforms in normalized space, scale = `{1, 1, 1}`
- **Animations:** **ABSOLUTE** local transforms per keyframe (NOT deltas)

**Quaternion format:** WXYZ in data files (Blender native `{w, x, y, z}`).
`SkeletalAnimUtil` converts to XYZW internally.

**Joint indices:** 1-based in data files (Luau convention). No `+1` needed in `sampleAnimation()`.

**Skinning patterns:** 0-based bone indices in patterns table. The `+1` is done in `skinVerticesFact()`.

### Why ABSOLUTE (not deltas)

The export script samples the full evaluated pose at each frame, computes local transform relative to parent (in normalized space), and stores that directly:
- Each keyframe = final local TRS for that bone at that time
- Runtime writes values directly to `localTransforms[jointIdx]`
- No delta composition, no `matrix_basis`, no rest-pose multiplication
- Avoids all FCurve delta interpretation complexity

### Runtime Pipeline

```
sampleAnimation()  →  writes absolute local transforms
updateSkeleton()   →  computes worldMatrices + skinMatrices
skinVerticesFact() →  transforms vertices by bone skinMatrix
```

### Export Method (Blender MCP or blender_to_rive.py)

```python
# For each frame, for each bone:
bpy.context.scene.frame_set(frame)
pose_world = arm_world @ pose_bone.matrix
pose_normalized = normalize_mat @ pose_world
loc, rot, _ = pose_normalized.decompose()
pose_mat = LocRotScale(loc, rot, (1,1,1))  # Force scale=1
local_mat = parent_mat.inv @ pose_mat       # This IS the final local transform
# Store as: translation={x,y,z}, rotation={w,x,y,z} (WXYZ)
```

---

## Prerequisites

### Required MCP Tools
- **Blender MCP** - For direct Blender scene access

### Reference Files
- **CLAUDE.md** - Complete Rive Luau documentation
- **Mesh3DUtil.luau** - 3D math utilities
- **SkeletalAnimUtil.luau** - Skeletal animation system
- **blender_to_rive.py** - Standalone export script (alternative to MCP)

---

## Multi-Zone Coloring

### Setup in Blender
1. Create one material per color zone (e.g., M_Body, M_Head, M_Jaw, M_Ears, etc.)
2. Assign materials to faces via vertex groups or manual selection
3. Export — each material becomes a category index `c=1..N`

### Implementation in Node Script
```luau
-- Expose colors in Property Group
bodyColor: Input<Color>,
headColor: Input<Color>,
jawColor: Input<Color>,
earColor: Input<Color>,
frontLegColor: Input<Color>,
hindLegColor: Input<Color>,
tailColor: Input<Color>,

-- Build colorMap in processFaces
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

---

## Anti-Flickering System (CRITICAL - 3 Techniques Combined)

### Problem
Faces with nearly equal depth cause z-fighting flickering during rotation, especially between Parts from different files.

### Solution: 3 Techniques Combined

#### 1. ProjectedFace Type with Index
```luau
export type ProjectedFace = {
    path: Path,
    depth: number,
    color: Color,
    index: number,  -- Original insertion index for stable sort tiebreaker
}
```

#### 2. depthBias on processFaces
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

**Usage depends on how parts are split:**

```luau
-- Case A: Parts = separate objects (robot body/head) → large bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 10)
processFaces(self, vertsC, facesC, ..., 20)

-- Case B: Parts = Z-sorted slices of mixed objects → no bias
processFaces(self, vertsA, facesA, ...)
processFaces(self, vertsB, facesB, ...)

-- Case C: Wall-mounted overlay → force to front
processFaces(self, screenVerts, screenFaces, ..., 100)
```

#### 3. Stable Sort with table.sort
```luau
local Z_EPSILON = 0.001
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local depthDiff = a.depth - b.depth
    if math.abs(depthDiff) < Z_EPSILON then
        return a.index < b.index
    end
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

---

## Wall-Mounted Surfaces (Screens, Panels, Signs)

**Problem:** Flat surfaces on walls Z-fight at rotation angles. Geometric offsets either fail or cause visible detachment.

**Solution:**
1. Remove the surface mesh from Blender
2. Re-export Part files without it
3. Hardcode vertices/faces directly in the Node Script (`advance()`)
4. Position close to wall (1-2 normalized units from wall surface)
5. Use `depthBias=99/100` to force draw order

```luau
local screenVerts: { { x: number, y: number, z: number } } = {
    {x=-51, y=48.66, z=-8.82},
    {x=-51, y=83.91, z=-8.82},
    {x=-51, y=83.91, z=17.61},
    {x=-51, y=48.66, z=17.61},
}
local screenFaces: { { verts: { number }, c: number } } = {
    {verts = {1, 2, 3}, c = 12},
    {verts = {1, 3, 4}, c = 12},
}
processFaces(self, screenVerts, screenFaces, ..., 100)
```

---

## Skinning Data Format (CRITICAL for Animated Models)

### ❌ OLD Format (causes typecheck errors on large models)
```luau
ModelData.skinning = {
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Repeated 100s of times!
}
```

### ✅ NEW Factorized Format
```luau
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Root
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Head
  [2] = {j = {2, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Shoulder.L
  -- ... one per bone
}

ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, 2, 9, 9, 5, 5, ...}
```

### Node Script Usage
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
            local jointIdx = skin.j[k] + 1  -- 0-based → 1-based
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
```

---

## Coordinate System (Blender Z-up)

For Blender Z-up models, rotation mapping:
- `rotationY` (Yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (Pitch) → Tilt forward/back
- `rotationZ` (Roll) → Tilt left/right

```luau
local function transformVertex(vx, vy, vz, ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ)
    local x, y, z = vx - ax, vy - ay, vz - az
    -- Yaw: rotate in XY plane
    local rx = x * cosY - y * sinY
    local ry = x * sinY + y * cosY
    x, y = rx, ry
    -- Pitch: rotate in YZ plane
    local ry2 = y * cosX - z * sinX
    local rz = y * sinX + z * cosX
    y, z = ry2, rz
    -- Roll: rotate in XY plane
    local rx2 = x * cosZ - y * sinZ
    local ry2b = x * sinZ + y * cosZ
    return rx2, ry2b, z
end
```

---

## Rive Luau Restrictions

### 1. table.sort with Typed Comparator (WORKS!)
```luau
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local depthDiff = a.depth - b.depth
    if math.abs(depthDiff) < Z_EPSILON then
        return a.index < b.index
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

### Part Data File
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

ModelData.vertices = { {x=0, y=0, z=0}, ... }
ModelData.faces = { {verts={1,2,3}, c=1}, ... }
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}
```

### Animation Data File
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
}
```

**Key format details:**
- `jointIndex` is **1-based** (Luau arrays)
- Rotation values are **WXYZ** (Blender native)
- All transforms are **ABSOLUTE** (not deltas)

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| Faces flickering | Z-fighting from coplanar faces | Use 3-technique anti-flickering |
| Flickering between Parts (objects) | Parts compete for same depth | Use depthBias 0, 10, 20 |
| Flickering between Parts (Z-sliced) | Bias corrupts mixed Z-ordering | Use depthBias=0 for all parts |
| Screen/panel flickers on wall | Coplanar with wall | Hardcode + depthBias=100 |
| Screen detaches from wall | Geometric offset too large | Use small offset + large depthBias |
| Model disappears when animated | Data format mismatch | Re-export with blender_to_rive.py |
| Animation looks wrong | Using deltas instead of absolute | Ensure ABSOLUTE local transforms |
| Quaternion issues | WXYZ vs XYZW confusion | Data=WXYZ, runtime converts to XYZW |
| `localTransforms[0]` nil | 0-based jointIndex | Use 1-based jointIndex in data |
| `{x=1}[1]` returns nil | Named keys vs arrays | Use ordered arrays in data files |
| Model twisted when animated | Coordinate space mismatch | Use SAME normalize_mat for ALL data |
| "Code too complex" / typecheck error | Too many skinning entries | Use factorized skinning format |
| "Path modified between draws" | path:reset() in draw() | Build paths in advance() |
| Model tilts instead of turns | Wrong rotation axis | Yaw = XY rotation for Z-up models |
| rotationSpeed does nothing | Missing markNeedsUpdate | Store context, call markNeedsUpdate() |

---

## Pre-Export Checklist

Before running any export:

- [ ] Analyzed model (vertex count, polygon count, materials)
- [ ] Identified coordinate system (Z-up for Blender)
- [ ] Mapped materials to category indices (one per zone)
- [ ] Will use `c=index` format (NOT RGB)
- [ ] Will sort faces by avgZ before fragmenting
- [ ] Will extract only used vertices per part
- [ ] **Will use factorized skinning** (patterns + index)
- [ ] **Animations: ABSOLUTE local transforms** (not deltas)
- [ ] **Quaternions: WXYZ in data files**
- [ ] **Joint indices: 1-based in data files**
- [ ] Main script will store `context` for `markNeedsUpdate()`
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
- [ ] **Wall-mounted surfaces** (if any):
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
| Exported FCurve deltas | Animation corrupted | Export ABSOLUTE local transforms |
| Used 0-based jointIndex | Root bone never animated | Use 1-based jointIndex |
| Used named keys `{x=,y=}` | `[1]` returns nil | Use ordered arrays `{v1, v2}` |
| Sorted by maxZ | Objects behind terrain | Sort by avgZ (centroid) |
| Forgot `context:markNeedsUpdate()` | rotationSpeed does nothing | Store context, call markNeedsUpdate |
| Yaw rotated around Y axis | Model tilts instead of turns | For Z-up: rotate in XY plane |
| Shared all vertices across parts | "Code too complex" error | Extract only used vertices per part |
| Used geometric offset for wall screen | Screen detaches at rotation | Use depthBias=100 + small offset |
| Used depthBias on Z-sliced parts | Objects appear behind walls | Use depthBias=0 for Z-sliced parts |
| Tried to patch unknown data format | Hours of debugging | Re-export from Blender instead |

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
