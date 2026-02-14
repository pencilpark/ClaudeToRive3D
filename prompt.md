# Blender to Rive 3D Export — AI Agent Prompt

> **For Claude Code with Blender MCP**: Universal conversion of ANY Blender 3D model to Rive-compatible Luau code.

---

## ⚠️ STOP! Before You Start

**Read these 14 rules or face hours of debugging:**

1. **⚠️ ALWAYS use "posed rest" as reference** — NOT `bone.matrix_local` (pure REST). See rule 12.
2. **⚠️ NEVER reset `matrix_basis`** before sampling animations. It IS the model's default pose.
3. **⚠️ ALWAYS prefer Blender MCP** over standalone Python scripts — more reliable.
4. **DON'T require Mesh3DUtil for static models** — Inline the math functions
5. **USE `c=index` format** — NOT RGB colors (60% file size reduction)
6. **SORT faces by avgZ** — At export time, then table.sort at runtime
7. **STORE `context`** — Required for `markNeedsUpdate()` (auto-rotation)
8. **BLENDER Z-UP**: Yaw = XY rotation, NOT Y-axis rotation
9. **FACTORIZE SKINNING** — Use patterns table + index array (~40% smaller files)
10. **USE ANTI-FLICKERING** — table.sort + index tiebreaker + Z_EPSILON (0.001)
11. **USE `depthBias`** — 0/10/20 for object-based parts, 0 for Z-sliced parts, 99/100 for wall overlays
12. **⚠️ "POSED REST" = no action + pose_position='POSE'** — The default appearance WITH `matrix_basis`. Skeleton IBMs, vertices, AND animations must ALL use this same reference. `bone.matrix_local` for IBMs but `pose_bone.matrix` for animations causes massive offsets!
13. **Static channel optimization: compare against POSED REST** — NOT just frame-to-frame constancy. Keep constant-but-different-from-posed-rest as 2-keyframe channels.
14. **ANIMATIONS = ABSOLUTE transforms** — NOT deltas from rest pose. Export final local TRS per keyframe.
15. **⚠️ RE-EXPORT TRAP: Quaternion sign ambiguity** — `decompose()` is NOT unique (`q` ≡ `-q`). When re-exporting animations in a new session, compare rest local quaternion dot product vs file. If dot < 0.95 → use `matrix_basis` delta. Non-keyed bones → exact file rest values. See Step 8b.

---

## Your Task

Convert ANY Blender 3D model into functional Rive Node Script Luau code with:
- **Multi-mesh support**: Any number of mesh objects linked to one armature
- **Two skinning modes**: BONE-parented (rigid) AND armature-modifier (multi-bone weights)
- **Automatic triangulation**: via bmesh (non-destructive, preserves original)
- **Polygon-based fragmentation**: ~1900 faces per file with indexed colors
- **Skeletal animation**: Any number of bones, any number of animations
- **Material-to-color categories**: Multi-zone coloring (sorted alphabetically)
- **Vertex optimization**: Only used vertices per fragment
- **Factorized skinning**: Patterns table + index array
- **Anti-flickering**: table.sort + index tiebreaker + depthBias
- **Wall-mounted surfaces**: Hardcoded in Node Script + depthBias
- **Verification**: Skin matrices = Identity + skinned vertices roundtrip

---

## Universal 10-Step Export Process

### Step 1: Discover Model
```python
# Auto-detect:
# - Armature (first ARMATURE object, or by name)
# - All MESH children (exclude cameras, empties, helpers)
# - Parent type: BONE (rigid) vs ARMATURE modifier (multi-bone)
# - Materials across all meshes (sorted alphabetically → c=1..N)
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
        print(f"⚠️ {pb.name} has residual matrix_basis → MUST use posed rest")
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

### Step 4: Compute Normalization (POSED REST)
```python
# Bounding box from ALL meshes in POSED REST position
# normalize_mat = Scale(TARGET_SIZE / max_dim) @ Translate(-center)
# TARGET_SIZE = 200 (standard)
```

### Step 5: Export Skeleton (POSED REST)
```python
# Use pose_bone.matrix (NOT bone.matrix_local!)
bone_world = arm_world @ pose_bone.matrix  # Includes matrix_basis ✓
bone_norm = normalize_mat @ bone_world
loc, rot, _ = bone_norm.decompose()
bone_mat = LocRotScale(loc, rot, (1,1,1))  # Force scale=1
ibm = bone_mat.inverted()
# Rest pose local transform = parent_mat.inv @ bone_mat
```

### Step 6: Export Meshes
```python
# Per mesh object:
# 1. Triangulate via bmesh (non-destructive temp copy)
# 2. Transform vertices: normalize_mat @ obj.matrix_world @ v.co
# 3. Map faces → material category index
# 4. Skinning:
#    - BONE parent → rigid (all verts → parent bone)
#    - ARMATURE modifier → vertex groups (up to 4 bones, weights normalized)
```

### Step 7: Sort & Fragment
```python
# Sort ALL faces by avgZ (painter's algorithm)
# Split into ~1900-face parts
# Each part: only used vertices (remapped 1-based), own skinning data
```

### Step 8: Export Animations
```python
# DO NOT reset matrix_basis!
# Sample ABSOLUTE local transforms per frame per bone
# Store: translation {x,y,z}, rotation {w,x,y,z} (WXYZ)
```

### Step 8b: Re-Export Safe Sampling (when Part files already exist)
```python
# ⚠️ ONLY when re-exporting animations for an existing model
# 1. Parse rest pose from existing Part file
# 2. Detect mismatched bones: dot(blender_rest_local.rot, file_rest_local.rot) < 0.95
# 3. Get keyframed bone names from action FCurves
# 4. Three-tier hybrid:
#    - NOT keyed → exact file rest values (translation + rotation)
#    - Keyed + match (dot ≥ 0.95) → file_rest_local × (blender_rest_local⁻¹ × anim_local)
#    - Keyed + mismatch (dot < 0.95) → file_rest_local × (rest_basis⁻¹ × frame_basis)
# 5. Animation composition: merge Idle channels with partial animations
#    (e.g., Yes = Idle body breathing + Head nod from Yes action)
```

### Step 9: Optimize Channels
```python
# Per bone per path:
# - Constant AND matches posed-rest → REMOVE
# - Constant but DIFFERS from posed-rest → 2-keyframe
# - Varies → full channel
```

### Step 10: Verify & Write
```python
# MANDATORY: skin matrices = Identity at posed rest (< 0.001)
# Write: Part files (skeleton in first) + Animation files (separate)
```

---

## Animation System

### Data Format
**All data in SAME normalized coordinate space (~200 units max):**
- **Quaternions:** WXYZ in files (Blender native). `SkeletalAnimUtil` converts to XYZW internally.
- **Joint indices:** 1-based in files (Luau arrays).
- **Skinning patterns:** 0-based bone indices. Runtime adds `+1`.
- **Transforms:** ABSOLUTE (not deltas).

### Runtime Pipeline
```
sampleAnimation()  →  writes absolute local transforms
updateSkeleton()   →  computes worldMatrices + skinMatrices
skinVerticesFact() →  transforms vertices by bone skinMatrix
```

### Static Channel Optimization (CRITICAL)
```python
EPSILON = 0.0001
if is_constant_across_frames:
    if matches_posed_rest(epsilon=EPSILON):
        pass  # REMOVE — sampleAnimation resets to rest = posed-rest
    else:
        keep_as_2_keyframe(times=[0, duration])  # KEEP — differs from default
else:
    keep_full_channel()  # KEEP — values vary
```

---

## File Size Limits

| Parameter | Value | Notes |
|-----------|-------|-------|
| Max faces/file | **~1900** | Using `c=index` |
| Max vertices/file | **~2500** | With vertex optimization |

**Category index** (`c=1`) instead of RGB → ~60% smaller.
**Factorized skinning** (patterns + index) → ~40% smaller.
**Animations** in separate files from Part data.

---

## Multi-Mesh Support

| Mesh Parent Type | Skinning | Example |
|-----------------|----------|---------|
| **BONE parent** (rigid) | All verts → parent bone | Torso, head, limbs |
| **ARMATURE modifier** | Vertex groups → up to 4 bones | Hands, flexible parts |
| **No parent** | Excluded from export | Helpers, lights |

All meshes share ONE skeleton, ONE normalization. Vertices merged, faces Z-sorted across all meshes before fragmenting.

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
-- Z-sliced parts → depthBias = 0 for all
-- Separate objects → depthBias = 0, 10, 20
-- Wall overlay → depthBias = 99, 100
```

### 3. Stable Sort
```luau
local Z_EPSILON = 0.001
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    local d = a.depth - b.depth
    if math.abs(d) < Z_EPSILON then return a.index < b.index end
    return a.depth < b.depth
end)
```

---

## Multi-Zone Coloring

1. Blender: one material per zone
2. Export: each material → `c=1..N` (sorted alphabetically)
3. Node Script: `Input<Color>` per zone + `colorMap` lookup

```luau
local colorMap: { [number]: Color } = {
    [1] = self.bodyColor,
    [2] = self.headColor,
    [3] = self.armsColor,
}
local faceColor = colorMap[face.c] or self.bodyColor
```

---

## Wall-Mounted Surfaces

1. Remove surface from Blender mesh
2. Hardcode vertices/faces in Node Script (`advance()`)
3. Position 1-2 units from wall + `depthBias=99/100`

```luau
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

### Runtime Usage
```luau
local function skinVerticesFact(skeleton, vertices, skinningPatterns, skinningIndex)
    for i, v in ipairs(vertices) do
        local skin = skinningPatterns[skinningIndex[i]]
        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- 0-based → 1-based
            local weight = skin.w[k]
            if weight > 0 then
                -- Transform vertex by skinMatrix[jointIdx]
            end
        end
    end
end
```

---

## Coordinate System (Blender Z-up)

- `rotationY` (Yaw) → Rotate in XY plane (turntable)
- `rotationX` (Pitch) → Tilt forward/back
- `rotationZ` (Roll) → Tilt left/right

```luau
-- Yaw: x,y rotation (cosY/sinY)
-- Pitch: y,z rotation (cosX/sinX)
-- Roll: x,y rotation (cosZ/sinZ)
```

---

## Rive Luau Restrictions

### table.sort MUST Have Type Annotations
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
ModelData.vertices = { {x=0, y=0, z=0}, ... }
ModelData.faces = { {verts={1,2,3}, c=1}, ... }
ModelData.skinningPatterns = S
ModelData.skinningIndex = {1, 1, 1, 6, 6, ...}
```

### Animation Data File
```luau
ModelData.animations = {
  ["walk"] = {
    name = "walk", duration = 1.5,
    channels = {
      { jointIndex = 1, path = "rotation", times = {...}, values = {w,x,y,z,...} },
      { jointIndex = 1, path = "translation", times = {...}, values = {x,y,z,...} },
    },
  },
}
```

**Key:** jointIndex = 1-based, rotation = WXYZ, transforms = ABSOLUTE.

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| **Body parts scattered/dislocated** | **Different reference poses** | **Posed rest for ALL exports** |
| **Head/shoulders offset** | **Pure REST for IBMs, posed for anims** | **Use `pose_bone.matrix` everywhere** |
| **Arms in T-pose / horizontal** | **`matrix_basis` reset or channels removed** | **Never reset; keep constant-but-different** |
| **Huge offset on root** | **matrix_basis amplified by scale** | **Detect residuals first (Step 2)** |
| **Bones snap to wrong pose** | **No keyframes + reset matrix_basis** | **Keep matrix_basis; use posed-rest** |
| Faces flickering | Z-fighting | 3-technique anti-flickering |
| Animation wrong | Deltas not absolute | ABSOLUTE local transforms |
| Quaternion issues | WXYZ/XYZW mismatch | Data=WXYZ, runtime converts |
| File too large | Repeated skinning | Factorized skinning |
| Non-triangular faces | Quads/ngons | Triangulate via bmesh |
| `StructRNA removed` | Freed evaluated mesh | Use temp mesh copy |
| `rotationSpeed` broken | No markNeedsUpdate | Store context |
| **Fingers stretched on re-export** | **Quaternion sign ambiguity (dot < 0.95)** | **`matrix_basis` delta for mismatched bones** |
| **Re-export differs from original** | **`decompose()` not unique across sessions** | **Three-tier hybrid sampling (Step 8b)** |
| **Body frozen in partial anim** | **Only head/hands keyed, rest at rest pose** | **Animation composition: merge Idle + target** |

---

## Pre-Export Checklist

- [ ] `matrix_basis` residuals detected (Step 2)
- [ ] Model analyzed (meshes, bones, materials, parent types)
- [ ] Normalization in POSED REST (all meshes)
- [ ] Skeleton IBMs from posed rest (`pose_bone.matrix`)
- [ ] Vertices in posed rest
- [ ] Meshes triangulated (bmesh)
- [ ] Animations WITHOUT resetting `matrix_basis`
- [ ] Static channels vs POSED REST
- [ ] Skin matrices = Identity verified (< 0.001)
- [ ] Materials → category indices (alphabetical)
- [ ] Faces Z-sorted → fragments → vertex optimization
- [ ] Factorized skinning (patterns + index)
- [ ] ABSOLUTE WXYZ transforms, 1-based joints
- [ ] Anti-flickering + depthBias
- [ ] `context:markNeedsUpdate()` for rotation/animation
- [ ] **Re-export: quaternion mismatch detection** (rest local dot < 0.95)
- [ ] **Re-export: hybrid sampling** (non-keyed → file rest, keyed → delta or matrix_basis delta)
- [ ] **Partial animations: composition with Idle** (resample + looping)
