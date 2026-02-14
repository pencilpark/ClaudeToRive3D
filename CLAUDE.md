# Blender to Rive 3D Export — Universal Guide

> **Quick Start:** Run `blender_to_rive.py` in Blender OR use Claude Code + Blender MCP → Copy generated `.luau` files to Rive

## ⚠️ CRITICAL RULES (Read Before Exporting)

1. **⚠️ ALWAYS use "posed rest" as reference** — NOT `bone.matrix_local` (pure REST). See "Posed Rest" section.
2. **⚠️ NEVER reset `matrix_basis`** before sampling animations — it IS the model's default pose.
3. **⚠️ ALWAYS prefer Blender MCP** over standalone Python scripts — more reliable.
4. **Static models DON'T need Mesh3DUtil** — All math can be inline
5. **Use category index `c=1`** instead of RGB colors — 60% smaller files
6. **Sort faces by avgZ** at export time for painter's algorithm
7. **Extract only used vertices per part** — Prevents typecheck errors
8. **Blender Z-up**: Yaw rotates in XY plane, NOT around Y axis
9. **Factorize skinning data** — Use index references to reduce file size ~40%
10. **Use anti-flickering method** — table.sort + index tiebreaker + depthBias
11. **Use depthBias per Part file** — Large offsets (0, 10, 20) when parts are separate objects
12. **Wall-mounted surfaces** — Hardcode in Node Script + depthBias to force draw order
13. **Multi-zone coloring** — Assign Blender materials per zone, expose Input<Color> per zone
14. **Triangulate all meshes** — via bmesh at export time, not in Blender (preserves original)

---

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
├── blender_to_rive.py       # Universal export script (v5.0)
├── prompt.md                # AI agent prompt for Claude Code
└── CLAUDE.md                # This documentation
```

**File naming convention:** `{MODEL_NAME}Part{A,B,C,...}Data.luau` and `{MODEL_NAME}Anim{1,2,3,...}Data.luau`. Configure `MODEL_NAME` in `blender_to_rive.py` settings.

**Animations** are stored in separate files from Part data. Each animation file can contain multiple clips. Split across files if total size exceeds Rive limits.

---

## Universal Export Process (10 Steps)

**Proven on:** 15 meshes, 43 bones, 14 animations, 5664 faces, 9300 vertices — any model follows the same steps.

### Step 1: Discover Model
```python
# Automatically find:
# - The armature (first object of type 'ARMATURE')
# - All mesh children (exclude non-mesh, cameras, empties, etc.)
# - Parent type per mesh: BONE (rigid) vs ARMATURE modifier (multi-bone skinning)
# - Materials across all meshes (sorted alphabetically → category indices 1..N)
# - Total vertex/polygon count

armature = None
for obj in bpy.data.objects:
    if obj.type == 'ARMATURE':
        armature = obj
        break

mesh_objects = [
    child for child in armature.children
    if child.type == 'MESH' and child.name not in EXCLUDE_MESHES
]
```

### Step 2: Detect `matrix_basis` Residuals (ALWAYS FIRST)
```python
# Determines whether to use "posed rest" (most models) or "pure rest"
armature.animation_data.action = None
armature.data.pose_position = 'POSE'
bpy.context.view_layer.update()

non_identity = 0
for pb in armature.pose.bones:
    loc, rot, _ = pb.matrix_basis.decompose()
    if loc.length > 0.0001 or abs(rot.w - 1.0) + abs(rot.x) + abs(rot.y) + abs(rot.z) > 0.001:
        non_identity += 1

# If ANY bone has residual matrix_basis → MUST use "posed rest" for ALL exports
```

### Step 3: Build Bone Order
```python
# DFS traversal from root bones, producing a consistent ordering
# This order is used for: joint indices, parent arrays, IBMs, rest pose, animations
bone_order = []
def dfs(bone):
    bone_order.append(bone.name)
    for child in sorted(bone.children, key=lambda b: b.name):
        dfs(child)

for root in sorted(armature.data.bones, key=lambda b: b.name):
    if root.parent is None:
        dfs(root)
```

### Step 4: Compute Normalization (in POSED REST)
```python
# ⚠️ CRITICAL: Bounding box from ALL meshes in POSED REST position
armature.animation_data.action = None
armature.data.pose_position = 'POSE'
bpy.context.view_layer.update()

# Gather all vertices across all meshes in world space
for obj in mesh_objects:
    for v in obj.data.vertices:
        world_pos = obj.matrix_world @ v.co  # Follows posed bones
        update_bounds(world_pos)

center = (min_coord + max_coord) / 2
scale_factor = TARGET_SIZE / max_dimension  # TARGET_SIZE = 200
normalize_mat = Matrix.Scale(scale_factor, 4) @ Matrix.Translation(-center)
```

### Step 5: Export Skeleton (from POSED REST)
```python
# ⚠️ Use pose_bone.matrix (includes matrix_basis), NOT bone.matrix_local
arm_world = armature.matrix_world

for bone_name in bone_order:
    pose_bone = armature.pose.bones[bone_name]
    bone_world = arm_world @ pose_bone.matrix    # ← NOT bone.matrix_local!
    bone_normalized = normalize_mat @ bone_world
    loc, rot, _ = bone_normalized.decompose()
    bone_mat = Matrix.LocRotScale(loc, rot, Vector((1,1,1)))  # Force scale=1
    ibm = bone_mat.inverted()
    # Local transform = parent_mat.inv @ bone_mat (or bone_mat for roots)
```

### Step 6: Export Meshes (Vertices + Faces + Skinning)
```python
# For each mesh object:
# 1. Get evaluated mesh (applies modifiers) or use original
# 2. Triangulate via bmesh (non-destructive — only temporary mesh)
# 3. Transform vertices: normalize_mat @ obj.matrix_world @ v.co
# 4. Map faces to material categories
# 5. Determine skinning:
#    - BONE parent → all verts assigned to parent bone (rigid)
#    - ARMATURE modifier → read vertex groups (multi-bone weights, up to 4 per vert)

# Triangulation (non-destructive):
bm = bmesh.new()
bm.from_mesh(mesh_data)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
tri_mesh = bpy.data.meshes.new("_temp_tri")
bm.to_mesh(tri_mesh)
bm.free()
# ... export from tri_mesh ...
bpy.data.meshes.remove(tri_mesh)  # Cleanup
```

### Step 7: Sort & Fragment
```python
# 1. Sort ALL faces (from all meshes combined) by avgZ — painter's algorithm
# 2. Split into parts of ~MAX_FACES_PER_PART faces each
# 3. Each part gets ONLY its used vertices (remapped indices starting at 1)
# 4. Each part gets its own factorized skinning data

all_faces.sort(key=lambda f: average_z_of_face(f))
parts = [all_faces[i:i+MAX_FACES] for i in range(0, len(all_faces), MAX_FACES)]
```

### Step 8: Export Animations (ABSOLUTE local transforms)
```python
# ⚠️ DO NOT reset matrix_basis before sampling!
# ⚠️ Animations are ABSOLUTE (not deltas from rest pose)

for action in actions:
    armature.animation_data.action = action
    armature.data.pose_position = 'POSE'

    for frame in range(start, end + 1):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()

        for bone_name in bone_order:
            pose_bone = armature.pose.bones[bone_name]
            pose_world = arm_world @ pose_bone.matrix
            pose_norm = normalize_mat @ pose_world
            loc, rot, _ = pose_norm.decompose()
            pose_mat = Matrix.LocRotScale(loc, rot, Vector((1,1,1)))
            local_mat = parent_mat.inverted() @ pose_mat
            # Store: translation + rotation as WXYZ
```

### Step 9: Optimize Animation Channels
```python
# Three outcomes per bone per path (translation, rotation):
#   1. Constant AND matches posed-rest → REMOVE (safe)
#   2. Constant but DIFFERS from posed-rest → KEEP as 2-keyframe
#   3. Varies across frames → KEEP full channel
EPSILON = 0.0001
```

### Step 10: Verify & Write Files
```python
# ⚠️ MANDATORY verification before writing:

# 1. Skin matrices = Identity at posed rest (max deviation < 0.001)
for i in range(joint_count):
    skin = world_mats[i] @ ibms[i]
    deviation = max(abs(skin[r][c] - identity[r][c]) for r, c in itertools.product(range(4), range(4)))
    assert deviation < 0.001

# 2. Write Part files (skeleton in first part only)
# 3. Write Animation files (split by ANIM_FILE_SPLIT or auto-split)
```

---

## ⚠️ CRITICAL: "Posed Rest" vs "Pure Rest" (THE #1 EXPORT TRAP)

### Problem
Many Blender models have a `matrix_basis` residual on pose bones — a "default pose" (arms down, fingers closed, legs bent) that is NOT the rest pose. This residual persists even with NO action assigned.

### Why It Matters
If you use `bone.matrix_local` (pure REST) for the skeleton but `pose_bone.matrix` (which includes `matrix_basis`) for animations, you get a **coordinate space mismatch**. A tiny difference in Blender gets amplified by `armature.matrix_world` (often scale=100) × `normalize_mat` (scale ~30-50) = **massive offset** in normalized space.

### The Rule
**Skeleton, vertices, and animations must ALL use the SAME reference pose = "posed rest".**

**"Posed Rest"** = armature with NO action assigned, `pose_position='POSE'`, `matrix_basis` applied naturally. This IS the model's actual default appearance.

```python
# ✅ CORRECT: Use "posed rest" for EVERYTHING
armature.animation_data.action = None
armature.data.pose_position = 'POSE'       # matrix_basis applies
bpy.context.view_layer.update()

bone_world = arm_world @ pose_bone.matrix  # Includes matrix_basis ✓
vertex_world = obj.matrix_world @ v.co     # obj.matrix_world follows posed bones ✓

# ❌ WRONG: Using pure REST for skeleton
armature.data.pose_position = 'REST'       # Uses bone.matrix_local
# → IBMs won't match pose_bone.matrix during animation → huge offset
```

### Verification
At posed rest (no action), `skinMatrix = worldMatrix × IBM` must equal **Identity** for all bones. Max acceptable deviation: 0.001. If deviation > 1.0, there is a coordinate space mismatch.

### Why NEVER Reset `matrix_basis`
`matrix_basis` IS the model's default pose — NOT an animation artifact. If you reset it before sampling, bones without keyframes in the current action snap to pure REST instead of their intended default position (arms horizontal, fingers open, etc.).

### Why Static Channel Optimization Must Compare Against Posed Rest
When removing constant animation channels:
- ✅ Remove if constant AND matches **posed rest** (epsilon 0.0001) — bone stays at default
- ✅ Keep as 2-keyframe if constant but **differs from posed rest** — bone needs this value
- ❌ NEVER remove just because constant between frames — may be constant at a non-default value!

---

## Animation System Format

### Data Format
**All data is in the SAME normalized coordinate space:**
- **Vertices:** Centered, scaled to ~200 units max dimension, in posed rest position
- **IBMs:** From posed rest (`pose_bone.matrix`), scale forced to 1
- **Rest pose:** Local transforms from posed rest, scale = `{1, 1, 1}`
- **Animations:** **ABSOLUTE** local transforms per keyframe (NOT deltas)

**Quaternion format:** WXYZ in data files (Blender native: `{w, x, y, z}`).
`SkeletalAnimUtil` converts to XYZW internally in `buildSkeleton()` and `sampleQuat()`.

**Joint indices:** 1-based in data files (Luau array convention). No `+1` needed in `sampleAnimation()`.

**Skinning patterns:** 0-based bone indices in the patterns table. The `+1` conversion to Luau 1-based is done in `skinVerticesFact()` at runtime.

### Why ABSOLUTE Transforms (not deltas)
The export samples the full evaluated pose at each frame, computes local transform relative to parent (in normalized space), and stores directly:
- Each keyframe = final local TRS for that bone at that time
- Runtime writes values directly to `localTransforms[jointIdx]`
- No delta composition, no `matrix_basis`, no rest-pose multiplication
- Avoids all FCurve delta interpretation complexity

### Runtime Pipeline (SkeletalAnimUtil)
```
sampleAnimation()  →  writes absolute local transforms to skeleton.localTransforms
updateSkeleton()   →  computes worldMatrices (parent chain) and skinMatrices (world × IBM)
skinVerticesFact() →  transforms each vertex by its bone's skinMatrix
```

---

## Multi-Mesh Export (Universal)

### Supported Mesh Types
The export handles ANY combination of:

| Mesh Parent Type | Skinning | Example |
|-----------------|----------|---------|
| **BONE parent** (rigid) | All vertices → parent bone | Robot torso, head, limbs |
| **ARMATURE modifier** (multi-bone) | Vertex groups → up to 4 bones/weights | Hands, clothing, flexible parts |
| **No parent** (excluded) | Not exported | Helper objects, lights |

### How Multi-Mesh Works
1. **All meshes share ONE skeleton** (from the armature)
2. **All meshes share ONE normalization** (bounding box across all meshes)
3. **Vertices from all meshes are merged** into one global vertex list
4. **Faces are Z-sorted across all meshes** before fragmenting into parts
5. **Each part gets only its used vertices** (remapped indices)
6. **Skinning is per-vertex**, regardless of which mesh the vertex came from

### Triangulation
All meshes are triangulated at export via `bmesh.ops.triangulate()`. This is **non-destructive** — the original Blender mesh is preserved; only a temporary copy is triangulated for export.

---

## File Size & Optimization

### Limits
| Parameter | Value | Notes |
|-----------|-------|-------|
| Max faces/file | **~1900** | Using `c=index` instead of RGB |
| Max vertices/file | **~2500** | With vertex optimization per part |

### Category Index Format
```luau
-- ❌ WRONG: Verbose RGB colors (huge files)
{ verts = { 1, 2, 3 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Category index (60% smaller)
{ verts = { 1, 2, 3 }, c = 1 }
```

### Factorized Skinning Format
```luau
-- ❌ WRONG: Repeated full entries (huge files, typecheck errors)
ModelData.skinning = {
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Repeated 100s of times!
}

-- ✅ CORRECT: Patterns table + index array (~40% smaller)
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Root
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Head
  -- ... one entry per unique weight combination
}
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, 2, ...}  -- Pattern index per vertex
```

For multi-bone skinning (ARMATURE modifier), patterns contain actual multi-bone weights:
```luau
[42] = {j = {9, 10, 11, 0}, w = {0.45, 0.35, 0.20, 0.0}},  -- 3-bone blend
```

---

## Anti-Flickering System (3 Techniques Combined)

### Problem
Faces with nearly equal depth cause z-fighting flickering during rotation.

### Solution

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
local function processFaces(self, vertices, faces, ..., depthBias: number?)
    local bias = depthBias or 0
    local avgZ = (sumZ / #transformed) + bias
    table.insert(self.projectedFaces, {
        path = facePath, depth = avgZ, color = litColor,
        index = #self.projectedFaces + 1,
    })
end
```

**depthBias depends on how parts are split:**
```luau
-- Z-sorted slices (faces sorted by avgZ before splitting) → no bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 0)

-- Separate objects (robot body/head) → large bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 10)
processFaces(self, vertsC, facesC, ..., 20)

-- Wall-mounted overlay → force to front
processFaces(self, screenVerts, screenFaces, ..., 100)
```

#### 3. Stable Sort with Index Tiebreaker
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

### Recommended Values
| Parameter | Value | When |
|-----------|-------|------|
| Z_EPSILON | 0.001 | Always |
| depthBias (Z-sliced) | 0, 0, 0 | Parts = faces sorted by avgZ |
| depthBias (separate objects) | 0, 10, 20 | Parts = distinct mesh objects |
| depthBias (wall overlay) | 99, 100 | Must draw on top |
| faceExpansion | 0.05 | Always |
| brightness | 50 | Always |

---

## Multi-Zone Coloring

1. **In Blender:** Create one material per zone (e.g., M_Body, M_Head, M_Arms)
2. **Assign materials** to faces
3. **Export** — each material becomes `c=1..N` (sorted alphabetically)
4. **In Node Script:** Expose `Input<Color>` per zone, build colorMap

```luau
local colorMap: { [number]: Color } = {
    [1] = self.bodyColor,
    [2] = self.headColor,
    [3] = self.armsColor,
}
local faceColor = colorMap[face.c] or self.bodyColor
```

---

## Wall-Mounted Surfaces (Screens, Panels)

**Problem:** Flat surfaces on walls Z-fight at rotation angles.

**Solution:** Decouple visual position from sort order:
1. Remove the surface from Blender
2. Re-export Part files
3. Hardcode vertices/faces in Node Script (`advance()`)
4. Position close to wall (1-2 normalized units)
5. Use `depthBias=99/100` to force draw order

```luau
local screenVerts = { {x=-51, y=48.66, z=-8.82}, ... }
local screenFaces = { {verts={1,2,3}, c=12}, {verts={1,3,4}, c=12} }
processFaces(self, screenVerts, screenFaces, ..., 100)
```

---

## Coordinate System (Blender Z-up to Rive)

**Blender uses Z-up, Rive screen is X-right, Y-down, Z-into-screen.**

Rotation mapping:
- `rotationY` (yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (pitch) → Tilt forward/backward
- `rotationZ` (roll) → Tilt left/right

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
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}
```

### Animation Data File (e.g., ModelAnim1Data.luau)
```luau
ModelData.animations = {
  ["walk"] = {
    name = "walk",
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

## Rive Luau Specifics

### table.sort Requires Type Annotations
```luau
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    return a.depth < b.depth
end)
```

### Type Casting for Untyped Data
```luau
local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
```

### Path Modification in draw() FORBIDDEN
```luau
-- ✅ Build paths in advance(), only draw in draw()
function advance(self, seconds)
    local facePath = Path.new()
    facePath:moveTo(...)
    facePath:close()
end
```

### Auto-Rotation Requires markNeedsUpdate
```luau
local function advance(self: Model3D, seconds: number): boolean
    if self.rotationSpeed ~= 0 then
        self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
        if self.context then
            self.context:markNeedsUpdate()
        end
    end
    if self.animationEnabled and self.context then
        self.context:markNeedsUpdate()
    end
    return true
end
```

---

## Skinning in Node Script (Factorized)

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

## Export Workflow

### Option A: blender_to_rive.py (Standalone Script)
1. Open your `.blend` file
2. Configure settings at top of script:
   - `MODEL_NAME` — prefix for all output files
   - `ARMATURE_NAME` — name of armature (or `None` for auto-detect)
   - `EXCLUDE_MESHES` — set of mesh names to skip
   - `EXCLUDE_ACTIONS` — set of action names to skip
   - `ANIM_FILE_SPLIT` — manual animation grouping (or `None` for auto)
3. Run script (`Alt+P` in Text Editor)
4. Copy generated `.luau` files to Rive project

### Option B: Claude Code + Blender MCP (Preferred)
1. Connect Blender MCP
2. Claude analyzes the model (meshes, bones, materials, vertex count)
3. Claude runs the 10-step export logic via Python in Blender
4. Claude generates the `.luau` files directly
5. Claude verifies the output (skin matrices, vertex roundtrip)

Both produce the same output format.

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| **Body parts dislocated/scattered** | **Different reference poses for skeleton vs vertices vs animations** | **Use "posed rest" for ALL exports** |
| **Head/shoulders offset** | **Skeleton uses pure REST, animations use posed REST** | **Use `pose_bone.matrix`, not `bone.matrix_local`** |
| **Arms horizontal / T-pose in Idle** | **`matrix_basis` reset or static channels removed** | **NEVER reset matrix_basis; keep constant-but-different channels** |
| **Huge offset on root bone** | **`matrix_basis` × armature_scale × normalize_scale** | **Detect matrix_basis residuals first (Step 2)** |
| **Bones snap to wrong pose** | **Action lacks keyframes, matrix_basis was reset** | **Keep matrix_basis; posed-rest covers default** |
| Faces flickering | Z-fighting from coplanar faces | 3-technique anti-flickering |
| Flickering between Parts | Parts compete for same depth | depthBias: 0/10/20 or 0/0/0 |
| Screen flickers on wall | Coplanar with wall | Hardcode + depthBias=100 |
| Model disappears when animated | Data format mismatch | Re-export via Blender MCP |
| Animation looks wrong | Deltas instead of absolute | Ensure ABSOLUTE local transforms |
| Quaternion issues | WXYZ vs XYZW | Data=WXYZ, runtime converts |
| `localTransforms[0]` nil | 0-based jointIndex | Use 1-based in data files |
| File too large / typecheck | Too many skinning entries | Use factorized skinning |
| Model rotates wrong axis | Y-up vs Z-up confusion | Yaw = XY rotation for Z-up |
| `rotationSpeed` does nothing | Missing markNeedsUpdate | Store context |
| Non-triangular faces | Quads/ngons in mesh | Triangulate via bmesh at export |
| `StructRNA removed` error | Evaluated mesh freed too early | Use separate temp mesh for bmesh |
| Colors all same | Not using category index | Use `c=index` format |

---

## Pre-Export Checklist

- [ ] **Step 2: `matrix_basis` check** — detect residuals, determine posed-rest mode
- [ ] Model analyzed (meshes, vertex/polygon count, materials, parent types)
- [ ] **Normalization computed in POSED REST** (all meshes combined)
- [ ] **Skeleton IBMs from posed rest** (`pose_bone.matrix`)
- [ ] **Vertices exported in posed rest** (`pose_position='POSE'`, no action)
- [ ] **Meshes triangulated** (via bmesh, non-destructive)
- [ ] **Animations sampled WITHOUT resetting `matrix_basis`**
- [ ] **Static channels compared against POSED REST**
- [ ] **Verification: skin matrices = Identity** (deviation < 0.001)
- [ ] Materials → category indices (sorted alphabetically)
- [ ] `c=index` format (NOT RGB)
- [ ] Faces sorted by avgZ before fragmenting
- [ ] Each part has only its used vertices (remapped indices)
- [ ] **Factorized skinning** (patterns + index)
- [ ] **ABSOLUTE local transforms** (not deltas)
- [ ] **WXYZ quaternions** in data files
- [ ] **1-based joint indices** in data files
- [ ] `context:markNeedsUpdate()` for auto-rotation/animation
- [ ] Yaw rotates in XY plane (Z-up)
- [ ] **Anti-flickering**: index field + depthBias + Z_EPSILON sort
- [ ] **Multi-zone coloring** (if applicable): materials → colorMap
- [ ] **Wall-mounted surfaces** (if any): hardcode + depthBias=100

---

## Performance Notes

- **~5000 faces** renders smoothly with table.sort
- Each frame: transform → cull → light → project → sort → draw
- Paths created in `advance()`, only drawn in `draw()`
- Factorized skinning: minimal overhead (one lookup per vertex)
- depthBias: zero runtime cost (just shifts depth value)

---

## Default Values

```luau
rotationSpeed = 10,       -- Visible rotation for testing
brightness = 50,          -- Base lighting 50%
faceExpansion = 0.05,     -- Visual gap between faces
backfaceCulling = true,   -- Cull back-facing polygons
animationSpeed = 1,       -- Normal playback speed
```

---

## Workflow Orchestration

### 1. Plan Mode Default
Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions). STOP and re-plan if something goes sideways.

### 2. Subagent Strategy
Offload research, exploration, and parallel analysis to subagents. One task per subagent.

### 3. Self-Improvement Loop
After ANY correction: update `tasks/lessons.md`. Write rules to prevent the same mistake.

### 4. Verification Before Done
Never mark complete without proving it works. "Would a staff engineer approve this?"

### 5. Demand Elegance
For non-trivial changes: "is there a more elegant way?" Skip for simple fixes.

### 6. Autonomous Bug Fixing
Given a bug report: just fix it. No hand-holding required.

## Task Management
**Plan First** → **Verify Plan** → **Track Progress** → **Explain Changes** → **Document Results** → **Capture Lessons**

## Core Principles
**Simplicity First** · **No Laziness** · **Minimal Impact** · **Root Causes Only**
