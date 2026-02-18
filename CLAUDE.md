# Blender to Rive 3D Export — Universal Guide


## Workflow Orchestration

### 1. Plan Mode Default

Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
If something goes sideways, STOP and re-plan immediately - don't keep pushing
Use plan mode for verification steps, not just building
Write detailed specs upfront to reduce ambiguity


### 2. Subagent Strategy to keep main context window clean

Offload research, exploration, and parallel analysis to subagents
For complex problems, throw more compute at it via subagents
One task per subagent for focused execution


### 3. MANDATORY: Self-Improvement Loop MANDATORY

After ANY correction from the user: update 'tasks/lessons.md' with the pattern
Write rules for yourself that prevent the same mistake
Ruthlessly iterate on these lessons until mistake rate drops
Review lessons at session start for relevant project


### 4. Verification Before Done

Never mark a task complete without proving it works
Diff behavior between main and your changes when relevant
Ask yourself: "Would a staff engineer approve this?"
Run tests, check logs, demonstrate correctness


### 5. Demand Elegance (Balanced)

For non-trivial changes: pause and ask "is there a more elegant way?"
If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
Skip this for simple, obvious fixes - don't over-engineer
Challenge your own work before presenting it


### 6. Autonomous Bug Fixing

When given a bug report: just fix it. Don't ask for hand-holding
Point at logs, errors, failing tests -> then resolve them
Zero context switching required from the user
Go fix failing CI tests without being told how

## Task Management

**Plan First**: Write plan to 'tasks/todo.md' with checkable items
**Verify Plan**: Check in before starting implementation
**Track Progress**: Mark items complete as you go
**Explain Changes**: High-level summary at each step
**Document Results**: Add review to 'tasks/todo.md'
**Capture Lessons**: Update 'tasks/lessons.md' after corrections


## Core Principles

**Simplicity First**: Make every change as simple as possible. Impact minimal code.
**No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
**Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Identity
AI assistant for Rive scripting in **pure Luau** (no Roblox libraries).
Prioritize working patterns over theoretical completeness.
Always use `--!strict` mode.

> **Quick Start:** USE FIRST Claude Code + Blender MCP → Copy generated `.luau` files to Rive OR Run `blender_to_rive.py` in Blender if needed

## CRITICAL RULES (Read Before Exporting)

1. **ALWAYS use "posed rest" as reference** — NOT `bone.matrix_local` (pure REST). See "Posed Rest" section.
2. **NEVER reset `matrix_basis`** before sampling animations — it IS the model's default pose.
3. **ALWAYS prefer Blender MCP** over standalone Python scripts — more reliable.
4. **Static models DON'T need Mesh3DUtil** — All math can be inline
5. **Use flat arrays** for vertices (stride 3) and faces (stride 4) — ~33% smaller files
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

## Primary Reference (LERP)

**FETCH before starting any Rive scripting session:**
```
https://forge.mograph.life/apps/lerp/quick-reference
https://forge.mograph.life/apps/lerp/api/core-types
https://forge.mograph.life/apps/lerp/api/drawing
```

**FETCH when needed:**
- Complex interactions: `https://forge.mograph.life/apps/lerp/rive/environment`
- Lifecycle issues: `https://forge.mograph.life/apps/lerp/getting-started/how-rive-scripts-work`
- ViewModels: `https://forge.mograph.life/apps/lerp/advanced/viewmodels`
- Procedural graphics: `https://forge.mograph.life/apps/lerp/advanced/procedural`


## Project Structure (Generic Template)

```
YOUR_MODEL/
├── Model.luau               # Main Node Script (rendering + Property Group)
├── ModelPartAData.luau      # Part A: ~1900 faces max + skeleton data
├── ModelPartBData.luau      # Part B: ~1900 faces max
├── ModelPartCData.luau      # Part C: remaining faces (optional)
├── ModelAnim1Data.luau      # Animation data file 1 (split by size)
├── ModelAnim2Data.luau      # Animation data file 2 (optional)
├── Mesh3DUtil.luau          # 3D math utilities (for animated models)
├── SkeletalAnimUtil.luau    # Skeletal animation system
├── blender_to_rive.py       # Universal export script
├── convert_flat.py          # Convert data files to flat arrays (post-export optimization)
├── prompt.md                # AI agent prompt for Claude Code
└── CLAUDE.md                # This documentation
```

**File naming convention:** `{MODEL_NAME}Part{A,B,C,...}Data.luau` and `{MODEL_NAME}Anim{1,2,3,...}Data.luau`. Configure `MODEL_NAME` in `blender_to_rive.py` settings.

**Animations** are stored in separate files from Part data. Each animation file can contain multiple clips. Split across files if total size exceeds Rive limits.

---

## Flat Array Data Format (Optimized)

### Why Flat Arrays
Table-of-tables format (`{x=N, y=N, z=N}`) adds ~33% overhead from repeated key names and braces. Flat arrays store raw numbers with implicit structure defined by stride.

### Vertex Format (stride = 3)
```luau
-- OLD (verbose): ~33% larger
ModelData.vertices = {
  {x = 10.825, y = -18.875, z = -1.141},
  {x = 11.296, y = -19.324, z = 1.685},
}

-- NEW (flat): stride 3 → x, y, z, x, y, z, ...
ModelData.vertices = {
  10.825, -18.875, -1.141,
  11.296, -19.324, 1.685,
}
```

**Access pattern:**
```luau
-- Vertex i (1-based): base = (i - 1) * 3
local vx, vy, vz = vertices[base + 1], vertices[base + 2], vertices[base + 3]

-- Vertex count = #vertices / 3
local vertCount = #vertices / 3
```

### Face Format (stride = 4)
```luau
-- OLD (verbose):
ModelData.faces = {
  {verts = {4150, 4151, 4152}, c = 1},
  {verts = {4151, 4150, 4153}, c = 1},
}

-- NEW (flat): stride 4 → v1, v2, v3, category, v1, v2, v3, category, ...
ModelData.faces = {
  4150, 4151, 4152, 1,
  4151, 4150, 4153, 1,
}
```

**Access pattern:**
```luau
-- Face fi (0-based): fBase = fi * 4
local vi1, vi2, vi3, cat = faces[fBase + 1], faces[fBase + 2], faces[fBase + 3], faces[fBase + 4]

-- Face count = #faces / 4
local faceCount = #faces / 4
```

### Performance Benefits
- `table.create(vertCount * 3, 0)` pre-allocates flat result array — avoids GC pressure
- Direct index assignment `result[base + 1] = sx` instead of `table.insert(result, {x=sx, ...})`
- Triangles are always 3 vertices — unroll the face loop instead of ipairs
- ~33% file size reduction across all Part data files

### Converting Existing Files
Use `convert_flat.py` to convert table-of-tables format to flat arrays:
```bash
python3 convert_flat.py
```
The script auto-detects and converts `.vertices` and `.faces` blocks while preserving skeleton, skinning, and animation data unchanged.

---

## Universal Export Process (10 Steps)

**Proven on:** 15+ meshes, 43+ bones, 14+ animations, 5664+ faces, 9300+ vertices — any model follows the same steps.

### Step 1: Discover Model
```python
# Automatically find:
# - The armature (first object of type 'ARMATURE')
# - All mesh children (exclude non-mesh, cameras, empties, etc.)
# - Parent type per mesh: BONE (rigid) vs ARMATURE modifier (multi-bone skinning)
# - Materials across all meshes (sorted alphabetically -> category indices 1..N)
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

# If ANY bone has residual matrix_basis -> MUST use "posed rest" for ALL exports
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
# CRITICAL: Bounding box from ALL meshes in POSED REST position
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
# Use pose_bone.matrix (includes matrix_basis), NOT bone.matrix_local
arm_world = armature.matrix_world

for bone_name in bone_order:
    pose_bone = armature.pose.bones[bone_name]
    bone_world = arm_world @ pose_bone.matrix    # <- NOT bone.matrix_local!
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
# 2. Triangulate via bmesh (non-destructive - only temporary mesh)
# 3. Transform vertices: normalize_mat @ obj.matrix_world @ v.co
# 4. Store as flat array: x, y, z, x, y, z, ...
# 5. Map faces to flat array: v1, v2, v3, category, v1, v2, v3, category, ...
# 6. Determine skinning:
#    - BONE parent -> all verts assigned to parent bone (rigid)
#    - ARMATURE modifier -> read vertex groups (multi-bone weights, up to 4 per vert)

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
# 1. Sort ALL faces (from all meshes combined) by avgZ - painter's algorithm
# 2. Split into parts of ~MAX_FACES_PER_PART faces each
# 3. Each part gets ONLY its used vertices (remapped indices starting at 1)
# 4. Each part gets its own factorized skinning data
# 5. Output vertices and faces as flat arrays

all_faces.sort(key=lambda f: average_z_of_face(f))
parts = [all_faces[i:i+MAX_FACES] for i in range(0, len(all_faces), MAX_FACES)]
```

### Step 8: Export Animations (ABSOLUTE local transforms)
```python
# DO NOT reset matrix_basis before sampling!
# Animations are ABSOLUTE (not deltas from rest pose)

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
#   1. Constant AND matches posed-rest -> REMOVE (safe)
#   2. Constant but DIFFERS from posed-rest -> KEEP as 2-keyframe
#   3. Varies across frames -> KEEP full channel
EPSILON = 0.0001
```

### Step 10: Verify & Write Files
```python
# MANDATORY verification before writing:

# 1. Skin matrices = Identity at posed rest (max deviation < 0.001)
for i in range(joint_count):
    skin = world_mats[i] @ ibms[i]
    deviation = max(abs(skin[r][c] - identity[r][c]) for r, c in itertools.product(range(4), range(4)))
    assert deviation < 0.001

# 2. Write Part files (skeleton in first part only)
#    - Vertices as flat arrays (stride 3)
#    - Faces as flat arrays (stride 4)
# 3. Write Animation files (split by ANIM_FILE_SPLIT or auto-split)
```

---

## CRITICAL: "Posed Rest" vs "Pure Rest" (THE #1 EXPORT TRAP)

### Problem
Many Blender models have a `matrix_basis` residual on pose bones — a "default pose" (arms down, fingers closed, legs bent) that is NOT the rest pose. This residual persists even with NO action assigned.

### Why It Matters
If you use `bone.matrix_local` (pure REST) for the skeleton but `pose_bone.matrix` (which includes `matrix_basis`) for animations, you get a **coordinate space mismatch**. A tiny difference in Blender gets amplified by `armature.matrix_world` (often scale=100) x `normalize_mat` (scale ~30-50) = **massive offset** in normalized space.

### The Rule
**Skeleton, vertices, and animations must ALL use the SAME reference pose = "posed rest".**

**"Posed Rest"** = armature with NO action assigned, `pose_position='POSE'`, `matrix_basis` applied naturally. This IS the model's actual default appearance.

```python
# CORRECT: Use "posed rest" for EVERYTHING
armature.animation_data.action = None
armature.data.pose_position = 'POSE'       # matrix_basis applies
bpy.context.view_layer.update()

bone_world = arm_world @ pose_bone.matrix  # Includes matrix_basis
vertex_world = obj.matrix_world @ v.co     # obj.matrix_world follows posed bones

# WRONG: Using pure REST for skeleton
armature.data.pose_position = 'REST'       # Uses bone.matrix_local
# -> IBMs won't match pose_bone.matrix during animation -> huge offset
```

### Verification
At posed rest (no action), `skinMatrix = worldMatrix x IBM` must equal **Identity** for all bones. Max acceptable deviation: 0.001. If deviation > 1.0, there is a coordinate space mismatch.

### Why NEVER Reset `matrix_basis`
`matrix_basis` IS the model's default pose — NOT an animation artifact. If you reset it before sampling, bones without keyframes in the current action snap to pure REST instead of their intended default position (arms horizontal, fingers open, etc.).

### Why Static Channel Optimization Must Compare Against Posed Rest
When removing constant animation channels:
- Remove if constant AND matches **posed rest** (epsilon 0.0001) — bone stays at default
- Keep as 2-keyframe if constant but **differs from posed rest** — bone needs this value
- NEVER remove just because constant between frames — may be constant at a non-default value!

---

## Quaternion Sign Ambiguity & Re-Export (THE #2 EXPORT TRAP)

### Problem
`Matrix.decompose()` returns a quaternion, but **`q` and `-q` represent the same 3D rotation**. Blender may choose a different sign/decomposition path between sessions. When `matrix_basis` is restored in a new Blender session, `pose_bone.matrix.decompose()` can yield quaternions that differ from the original export — not just by sign, but by fundamentally different decomposition paths.

### Why It Matters
In a skeleton chain, the local quaternion of a parent bone defines the coordinate space for all its children. A different decomposition at the parent **cascades through the entire chain**, causing child bones (especially fingers) to stretch, twist, or fly off. This cannot be fixed by simply negating the quaternion.

### When This Happens
- **Re-exporting animations** in a new Blender session after the original Part files were already written
- **Adding new animations** to an existing model
- **Any scenario** where `matrix_basis` was saved/restored across sessions

### Detection: Rest Local Dot Product
Compare Blender's current rest local quaternion vs the file's rest local quaternion for each bone:

```python
# Parse rest pose from existing Part file
file_rest_locals = parse_from_file(part_file)  # {joint_idx: {translation, rotation}}

# Compute Blender's current rest locals
armature.animation_data.action = None
armature.data.pose_position = 'POSE'
bpy.context.view_layer.update()

mismatched_bones = set()
for idx, name in enumerate(bone_order):
    file_rot = Quaternion(file_rest_locals[idx+1]['rotation'])  # WXYZ
    blender_rot = compute_current_rest_local(name).rotation
    dot = abs(file_rot.dot(blender_rot))
    if dot < 0.95:
        mismatched_bones.add(idx + 1)
        print(f"J{idx+1}({name}): dot={dot:.3f} -> MISMATCHED")
```

### Resolution: Three-Tier Hybrid Sampling

When re-exporting animations (Part files already exist), use this strategy:

```python
for each bone in each animation frame:
    if bone NOT keyframed in this action:
        # Tier 1: Exact file rest values (no sampling)
        use file_rest_locals[joint_idx]  # translation + rotation

    elif bone IS keyframed AND NOT mismatched (dot >= 0.95):
        # Tier 2: World-space delta (classic approach)
        delta = blender_rest_local.inverted() @ blender_anim_local
        corrected = file_rest_local @ delta

    elif bone IS keyframed AND mismatched (dot < 0.95):
        # Tier 3: matrix_basis delta (bypasses decomposition issues)
        rest_basis = pose_bone.matrix_basis at rest (no action)
        frame_basis = pose_bone.matrix_basis at animation frame
        delta_basis = rest_basis.inverted() @ frame_basis
        corrected = file_rest_local_matrix @ delta_basis
```

### Why `matrix_basis` Delta Works
`matrix_basis` is the bone-local transform that Blender applies on top of the rest pose. It captures the animation change **independently of how the world-space matrix gets decomposed**. The delta `rest_basis_inv x frame_basis` represents the pure local animation change, which can be safely composed with the file's rest local transform.

### Keyframed Bone Detection
Only bones **directly keyframed** in an action should be sampled. Use FCurve analysis:

```python
def get_animated_bones(action):
    """Return set of bone names with actual keyframes in this action."""
    animated = set()
    for fc in action.fcurves:
        if fc.data_path.startswith("pose.bones["):
            bone_name = fc.data_path.split('"')[1]
            animated.add(bone_name)
    return animated
```

Non-keyframed bones receive **exact file rest values** — never sampled, never delta'd.

---

## Animation Composition (Merging Idle + Targeted Animations)

### Use Case
Some animations only affect a subset of bones (e.g., "Yes" = head nod, "No" = head shake) but the rest of the body should keep its Idle breathing motion, not freeze.

### Pattern
Merge Idle animation channels with the targeted animation's specific channels:

```python
# 1. Parse Idle animation from existing Anim file
idle_channels = parse_idle_from_file()  # All channels from Idle clip

# 2. Get the targeted animation's specific channels (e.g., Head rotation for Yes)
target_channels = sample_target_animation()  # Only the keyed bones

# 3. Merge: for each Idle channel
for idle_ch in idle_channels:
    if target_animation_overrides_this_bone_and_path(idle_ch):
        # Use target animation's channel (e.g., Head rotation from Yes)
        merged_channels.append(target_channel)
    else:
        # Resample Idle at target animation's frame times
        resampled = resample_idle_channel(idle_ch, target_times, target_duration)
        merged_channels.append(resampled)
```

### Resampling with Linear Interpolation + Looping
When the target animation has different duration/timing than Idle:

```python
def resample_channel(source_times, source_values, target_times, stride):
    """Resample source channel at target frame times with looping."""
    source_duration = source_times[-1]
    result = []
    for t in target_times:
        # Loop within source duration
        t_loop = t % source_duration if source_duration > 0 else 0
        # Find bracketing keyframes and lerp
        value = interpolate_at_time(source_times, source_values, t_loop, stride)
        result.extend(value)
    return result
```

### When to Use Animation Composition
- **Head gestures** (Yes, No, Look) -> Head channels from gesture + Idle body
- **Facial expressions** -> Face bone channels + Idle body
- **Hand gestures** -> Hand channels from gesture + Idle body
- **Any partial-body animation** where freezing the rest of the body looks unnatural

---

## Animation System Format

### Data Format
**All data is in the SAME normalized coordinate space:**
- **Vertices:** Flat array (stride 3), centered, scaled to ~200 units max, in posed rest position
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
sampleAnimation()  ->  writes absolute local transforms to skeleton.localTransforms
updateSkeleton()   ->  computes worldMatrices (parent chain) and skinMatrices (world x IBM)
skinVerticesFact() ->  transforms each vertex by its bone's skinMatrix (flat array in/out)
```

---

## Multi-Mesh Export (Universal)

### Supported Mesh Types
The export handles ANY combination of:

| Mesh Parent Type | Skinning | Example |
|-----------------|----------|---------|
| **BONE parent** (rigid) | All vertices -> parent bone | Torso, head, limbs |
| **ARMATURE modifier** (multi-bone) | Vertex groups -> up to 4 bones/weights | Hands, clothing, flexible parts |
| **No parent** (excluded) | Not exported | Helper objects, lights |

### How Multi-Mesh Works
1. **All meshes share ONE skeleton** (from the armature)
2. **All meshes share ONE normalization** (bounding box across all meshes)
3. **Vertices from all meshes are merged** into one global flat vertex array
4. **Faces are Z-sorted across all meshes** before fragmenting into parts
5. **Each part gets only its used vertices** (remapped indices, flat array)
6. **Skinning is per-vertex**, regardless of which mesh the vertex came from

### Triangulation
All meshes are triangulated at export via `bmesh.ops.triangulate()`. This is **non-destructive** — the original Blender mesh is preserved; only a temporary copy is triangulated for export.

---

## File Size & Optimization

### Limits
| Parameter | Value | Notes |
|-----------|-------|-------|
| Max faces/file | **~1900** | With flat face format (stride 4) |
| Max vertices/file | **~2500** | With vertex optimization per part |

### Flat Array Format (Primary Optimization)
```luau
-- OLD: Verbose table-of-tables (~33% larger)
ModelData.vertices = { {x=10, y=20, z=30}, ... }
ModelData.faces = { {verts={1,2,3}, c=1}, ... }

-- NEW: Flat arrays (optimized)
ModelData.vertices = { 10, 20, 30, ... }       -- stride 3: x, y, z
ModelData.faces = { 1, 2, 3, 1, ... }          -- stride 4: v1, v2, v3, category
```

### Factorized Skinning Format
```luau
-- WRONG: Repeated full entries (huge files, typecheck errors)
ModelData.skinning = {
  {j = {1, 0, 0, 0}, w = {1.0, 0.0, 0.0, 0.0}},  -- Repeated 100s of times!
}

-- CORRECT: Patterns table + index array (~40% smaller)
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
local function processFaces(self, vertices: {number}, faces: {number}, ..., depthBias: number?)
    local bias = depthBias or 0
    local faceCount = #faces / 4
    for fi = 0, faceCount - 1 do
        -- ... transform vertices, compute avgZ ...
        local avgZ = (tz1 + tz2 + tz3) / 3 + bias
        table.insert(self.projectedFaces, {
            path = facePath, depth = avgZ, color = litColor,
            index = #self.projectedFaces + 1,
        })
    end
end
```

**depthBias depends on how parts are split:**
```luau
-- Z-sorted slices (faces sorted by avgZ before splitting) -> no bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 0)

-- Separate objects (body/head) -> large bias
processFaces(self, vertsA, facesA, ..., 0)
processFaces(self, vertsB, facesB, ..., 10)
processFaces(self, vertsC, facesC, ..., 20)

-- Wall-mounted overlay -> force to front
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
3. **Export** — each material becomes category `1..N` (sorted alphabetically)
4. **In Node Script:** Expose `Input<Color>` per zone, build colorMap

```luau
local colorMap: { [number]: Color } = {
    [1] = self.bodyColor,
    [2] = self.headColor,
    [3] = self.armsColor,
}

-- In processFaces, read category from flat face array:
local category = faces[fBase + 4]
local faceColor = colorMap[category] or self.bodyColor
```

---

## Wall-Mounted Surfaces (Screens, Panels)

**Problem:** Flat surfaces on walls Z-fight at rotation angles.

**Solution:** Decouple visual position from sort order:
1. Remove the surface from Blender
2. Re-export Part files
3. Hardcode vertices/faces in Node Script (`advance()`) as flat arrays
4. Position close to wall (1-2 normalized units)
5. Use `depthBias=99/100` to force draw order

```luau
-- Flat vertex array: x, y, z per vertex
local screenVerts = { -51, 48.66, -8.82, -51, 40.00, -8.82, -30, 48.66, -8.82, -30, 40.00, -8.82 }
-- Flat face array: v1, v2, v3, category per face
local screenFaces = { 1, 2, 3, 12, 1, 3, 4, 12 }
processFaces(self, screenVerts, screenFaces, ..., 100)
```

---

## Coordinate System (Blender Z-up to Rive)

**Blender uses Z-up, Rive screen is X-right, Y-down, Z-into-screen.**

Rotation mapping:
- `rotationY` (yaw) -> Rotate in XY plane (horizontal turntable)
- `rotationX` (pitch) -> Tilt forward/backward
- `rotationZ` (roll) -> Tilt left/right

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

-- Flat vertex array (stride 3: x, y, z per vertex)
ModelData.vertices = {
  10.825, -18.875, -1.141,
  11.296, -19.324, 1.685,
  -- ...
}

-- Flat face array (stride 4: v1, v2, v3, category per face)
ModelData.faces = {
  4150, 4151, 4152, 1,
  4151, 4150, 4153, 1,
  -- ...
}

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
- Vertices are **flat arrays** (stride 3)
- Faces are **flat arrays** (stride 4)

---

## Rive Luau Specifics

### table.sort Requires Type Annotations
```luau
table.sort(faces, function(a: ProjectedFace, b: ProjectedFace): boolean
    return a.depth < b.depth
end)
```

### Type Casting for Untyped Data (Flat Arrays)
```luau
local vertices = (PartAData :: any).vertices :: { number }
local faces = (PartAData :: any).faces :: { number }
local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
```

### Path Modification in draw() FORBIDDEN
```luau
-- Build paths in advance(), only draw in draw()
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

## Skinning in Node Script (Factorized, Flat Arrays)

```luau
type SkinEntry = { j: { number }, w: { number } }

local function skinVerticesFact(
    skeleton: SkelAnim.Skeleton,
    vertices: { number },
    skinningPatterns: { [number]: SkinEntry },
    skinningIndex: { number }
): { number }
    local vertCount = #skinningIndex
    local result: { number } = table.create(vertCount * 3, 0)
    for i = 1, vertCount do
        local base = (i - 1) * 3
        local vx, vy, vz = vertices[base + 1], vertices[base + 2], vertices[base + 3]
        local skinIdx = skinningIndex[i]
        local skin = skinningPatterns[skinIdx]
        local sx, sy, sz = 0.0, 0.0, 0.0
        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- 0-based -> 1-based
            local weight = skin.w[k]
            if weight > 0 and jointIdx >= 1 and jointIdx <= skeleton.jointCount then
                local skinMat = skeleton.skinMatrices[jointIdx]
                if skinMat then
                    local tx, ty, tz = M.mat4TransformPoint(skinMat, vx, vy, vz)
                    sx = sx + tx * weight
                    sy = sy + ty * weight
                    sz = sz + tz * weight
                end
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

## processFaces (Flat Array Version)

```luau
local function processFaces(
    self: Model3D,
    vertices: { number },     -- Flat: x,y,z,x,y,z,...
    faces: { number },        -- Flat: v1,v2,v3,cat,v1,v2,v3,cat,...
    ax: number, ay: number, az: number,
    cosX: number, sinX: number,
    cosY: number, sinY: number,
    cosZ: number, sinZ: number,
    scaleFactor: number,
    fov: number, cameraDistance: number, usePerspective: boolean,
    brightness: number, faceExpansion: number, backfaceCulling: boolean,
    depthBias: number?
)
    local bias = depthBias or 0
    local faceCount = #faces / 4

    for fi = 0, faceCount - 1 do
        local fBase = fi * 4
        local vi1 = faces[fBase + 1]
        local vi2 = faces[fBase + 2]
        local vi3 = faces[fBase + 3]
        local category = faces[fBase + 4]

        -- Read vertices from flat array
        local b1 = (vi1 - 1) * 3
        local b2 = (vi2 - 1) * 3
        local b3 = (vi3 - 1) * 3

        local tx1, ty1, tz1 = transformVertex(
            vertices[b1 + 1] * scaleFactor, vertices[b1 + 2] * scaleFactor, vertices[b1 + 3] * scaleFactor,
            ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ
        )
        local tx2, ty2, tz2 = transformVertex(
            vertices[b2 + 1] * scaleFactor, vertices[b2 + 2] * scaleFactor, vertices[b2 + 3] * scaleFactor,
            ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ
        )
        local tx3, ty3, tz3 = transformVertex(
            vertices[b3 + 1] * scaleFactor, vertices[b3 + 2] * scaleFactor, vertices[b3 + 3] * scaleFactor,
            ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ
        )

        local avgZ = (tz1 + tz2 + tz3) / 3 + bias

        -- ... normal calculation, backface culling, lighting, projection, path building ...
        -- Use category to look up color: colorMap[category]
    end
end
```

---

## Bounding Box from Flat Vertices

```luau
-- In init(), compute bounding box from flat vertex arrays
local allVerts = {
    (PartAData :: any).vertices :: { number },
    (PartBData :: any).vertices :: { number },
    (PartCData :: any).vertices :: { number },
}
local minX, minY, minZ = math.huge, math.huge, math.huge
local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
for _, verts in ipairs(allVerts) do
    for i = 1, #verts, 3 do
        local vx, vy, vz = verts[i], verts[i + 1], verts[i + 2]
        minX = math.min(minX, vx)
        minY = math.min(minY, vy)
        minZ = math.min(minZ, vz)
        maxX = math.max(maxX, vx)
        maxY = math.max(maxY, vy)
        maxZ = math.max(maxZ, vz)
    end
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
4. Run `convert_flat.py` to optimize vertex/face data to flat arrays
5. Copy generated `.luau` files to Rive project

### Option B: Claude Code + Blender MCP (Preferred)
1. Connect Blender MCP
2. Claude analyzes the model (meshes, bones, materials, vertex count)
3. Claude runs the 10-step export logic via Python in Blender
4. Claude generates the `.luau` files directly (with flat arrays)
5. Claude verifies the output (skin matrices, vertex roundtrip)

Both produce the same output format.

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| **Body parts dislocated/scattered** | **Different reference poses for skeleton vs vertices vs animations** | **Use "posed rest" for ALL exports** |
| **Head/shoulders offset** | **Skeleton uses pure REST, animations use posed REST** | **Use `pose_bone.matrix`, not `bone.matrix_local`** |
| **Arms horizontal / T-pose in Idle** | **`matrix_basis` reset or static channels removed** | **NEVER reset matrix_basis; keep constant-but-different channels** |
| **Huge offset on root bone** | **`matrix_basis` x armature_scale x normalize_scale** | **Detect matrix_basis residuals first (Step 2)** |
| **Bones snap to wrong pose** | **Action lacks keyframes, matrix_basis was reset** | **Keep matrix_basis; posed-rest covers default** |
| Faces flickering | Z-fighting from coplanar faces | 3-technique anti-flickering |
| Flickering between Parts | Parts compete for same depth | depthBias: 0/10/20 or 0/0/0 |
| Screen flickers on wall | Coplanar with wall | Hardcode + depthBias=100 |
| Model disappears when animated | Data format mismatch | Re-export via Blender MCP |
| Animation looks wrong | Deltas instead of absolute | Ensure ABSOLUTE local transforms |
| Quaternion issues | WXYZ vs XYZW | Data=WXYZ, runtime converts |
| `localTransforms[0]` nil | 0-based jointIndex | Use 1-based in data files |
| File too large / typecheck | Too many skinning entries | Use factorized skinning + flat arrays |
| Model rotates wrong axis | Y-up vs Z-up confusion | Yaw = XY rotation for Z-up |
| `rotationSpeed` does nothing | Missing markNeedsUpdate | Store context |
| Non-triangular faces | Quads/ngons in mesh | Triangulate via bmesh at export |
| `StructRNA removed` error | Evaluated mesh freed too early | Use separate temp mesh for bmesh |
| Colors all same | Not reading category from flat array | `faces[fBase + 4]` for category |
| **Fingers stretched/distorted on re-export** | **Quaternion sign ambiguity in rest local decomposition** | **Detect mismatched bones (dot < 0.95), use `matrix_basis` delta** |
| **Re-export produces different results** | **`decompose()` yields different quaternions across sessions** | **Three-tier hybrid sampling (see Quaternion Sign Ambiguity section)** |
| **Body frozen during partial animation** | **Only head/hands animated, rest receives rest pose** | **Animation composition: merge Idle channels with targeted animation** |

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
- [ ] Materials -> category indices (alphabetical)
- [ ] **Flat arrays**: vertices stride 3, faces stride 4
- [ ] Faces sorted by avgZ before fragmenting
- [ ] Each part has only its used vertices (remapped indices)
- [ ] **Factorized skinning** (patterns + index)
- [ ] **ABSOLUTE local transforms** (not deltas)
- [ ] **WXYZ quaternions** in data files
- [ ] **1-based joint indices** in data files
- [ ] `context:markNeedsUpdate()` for auto-rotation/animation
- [ ] Yaw rotates in XY plane (Z-up)
- [ ] **Anti-flickering**: index field + depthBias + Z_EPSILON sort
- [ ] **Multi-zone coloring** (if applicable): materials -> colorMap + `faces[fBase+4]`
- [ ] **Wall-mounted surfaces** (if any): hardcode flat arrays + depthBias=100
- [ ] **Re-export: quaternion mismatch detection** (dot < 0.95 between Blender and file rest locals)
- [ ] **Re-export: hybrid sampling** (non-keyed -> file rest, keyed+match -> delta, keyed+mismatch -> matrix_basis delta)
- [ ] **Partial animations: composition with Idle** (resample Idle channels at target timing with looping)

---

## Performance Notes

- **~5000 faces** renders smoothly with table.sort
- Each frame: transform -> cull -> light -> project -> sort -> draw
- Paths created in `advance()`, only drawn in `draw()`
- Factorized skinning: minimal overhead (one lookup per vertex)
- depthBias: zero runtime cost (just shifts depth value)
- **Flat arrays**: `table.create(n, 0)` pre-allocation, direct index assignment, no GC from sub-tables
- **Unrolled triangle loop**: fixed stride-4 iteration vs ipairs over face tables

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



## Task Management
**Plan First**
-> **Verify Plan**
-> **Track Progress**
-> **Explain shortly Changes**
-> **Document Results**
-> **Capture Lessons**

## Core Principles
**Simplicity First** · **No Laziness** · **Minimal Impact** · **Root Causes Only**
