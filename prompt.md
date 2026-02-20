# Blender to Rive 3D Export — AI Agent Prompt

> **For Claude Code with Blender MCP**: Universal conversion of ANY Blender 3D model to Rive-compatible Luau code.

---

## STOP! Before You Start

**Read these 16 rules or face hours of debugging:**

1. **ALL static data in ONE single Blender MCP call** — Skeleton (IBMs + restPose), normalization bounds, and vertices MUST come from the SAME depsgraph state. The evaluated mesh is non-deterministic across separate `execute_blender_code` calls. Do everything in ONE call.
2. **NEVER reset `matrix_basis`** before sampling animations. It IS the model's default pose.
3. **ALWAYS prefer Blender MCP** over standalone Python scripts — more reliable.
4. **DON'T require Mesh3DUtil for static models** — Inline the math functions
5. **USE flat arrays** for vertices (stride 3) and faces (stride 4) — ~60% smaller files
6. **SORT faces by avgZ** — At export time, then table.sort at runtime
7. **STORE `context`** — Required for `markNeedsUpdate()` (auto-rotation)
8. **BLENDER Z-UP**: Yaw = XY rotation, NOT Y-axis rotation
9. **FACTORIZE SKINNING** — Use patterns table + index array (~40% smaller files)
10. **USE ANTI-FLICKERING** — table.sort + index tiebreaker + Z_EPSILON (0.005)
11. **USE `depthBias`** — 0/10/20 for object-based parts, 0 for Z-sliced parts, 99/100 for wall overlays
12. **Static channel optimization: compare against rest pose** — NOT just frame-to-frame constancy. Keep constant-but-different-from-rest as 2-keyframe channels.
13. **ANIMATIONS = ABSOLUTE transforms** — NOT deltas from rest pose. Export final local TRS per keyframe.
14. **RE-EXPORT TRAP: Quaternion sign ambiguity** — `decompose()` is NOT unique (`q` = `-q`). When re-exporting animations in a new session, compare rest local quaternion dot product vs file. If dot < 0.95 -> use `matrix_basis` delta. Non-keyed bones -> exact file rest values. See Step 8b.
15. **NEVER assume single-material = single color** — Atlas textures encode multiple color zones via UV. ALWAYS sample the texture at each face's UV coords with QUANT_STEP=0.005, and cluster into distinct zones. Each zone gets its own `Input<Color>`.
16. **Depsgraph non-determinism** — `bpy.data.meshes.new_from_object(eval_obj)` returns DIFFERENT results across separate Blender MCP `execute_blender_code` calls (depsgraph state pollution). Solution: do EVERYTHING in ONE call.

---

## Your Task

Convert ANY Blender 3D model into functional Rive Node Script Luau code with:
- **Multi-mesh support**: Any number of mesh objects linked to one armature
- **Two skinning modes**: BONE-parented (rigid) AND armature-modifier (multi-bone weights)
- **Automatic triangulation**: via bmesh (non-destructive, preserves original)
- **Polygon-based fragmentation**: ~2950 faces per file with indexed colors
- **Skeletal animation**: Any number of bones, any number of animations
- **Color zone detection**: Multi-material OR Atlas texture UV sampling (QUANT_STEP=0.005)
- **Vertex optimization**: Only used vertices per fragment
- **Factorized skinning**: Patterns table + index array
- **Flat array format**: Vertices (stride 3) and faces (stride 4) for ~60% file reduction
- **Shared times**: Factorized duplicate time arrays in animation files (~10% savings)
- **Anti-flickering**: table.sort + index tiebreaker + depthBias
- **Wall-mounted surfaces**: Hardcoded in Node Script + depthBias
- **Verification**: Skin matrices = Identity + skinned vertices roundtrip

---

## Universal 10-Step Export Process

**CRITICAL: Steps 4-8 MUST run in ONE single `execute_blender_code` call** to ensure consistent depsgraph state. The evaluated mesh is NON-DETERMINISTIC across separate calls.

### Step 1: Discover Model
```python
# Auto-detect:
# - Armature (first ARMATURE object, or by name)
# - All MESH children (exclude cameras, empties, helpers)
# - Parent type: BONE (rigid) vs ARMATURE modifier (multi-bone)
# - Color zones: multiple materials (sorted alphabetically -> c=1..N)
#   OR single Atlas material -> UV-sample texture per face -> quantize & cluster into zones
# - Total vertex/polygon count
```

### Step 2: Detect `matrix_basis` Residuals
```python
armature.animation_data.action = None
armature.data.pose_position = 'POSE'
bpy.context.view_layer.update()

for pb in armature.pose.bones:
    loc, rot, _ = pb.matrix_basis.decompose()
    if loc.length > 0.0001 or abs(rot.w - 1) + abs(rot.x) + abs(rot.y) + abs(rot.z) > 0.001:
        print(f"  {pb.name} has residual matrix_basis -> MUST use posed rest")
```

### Step 3: Build Bone Order
```python
# DFS from root bones (sorted alphabetically), consistent ordering for:
# joint indices, parent arrays, IBMs, rest pose, animation channels
bone_order = []
def dfs(bone):
    bone_order.append(bone.name)
    for child in sorted(bone.children, key=lambda b: b.name):
        dfs(child)
for root in sorted(armature.data.bones, key=lambda b: b.name):
    if root.parent is None:
        dfs(root)
```

### Step 4: Compute Normalization (from EVALUATED mesh)
```python
# Use evaluated mesh for bounds — includes matrix_basis effects (e.g. foot positions)
# MUST be in the SAME execute_blender_code call as Steps 5-8
depsgraph = bpy.context.evaluated_depsgraph_get()

for mesh_obj in mesh_objects:
    eval_obj = mesh_obj.evaluated_get(depsgraph)
    eval_mesh = bpy.data.meshes.new_from_object(eval_obj)
    for v in eval_mesh.vertices:
        world_pos = mesh_obj.matrix_world @ v.co
        update_bounds(world_pos)
    bpy.data.meshes.remove(eval_mesh)

center = (min_coord + max_coord) / 2
scale_factor = TARGET_SIZE / max_dimension  # TARGET_SIZE = 200
normalize_mat = Matrix.Scale(scale_factor, 4) @ Matrix.Translation(-center)
```

### Step 5: Export Skeleton (from POSED REST — `pose_bone.matrix`)
```python
# Use pose_bone.matrix (POSED REST) — includes matrix_basis effects
# MUST be in the SAME call as normalization + vertices
arm_world = armature.matrix_world

for bone_name in bone_order:
    pose_bone = armature.pose.bones[bone_name]
    bone_world = arm_world @ pose_bone.matrix     # <- POSED REST
    bone_normalized = normalize_mat @ bone_world
    loc, rot, _ = bone_normalized.decompose()
    bone_mat = Matrix.LocRotScale(loc, rot, Vector((1,1,1)))  # Force scale=1
    ibm = bone_mat.inverted()
    # Rest pose local transform = parent_mat.inv @ bone_mat
```

### Step 6: Export Meshes
```python
# CRITICAL: Use EVALUATED mesh — same depsgraph as normalization + skeleton
# MUST be in the SAME call as Steps 4-5
# Per mesh object:
# 1. Get evaluated mesh from depsgraph
# 2. Triangulate via bmesh (non-destructive - only temporary mesh)
# 3. Transform vertices: normalize_mat @ obj.matrix_world @ v.co
# 4. Store as flat arrays: x, y, z, x, y, z, ... (stride 3)
# 5. Map faces -> flat arrays: v1, v2, v3, category, ... (stride 4)
# 6. Skinning (from mesh vertex groups):
#    - BONE parent -> rigid (all verts -> parent bone)
#    - ARMATURE modifier -> vertex groups (up to 4 bones, weights normalized)

eval_obj = mesh_obj.evaluated_get(depsgraph)
eval_mesh = bpy.data.meshes.new_from_object(eval_obj)
bm = bmesh.new()
bm.from_mesh(eval_mesh)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
tri_mesh = bpy.data.meshes.new("_temp_tri")
bm.to_mesh(tri_mesh)
bm.free()
# ... export from tri_mesh ...
bpy.data.meshes.remove(tri_mesh)
bpy.data.meshes.remove(eval_mesh)
```

### Step 7: Sort & Fragment
```python
# Sort ALL faces by avgZ (painter's algorithm)
# Split into ~2950-face parts (with flat arrays)
# Each part: only used vertices (remapped 1-based), own skinning data
# Output as flat arrays
```

### Step 8: Export Animations
```python
# DO NOT reset matrix_basis!
# Sample ABSOLUTE local transforms per frame per bone
# MUST use the SAME normalize_mat from Step 4
# Store: translation {x,y,z}, rotation {w,x,y,z} (WXYZ)
```

### Step 8b: Re-Export Safe Sampling (when Part files already exist)
```python
# ONLY when re-exporting animations for an existing model
# 1. Parse rest pose from existing Part file
# 2. Detect mismatched bones: dot(blender_rest_local.rot, file_rest_local.rot) < 0.95
# 3. Get keyframed bone names from action FCurves
# 4. Three-tier hybrid:
#    - NOT keyed -> exact file rest values (translation + rotation)
#    - Keyed + match (dot >= 0.95) -> file_rest_local x (blender_rest_local_inv x anim_local)
#    - Keyed + mismatch (dot < 0.95) -> file_rest_local x (rest_basis_inv x frame_basis)
# 5. Animation composition: merge Idle channels with partial animations
#    (e.g., Yes = Idle body breathing + Head nod from Yes action)
```

### Step 9: Optimize Channels
```python
# Per bone per path:
# - Constant AND matches rest pose -> REMOVE
# - Constant but DIFFERS from rest pose -> 2-keyframe
# - Varies -> full channel
```

### Step 10: Verify & Write
```python
# MANDATORY: skin matrices = Identity at posed rest (< 0.001)
# Write: Part files (skeleton in first) + Animation files (separate)
# Vertices and faces as flat arrays
# sharedTimes factorized per clip
```

---

## Flat Array Data Format

### Vertices (stride 3)
```luau
-- x, y, z, x, y, z, ...
ModelData.vertices = {
  10.825, -18.875, -1.141,
  11.296, -19.324, 1.685,
}
-- Access: base = (i - 1) * 3; vx = vertices[base + 1]
-- Count: #vertices / 3
```

### Faces (stride 4)
```luau
-- v1, v2, v3, category, v1, v2, v3, category, ...
ModelData.faces = {
  4150, 4151, 4152, 1,
  4151, 4150, 4153, 1,
}
-- Access: fBase = fi * 4; vi1 = faces[fBase + 1], category = faces[fBase + 4]
-- Count: #faces / 4
```

### Post-Export Optimization (Option A only)
```bash
python3 convert_flat.py           # Vertices/faces -> flat arrays (~60% smaller)
python3 convert_shared_times.py   # Factorize duplicate times in animations (~10% smaller)
```
Both scripts are idempotent (safe to re-run) and preserve data they don't modify.
Option B (Blender MCP single-call) generates flat arrays + sharedTimes directly.

---

## Animation System

### Data Format
**All data in SAME normalized coordinate space (~200 units max):**
- **Quaternions:** WXYZ in files (Blender native). `SkeletalAnimUtil` converts to XYZW internally.
- **Joint indices:** 1-based in files (Luau arrays).
- **Skinning patterns:** 0-based bone indices. Runtime adds `+1`.
- **Transforms:** ABSOLUTE (not deltas).
- **Vertices:** Flat arrays, stride 3, from evaluated mesh.
- **Faces:** Flat arrays, stride 4.

### Runtime Pipeline
```
sampleAnimation()  ->  writes absolute local transforms
updateSkeleton()   ->  computes worldMatrices + skinMatrices
skinVerticesFact() ->  transforms vertices by bone skinMatrix (flat array in/out)
```

### Static Channel Optimization (CRITICAL)
```python
EPSILON = 0.0005
if is_constant_across_frames:
    if matches_rest_pose(epsilon=EPSILON):
        pass  # REMOVE - sampleAnimation resets to rest
    else:
        keep_as_2_keyframe(times=[0, duration])  # KEEP - differs from default
else:
    keep_full_channel()  # KEEP - values vary
```

---

## File Size Limits

| Parameter | Value | Notes |
|-----------|-------|-------|
| Max faces/file | **~2950** | With flat format (stride 4) |
| Max vertices/file | **~3600** | With vertex optimization |

**Flat arrays** (stride 3 vertices, stride 4 faces) -> ~60% smaller.
**Factorized skinning** (patterns + index) -> ~40% smaller.
**Animations** in separate files from Part data.

---

## Multi-Mesh Support

| Mesh Parent Type | Skinning | Example |
|-----------------|----------|---------|
| **BONE parent** (rigid) | All verts -> parent bone | Torso, head, limbs |
| **ARMATURE modifier** | Vertex groups -> up to 4 bones | Hands, flexible parts |
| **No parent** | Excluded from export | Helpers, lights |

All meshes share ONE skeleton, ONE normalization. Vertices merged as flat arrays, faces Z-sorted across all meshes before fragmenting.

---

## Anti-Flickering (3 Techniques)

### 1. ProjectedFace with Index
```luau
export type ProjectedFace = {
    path: Path, depth: number, color: Color,
    index: number,  -- Stable sort tiebreaker
}
```

### 2. depthBias on processFaces
```luau
-- Z-sliced parts -> depthBias = 0 for all
-- Separate objects -> depthBias = 0, 10, 20
-- Wall overlay -> depthBias = 99, 100
```

### 3. Stable Sort
```luau
local Z_EPSILON = 0.005
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local d = a.depth - b.depth
    if math.abs(d) < Z_EPSILON then return a.index < b.index end
    return a.depth < b.depth
end)
```

---

## Multi-Zone Coloring

Color zones are detected via **two methods** — always check both:

### Method A: Multiple Materials
1. Blender: one material per zone (e.g., M_Body, M_Head, M_Arms)
2. Export: each material -> category `1..N` (sorted alphabetically)

### Method B: Atlas Texture UV Sampling
When a model has **1 material + a texture** (common with game-ready models):
1. Sample texture pixels at each face's UV coords
2. Quantize sampled colors (QUANT_STEP=0.005 — NOT 0.02 which merges similar grays)
3. Each unique quantized color = one zone
4. Assign category `1..N` per zone (sorted alphabetically by name)

```python
# UV-sample per face:
QUANT_STEP = 0.005  # Fine-grained to preserve distinct zones (0.02 is too aggressive!)
for poly in mesh.polygons:
    for li in poly.loop_indices:
        uv = uv_layer.data[li].uv
        px, py = int(uv.x * w) % w, int(uv.y * h) % h
        # Read pixel at (px, py) -> accumulate RGB
    # Quantize -> map to zone -> category
```

### Both Methods -> Same Runtime Output
Node Script: `Input<Color>` per zone + `getTintColor(self, category)` lookup

```luau
local function getTintColor(self: Model3D, category: number): Color
    if category == 1 then return self.darkGrayColor
    elseif category == 2 then return self.greenColor
    elseif category == 3 then return self.orangeColor
    end
    return self.greenColor -- fallback
end
-- In processFaces: category = faces[fBase + 4]
```

---

## Wall-Mounted Surfaces

1. Remove surface from Blender mesh
2. Hardcode vertices/faces in Node Script (`advance()`) as flat arrays
3. Position 1-2 units from wall + `depthBias=99/100`

```luau
local screenVerts = { -51, 48.66, -8.82, -51, 40.00, -8.82, -30, 48.66, -8.82, -30, 40.00, -8.82 }
local screenFaces = { 1, 2, 3, 12, 1, 3, 4, 12 }
processFaces(self, screenVerts, screenFaces, ..., 100)
```

---

## Factorized Skinning

```luau
-- Patterns: one entry per unique weight combination
local S = {
  [0] = {j = {0, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  [1] = {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},
  -- Multi-bone example:
  [42] = {j = {9, 10, 11, 0}, w = {0.45, 0.35, 0.20, 0.0}},
}
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, 2, ...}  -- Pattern index per vertex
```

### Runtime Usage (Flat Arrays)
```luau
local function skinVerticesFact(skeleton, vertices: {number}, skinningPatterns, skinningIndex): {number}
    local vertCount = #skinningIndex
    local result: {number} = {}
    for i = 1, vertCount do
        local base = (i - 1) * 3
        local vx, vy, vz = vertices[base + 1], vertices[base + 2], vertices[base + 3]
        local skin = skinningPatterns[skinningIndex[i]]
        local sx, sy, sz = 0.0, 0.0, 0.0
        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- 0-based -> 1-based
            local weight = skin.w[k]
            if weight > 0 then
                -- Transform vertex by skinMatrix[jointIdx]
                local skinMat = skeleton.skinMatrices[jointIdx]
                local tx, ty, tz = M.mat4TransformPoint(skinMat, vx, vy, vz)
                sx = sx + tx * weight
                sy = sy + ty * weight
                sz = sz + tz * weight
            end
        end
        result[base + 1] = sx
        result[base + 2] = sy
        result[base + 3] = sz
    end
    return result
end
```

---

## Coordinate System (Blender Z-up)

- `rotationY` (Yaw) -> Rotate in XY plane (turntable)
- `rotationX` (Pitch) -> Tilt forward/back
- `rotationZ` (Roll) -> Tilt left/right

```luau
-- Yaw: x,y rotation (cosY/sinY)
-- Pitch: y,z rotation (cosX/sinX)
-- Roll: x,y rotation (cosZ/sinZ)
```

---

## Rive Luau Restrictions

### NO `table.create()` — Roblox-Only
```luau
-- WRONG: crashes at runtime (Roblox extension, not in Rive)
local result = table.create(6000)

-- CORRECT: standard Luau
local result = {}
```

### Constructor MUST Mirror ALL Type Fields
Every field declared in the `type` MUST also appear in the `return function()` constructor with an initial value. Missing field -> `nil` at runtime -> crash.

### table.sort MUST Have Type Annotations
```luau
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    return a.depth < b.depth
end)
```

### Type Casting for Flat Array Data
```luau
local vertices = (PartAData :: any).vertices :: { number }
local faces = (PartAData :: any).faces :: { number }
local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
```

### Path Modification in draw() FORBIDDEN
```luau
-- Build paths in advance(), only draw in draw()
```

### Auto-Rotation Requires markNeedsUpdate
```luau
if self.rotationSpeed ~= 0 and self.context then
    self.context:markNeedsUpdate()
end
```

---

## Output Data Structure

### Part Data File
```luau
ModelData.skeleton = {  -- First part only
  jointCount = N,
  jointParents = { nil, 1, 2, ... },
  inverseBindMatrices = { {16 floats}, ... },
  restPose = { { translation = {x,y,z}, rotation = {w,x,y,z}, scale = {1,1,1} }, ... },
}

-- Flat vertex array (stride 3)
ModelData.vertices = { 10.825, -18.875, -1.141, 11.296, -19.324, 1.685, ... }

-- Flat face array (stride 4)
ModelData.faces = { 4150, 4151, 4152, 1, 4151, 4150, 4153, 1, ... }

ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}
```

### Animation Data File
```luau
ModelData.animations = {
  ["walk"] = {
    name = "walk", duration = 1.5,
    sharedTimes = {
      {0, 0.033, 0.067, 0.1, ...},  -- Factorized time arrays
    },
    channels = {
      { jointIndex = 1, path = "rotation", timeRef = 1, values = {w,x,y,z,...} },
      { jointIndex = 1, path = "translation", timeRef = 1, values = {x,y,z,...} },
    },
  },
}
```

**Key:** jointIndex = 1-based, `timeRef` = 1-based index into `sharedTimes`, rotation = WXYZ, transforms = ABSOLUTE, vertices = flat stride 3, faces = flat stride 4.

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| **Model collapses into star/spikes** | **IBMs and restPose from different coordinate spaces** | **Use same source (pose_bone.matrix) for BOTH, in ONE call** |
| **Model explodes during animation** | **Part files and Anim files have different normalization** | **Everything in ONE `execute_blender_code` call** |
| **Arms in T-pose / horizontal** | **`matrix_basis` reset or channels removed** | **Never reset; keep constant-but-different** |
| **Huge offset on root** | **matrix_basis amplified by scale** | **Detect residuals first (Step 2)** |
| **Bones snap to wrong pose** | **No keyframes + reset matrix_basis** | **Keep matrix_basis; use posed-rest** |
| **Feet/limbs dislocated from body** | **Bounds and vertices from different spaces** | **Bounds + vertices + skeleton all from SAME call** |
| Faces flickering | Z-fighting | 3-technique anti-flickering |
| Animation wrong | Deltas not absolute | ABSOLUTE local transforms |
| Quaternion issues | WXYZ/XYZW mismatch | Data=WXYZ, runtime converts |
| File too large | Repeated skinning | Factorized skinning + flat arrays |
| Non-triangular faces | Quads/ngons | Triangulate via bmesh |
| `StructRNA removed` | Freed evaluated mesh | Use temp mesh copy |
| `rotationSpeed` broken | No markNeedsUpdate | Store context |
| Colors all same | Wrong category read | `faces[fBase + 4]` for category |
| **All faces one color despite texture** | **Atlas UV sampling QUANT_STEP too large** | **Use QUANT_STEP=0.005, not 0.02** |
| **Fingers stretched on re-export** | **Quaternion sign ambiguity (dot < 0.95)** | **`matrix_basis` delta for mismatched bones** |
| **Re-export differs from original** | **`decompose()` not unique across sessions** | **Three-tier hybrid sampling (Step 8b)** |
| **Body frozen in partial anim** | **Only head/hands keyed, rest at rest pose** | **Animation composition: merge Idle + target** |
| **`table.create` runtime error** | **Roblox-only, not in Rive Luau** | **Use `{}` instead** |
| **`nil` field crash in advance()** | **Field missing from constructor** | **Add field to `return function()` object** |

---

## Pre-Export Checklist

- [ ] `matrix_basis` residuals detected (Step 2)
- [ ] Model analyzed (meshes, bones, materials, parent types)
- [ ] **ALL static data in ONE call** (normalization + skeleton + vertices + animations)
- [ ] Normalization from evaluated mesh bounds
- [ ] Skeleton IBMs from `pose_bone.matrix` (POSED REST)
- [ ] Vertices from evaluated mesh (same depsgraph)
- [ ] Meshes triangulated (bmesh, non-destructive)
- [ ] Animations WITHOUT resetting `matrix_basis`
- [ ] Static channels vs rest pose
- [ ] Skin matrices = Identity verified (< 0.001)
- [ ] **Color zones detected**: multi-material (alphabetical) OR Atlas texture UV sampling (QUANT_STEP=0.005)
- [ ] Materials / texture zones -> category indices `1..N`
- [ ] **Flat arrays**: vertices stride 3, faces stride 4
- [ ] Faces Z-sorted -> fragments -> vertex optimization
- [ ] Factorized skinning (patterns + index)
- [ ] ABSOLUTE WXYZ transforms, 1-based joints
- [ ] **sharedTimes** factorized in animation files
- [ ] Anti-flickering + depthBias
- [ ] `context:markNeedsUpdate()` for rotation/animation
- [ ] **Re-export: quaternion mismatch detection** (rest local dot < 0.95)
- [ ] **Re-export: hybrid sampling** (non-keyed -> file rest, keyed -> delta or matrix_basis delta)
- [ ] **Partial animations: composition with Idle** (resample + looping)
