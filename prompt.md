# Blender to Rive 3D Animation - AI Agent Prompt

> **For Claude Code with Blender MCP**: This prompt enables AI-assisted conversion of Blender 3D models to Rive-compatible Luau code.

---

## ⚠️ STOP! Before You Start

**Read these 5 rules or face hours of debugging:**

1. **DON'T require Mesh3DUtil for static models** - Inline the math functions
2. **USE `c=index` format** - NOT RGB colors (60% file size reduction)
3. **SORT faces by avgZ** - At export time, then bubble sort at runtime
4. **STORE `context`** - Required for `markNeedsUpdate()` (auto-rotation)
5. **BLENDER Z-UP**: Yaw = XY rotation, NOT Y-axis rotation

---

## Your Task

Convert Blender 3D models into functional Rive Node Script Luau code with:
- Automatic polygon-based fragmentation (>1900 faces per file with indexed colors)
- Skeletal animation support (if Armature present)
- Material-to-color category conversion (using UV coordinates for texture atlases)
- Vertex index optimization per fragment
- Depth sorting for painter's algorithm

---

## UPDATED Limits (Landscape Export Lessons)

| Parameter | OLD Value | NEW Value | Notes |
|-----------|-----------|-----------|-------|
| Max faces/file | 600 | **1900** | Using `c=index` instead of RGB |
| Max vertices/file | 750 | **2500** | With vertex optimization per part |

**Key insight**: Using category index `c=1` instead of `color={r,g,b}` reduces file size by ~60%, allowing more faces per file.

---

## Prerequisites

### Required MCP Tools
- **Blender MCP** - For direct Blender scene access

### Reference Files
- **CLAUDE.md** - Complete Rive Luau documentation
- **Mesh3DUtil.luau** - 3D math utilities
- **SkeletalAnimUtil.luau** - Skeletal animation system
- **3DNodeScript.luau** - Example to chack of the Typical aned Expected outpout of the main file
- **blender_to_rive.py** - Standalone export script (alternative to MCP)

---

## Workflow with Blender MCP

### Step 1: Analyze Model

```
Use mcp__blender__get_scene_info to get:
- Object list (meshes, armatures)
- Polygon/vertex counts
- Material names
- Animation actions

Use mcp__blender__get_object_info for detailed mesh/armature info
Use mcp__blender__get_viewport_screenshot for visual reference
```

### Step 2: Extract Geometry via MCP

```python
# Execute via mcp__blender__execute_blender_code
import bpy
import json

mesh_obj = bpy.data.objects['MeshName']
mesh = mesh_obj.data
world_mat = mesh_obj.matrix_world

# Calculate normalization (center + scale to ~200 units)
# ... (see blender_to_rive.py for full implementation)

vertices = []
for vert in mesh.vertices:
    world_pos = normalize_mat @ world_mat @ vert.co
    vertices.append({"x": world_pos.x, "y": world_pos.y, "z": world_pos.z})

faces = []
for poly in mesh.polygons:
    verts = [v + 1 for v in poly.vertices]  # 1-based for Luau
    faces.append({"verts": verts, "c": poly.material_index + 1})

print(json.dumps({"vertices": vertices, "faces": faces}))
```

### Step 3: Extract Skeleton (If Armature Present)

⚠️ **CRITICAL: Coordinate Space Consistency**

ALL data must be in the SAME normalized space:
- Vertices, IBMs, rest pose, animations

⚠️ **CRITICAL: Scale = 1 Rule**

Always force scale to 1 on bone matrices to prevent animation amplification.

```python
# Execute via mcp__blender__execute_blender_code
import bpy
import json
from mathutils import Matrix, Vector

armature = bpy.data.objects['Armature']
bones = armature.data.bones
arm_world = armature.matrix_world

# Use the SAME normalize_mat as for vertices!
# ... (calculate from mesh bounds)

skeleton_data = {
    "jointCount": len(bones),
    "jointParents": [],
    "inverseBindMatrices": [],
    "restPose": []
}

bone_index = {bone.name: i + 1 for i, bone in enumerate(bones)}

for bone in bones:
    # Parent index
    parent_idx = bone_index.get(bone.parent.name) if bone.parent else None
    skeleton_data["jointParents"].append(parent_idx)

    # Bone world matrix in NORMALIZED space
    bone_world = arm_world @ bone.matrix_local
    bone_normalized = normalize_mat @ bone_world

    # FORCE scale to 1
    loc, rot, _ = bone_normalized.decompose()
    bone_mat_no_scale = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

    # IBM = inverse of normalized world matrix
    ibm = bone_mat_no_scale.inverted()
    skeleton_data["inverseBindMatrices"].append([ibm[r][c] for c in range(4) for r in range(4)])

    # Rest pose = local transform relative to parent
    if bone.parent:
        parent_world = arm_world @ bone.parent.matrix_local
        parent_normalized = normalize_mat @ parent_world
        parent_loc, parent_rot, _ = parent_normalized.decompose()
        parent_mat = Matrix.LocRotScale(parent_loc, parent_rot, Vector((1, 1, 1)))
        local_mat = parent_mat.inverted() @ bone_mat_no_scale
    else:
        local_mat = bone_mat_no_scale

    local_loc, local_rot, _ = local_mat.decompose()
    skeleton_data["restPose"].append({
        "translation": [local_loc.x, local_loc.y, local_loc.z],
        "rotation": [local_rot.w, local_rot.x, local_rot.y, local_rot.z],  # WXYZ
        "scale": [1.0, 1.0, 1.0]
    })

print(json.dumps(skeleton_data, indent=2))
```

### Step 4: Extract Skinning Data

```python
# Execute via mcp__blender__execute_blender_code
import bpy
import json

mesh_obj = bpy.data.objects['MeshName']
armature = bpy.data.objects['Armature']
mesh = mesh_obj.data
bones = armature.data.bones
bone_index = {bone.name: i for i, bone in enumerate(bones)}
vgroup_names = {vg.index: vg.name for vg in mesh_obj.vertex_groups}

skinning = []
for vert in mesh.vertices:
    weights = []
    for vg in vert.groups:
        vg_name = vgroup_names.get(vg.group)
        if vg_name and vg_name in bone_index:
            weights.append((bone_index[vg_name], vg.weight))

    weights.sort(key=lambda x: -x[1])
    weights = weights[:4]

    total = sum(w for _, w in weights)
    if total > 0:
        weights = [(j, w / total) for j, w in weights]

    while len(weights) < 4:
        weights.append((0, 0.0))

    skinning.append({
        "j": [w[0] for w in weights],
        "w": [w[1] for w in weights]
    })

print(json.dumps(skinning))
```

### Step 5: Extract Animations

```python
# Execute via mcp__blender__execute_blender_code
import bpy
import json
from mathutils import Matrix, Vector

armature = bpy.data.objects['Armature']
arm_world = armature.matrix_world
bones = armature.data.bones
bone_index = {bone.name: i + 1 for i, bone in enumerate(bones)}

# Use SAME normalize_mat!
# ...

animations = {}

for action in bpy.data.actions:
    if not any(fc.data_path.startswith("pose.bones") for fc in action.fcurves):
        continue

    frame_start, frame_end = action.frame_range
    fps = bpy.context.scene.render.fps

    # Temporarily assign action
    armature.animation_data.action = action

    bone_channels = {name: {"translation": [], "rotation": []} for name in bone_index.keys()}

    for frame in range(int(frame_start), int(frame_end) + 1):
        bpy.context.scene.frame_set(frame)
        time = (frame - frame_start) / fps

        for bone_name in bone_index.keys():
            pose_bone = armature.pose.bones.get(bone_name)
            if not pose_bone:
                continue

            # Get FINAL local transform in normalized space
            pose_world = arm_world @ pose_bone.matrix
            pose_normalized = normalize_mat @ pose_world
            loc, rot, _ = pose_normalized.decompose()
            pose_mat = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

            if pose_bone.parent:
                parent_world = arm_world @ pose_bone.parent.matrix
                parent_normalized = normalize_mat @ parent_world
                parent_loc, parent_rot, _ = parent_normalized.decompose()
                parent_mat = Matrix.LocRotScale(parent_loc, parent_rot, Vector((1, 1, 1)))
                local_mat = parent_mat.inverted() @ pose_mat
            else:
                local_mat = pose_mat

            local_loc, local_rot, _ = local_mat.decompose()
            bone_channels[bone_name]["translation"].append((time, [local_loc.x, local_loc.y, local_loc.z]))
            bone_channels[bone_name]["rotation"].append((time, [local_rot.w, local_rot.x, local_rot.y, local_rot.z]))

    # Convert to animation format
    duration = (frame_end - frame_start) / fps
    channels = []

    for bone_name, data in bone_channels.items():
        joint_idx = bone_index[bone_name]

        if data["translation"]:
            times = [t for t, _ in data["translation"]]
            values = [v for _, vals in data["translation"] for v in vals]
            channels.append({"jointIndex": joint_idx, "path": "translation", "times": times, "values": values})

        if data["rotation"]:
            times = [t for t, _ in data["rotation"]]
            values = [v for _, vals in data["rotation"] for v in vals]
            channels.append({"jointIndex": joint_idx, "path": "rotation", "times": times, "values": values})

    animations[action.name] = {"name": action.name, "duration": duration, "channels": channels}

print(json.dumps(animations, indent=2))
```

---

## Critical Constraints

### Polygon/Vertex Limits (UPDATED)
- **Maximum ~1900 polygons** per Luau script file (with indexed colors)
- **Maximum ~2500 vertices** per Luau script file
- Auto-fragment by mesh parts when exceeded
- **Each fragment must contain ONLY its used vertices** (remap indices)
- **Use category index `c=1` NOT RGB colors** - reduces file size significantly

### Coordinate Space Consistency
ALL data MUST be in the SAME normalized space:
- Vertices: centered, scaled to ~200 units
- IBMs: calculated in same normalized space with scale=1
- Rest pose: local transforms in same normalized space
- Animations: FINAL local transforms (not deltas!)

### Quaternion Format
- **Blender exports:** WXYZ `{w, x, y, z}`
- **SkeletalAnimUtil expects:** XYZW `{x, y, z, w}`
- Conversion handled automatically by SkeletalAnimUtil

### Animation Name Format
Blender exports as `"Armature|ActionName"`. Set `animationName` Input to match exactly.

---

## Rive Luau Restrictions

### 1. table.sort with Comparator NOT SUPPORTED
```luau
-- ❌ WRONG
table.sort(faces, function(a, b) return a.depth < b.depth end)

-- ✅ CORRECT: Manual bubble sort
local n = #faces
for i = 1, n - 1 do
  for j = 1, n - i do
    if faces[j].depth > faces[j + 1].depth then
      faces[j], faces[j + 1] = faces[j + 1], faces[j]
    end
  end
end
```

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

### 3. Nil-Safe Property Access
```luau
-- ❌ WRONG
self.skeleton = SkelAnim.buildSkeleton(data)
print(self.skeleton.jointCount)  -- Error: could be nil

-- ✅ CORRECT
local skeleton = SkelAnim.buildSkeleton(data)
self.skeleton = skeleton
print(skeleton.jointCount)  -- OK
```

### 4. Path Modification in draw() FORBIDDEN
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

### Animated Model
```luau
ModelData.vertices = { ... }
ModelData.faces = { ... }

ModelData.skeleton = {
  jointCount = N,
  jointParents = { nil, 1, 2, ... },
  inverseBindMatrices = { {16 floats}, ... },
  restPose = { { translation={...}, rotation={...}, scale={1,1,1} }, ... },
}

ModelData.skinning = {
  { j = {0,1,2,0}, w = {0.8,0.1,0.1,0} },
  ...
}

ModelData.animations = {
  ["Armature|Swim"] = {
    name = "Armature|Swim",
    duration = 4.21,
    channels = { { jointIndex=1, path="rotation", times={...}, values={...} }, ... },
  },
}

return ModelData
```

---

## Property Group Template

```luau
export type Model3D = {
    -- Rotation
    rotationSpeed: Input<number>,
    baseRotationX: Input<number>,
    baseRotationY: Input<number>,
    baseRotationZ: Input<number>,
    joystickPitch: Input<number>,
    joystickYaw: Input<number>,
    joystickRoll: Input<number>,

    -- Scale/Projection
    scale: Input<number>,           -- Default: 1
    fov: Input<number>,             -- Default: 800
    cameraDistance: Input<number>,  -- Default: 400
    usePerspective: Input<boolean>, -- Default: false

    -- Anchor
    anchorX: Input<number>,
    anchorY: Input<number>,
    anchorZ: Input<number>,

    -- Rendering
    brightness: Input<number>,      -- Default: 30
    faceExpansion: Input<number>,   -- Default: 0.005
    backfaceCulling: Input<boolean>,-- Default: true
    wireframe: Input<boolean>,      -- Default: false

    -- Animation
    animationEnabled: Input<boolean>,
    animationName: Input<string>,   -- e.g., "Armature|Swim"
    animationSpeed: Input<number>,  -- Default: 1

    -- Colors (named from Blender materials)
    primaryColor: Input<Color>,
    secondaryColor: Input<Color>,
    -- ... add per material

    -- Internal
    skeleton: SkelAnim.Skeleton?,
    currentAnimation: SkelAnim.AnimationClip?,
    animations: { [string]: SkelAnim.AnimationClip }?,
    animationTime: number,
    lastAnimationName: string,
    projectedFaces: { ProjectedFace },
}
```

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| Model twisted when animated | Coordinate space mismatch | Use SAME normalize_mat for ALL data |
| Animation explodes | Armature scale ≠ 1 | Force scale=1 on bone matrices |
| Animation doesn't play | Wrong animation name | Check console for available names |
| "Code too complex" error | Too many vertices | Fragment + remap indices |
| "Path modified between draws" | path:reset() in draw() | Build paths in advance() |
| Type mismatch | Untyped data | Cast through `:: any` |
| Jerky animation | Missing keyframes | Add more keyframes in Blender |

---

## Output Deliverables

Provide functional Luau scripts that:
- Render complete 3D model with all faces visible
- Stay within ~1900-polygon / ~2500-vertex limit per file (using indexed colors)
- Include skeleton/skinning/animation if Armature present
- Expose properties in Property Group (transforms, colors, animation)
- Use meaningful color input names from Blender materials
- Are immediately usable in Rive without modification

---

## Depth Sorting (Painter's Algorithm)

**CRITICAL**: Faces must be sorted back-to-front for correct rendering.

### What Works
```python
# At export time in Blender
def face_avg_z(face):
    return sum(vertices[vi-1]['z'] for vi in face['verts']) / len(face['verts'])
all_faces.sort(key=face_avg_z)
```

```luau
-- At runtime in Rive (bubble sort)
for i = 1, n - 1 do
  for j = 1, n - i do
    if faces[j].depth > faces[j + 1].depth then
      faces[j], faces[j + 1] = faces[j + 1], faces[j]
    end
  end
end
```

### What DOESN'T Work
- **BSP trees**: Static order breaks with rotation
- **maxZ sorting**: Terrain overlaps objects
- **Newell's algorithm**: Complex, similar results
- **Layer separation**: Doesn't handle all cases

---

## Coordinate System (Blender Z-up)

For Blender Z-up models, rotation mapping:
- `rotationY` (Yaw) → Rotate in XY plane (horizontal turntable)
- `rotationX` (Pitch) → Tilt forward/back
- `rotationZ` (Roll) → Tilt left/right

```luau
-- Transform for Z-up model
local function transformVertex(vx, vy, vz, ...)
  -- Yaw: rotate in XY plane (around Z)
  local rx = x * cosY - y * sinY
  local ry = x * sinY + y * cosY
  x, y = rx, ry
  -- Pitch: rotate in YZ plane
  local ry2 = y * cosX - z * sinX
  local rz = y * sinX + z * cosX
  y, z = ry2, rz
  -- ...
end
```

---

## Material Detection (UV-based for Texture Atlases)

When materials use texture atlases (like TEX_envProps), use UV coordinates:

```python
def get_material_category(mat_name, face, uv_layer):
    if "terrain" in mat_name.lower():
        return 1
    elif "road" in mat_name.lower():
        return 2
    elif "prop" in mat_name.lower() or "env" in mat_name.lower():
        avg_u, avg_v = get_face_uv(face, uv_layer)
        if avg_u < 0.25 and avg_v > 0.5:
            return 4  # Rocks (high in atlas)
        elif avg_u < 0.25:
            return 6  # Props
        else:
            return 5  # Cacti/trees
    return 1  # Default
```

---

## Mesh3DUtil - OPTIONAL for Static Models

**For static (non-animated) models, Mesh3DUtil is NOT required.**

Only require it if using:
- Matrix operations (mat4)
- Quaternion math
- Skeletal animation

---

## Alternative: Standalone Script

If Blender MCP is not available, use `blender_to_rive.py`:
1. Open in Blender Text Editor
2. Configure MODEL_NAME and settings
3. Run with Alt+P
4. Copy generated `.luau` files to Rive

---

## Auto-Rotation Implementation (CRITICAL)

**Problem:** `rotationSpeed` does nothing without waking the render loop.

```luau
-- ❌ WRONG: Rotation updates but screen doesn't refresh
local function advance(self: Model3D, seconds: number): boolean
  self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
  return true
end

-- ✅ CORRECT: Wake render loop for continuous animation
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
  return true
end
```

---

## Pre-Export Checklist

Before running any export:

- [ ] Analyzed model (vertex count, polygon count, materials)
- [ ] Identified coordinate system (Z-up for Blender)
- [ ] Mapped materials to category indices 1-6
- [ ] Will use `c=index` format (NOT RGB)
- [ ] Will sort faces by avgZ before fragmenting
- [ ] Will extract only used vertices per part
- [ ] Main script will store `context` for `markNeedsUpdate()`
- [ ] For Z-up: Yaw rotates in XY plane (cosY/sinY on x,y)

---

## Common Mistakes Summary

| What You Did | What Went Wrong | What To Do |
|--------------|-----------------|------------|
| Used Mesh3DUtil for static model | Unnecessary import | Inline the math functions |
| Used RGB `color={r,g,b}` | Files too large | Use `c=1` category index |
| Sorted by maxZ | Objects behind terrain | Sort by avgZ (centroid) |
| Forgot `context:markNeedsUpdate()` | rotationSpeed does nothing | Store context, call markNeedsUpdate |
| Used `table.sort` with comparator | Runtime error | Use manual bubble sort |
| Yaw rotated around Y axis | Model tilts instead of turns | For Z-up: rotate in XY plane |
| Shared all vertices across parts | "Code too complex" error | Extract only used vertices per part |
