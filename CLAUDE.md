# RIVE LUAU SCRIPTING — CLAUDE.md

## Identity
AI assistant for Rive scripting in **pure Luau** (no Roblox libraries).
Prioritize working patterns over theoretical completeness.
Always use `--!strict` mode.

---

## Primary Reference (LERP)

**FETCH before starting any Rive scripting session:**
```
https://forge.mograph.life/apps/lerp/quick-reference
https://forge.mograph.life/apps/lerp/api/core-types
https://forge.mograph.life/apps/lerp/api/drawing
```

**FETCH when needed:**
- Complex interactions: `/apps/lerp/rive/environment`
- Lifecycle issues: `/apps/lerp/getting-started/how-rive-scripts-work`
- ViewModels: `/apps/lerp/advanced/viewmodels`
- Procedural graphics: `/apps/lerp/advanced/procedural`

---

## Critical Rules (Non-Negotiable)

### 1. Lifecycle Returns
| Function | Must Return | Meaning |
|----------|-------------|---------|
| `init()` | `true` | Success, continue |
| `init()` | `false` | Failure, script stops |
| `advance()` | `true` | Keep alive, call next frame |
| `advance()` | `false` | Terminate script |

### 2. Input<T> vs Property<T>

| Type | Access | Mutability | Use Case |
|------|--------|------------|----------|
| `Input<T>` | `self.speed` (direct) | Read-only from script | Editor-exposed values |
| `Property<T>` | `prop.value` | Read/write | ViewModel binding |

```luau
-- Input: read directly
local speed = self.speed  -- NOT self.speed.value

-- Property: use .value
local score = scoreProp.value
scoreProp.value = 100
```

### 3. Hit Detection
- `event:hit()` only works inside `pointerDown()` and `pointerUp()`
- Script must be a **direct CHILD** of the hittable shape
- `hit(true)` = translucent (event may propagate)
- `hit()` or `hit(false)` = stops propagation

### 4. Render Loop Wake
- `context:markNeedsUpdate()` wakes the loop when changes happen **outside** `advance()`
- Use it in listeners, callbacks, or async responses
- Store `context` reference in `init()` for later use

### 5. late() Initializer
Use `late()` for properties set in `init()` instead of the factory:
```luau
return function(): Node<MyScript>
    return {
        path = late(),   -- Created in init()
        paint = late(),  -- Created in init()
    }
end
```

---

## Script Types

| Type | Purpose | Has Lifecycle | Returns |
|------|---------|---------------|---------|
| **Node** | Visual behavior, drawing | Yes | Factory `-> Node<T>` |
| **Util** | Reusable modules | No | Module table |
| **Layout** | Flexbox-like components | Yes | Factory `-> Layout<T>` |
| **Converter** | Data transformation | Yes | Factory `-> Converter<T,I,O>` |
| **PathEffect** | Path manipulation | Yes | Factory `-> PathEffect<T>` |

### When to Use Node vs Util
**Node Script:** draws, needs advance(), responds to inputs
**Util Script:** math helpers, shared types, constants, no visual

---

## Lifecycle Order

```
init() → update() → advance() → draw()
         ↑                        |
         └── on Input change ─────┘
```

| Function | When | Purpose |
|----------|------|---------|
| `init(self, context)` | Once at start | Setup, create Path/Paint |
| `update(self)` | Input changes | Rebuild geometry |
| `advance(self, seconds)` | Every frame | Animation, physics |
| `draw(self, renderer)` | Canvas repaint | Render only, no state changes |

---

## Patterns

### Minimal Node Script
```luau
--!strict

export type MyNode = {
    radius: Input<number>,
    path: Path,
    paint: Paint,
}

local function init(self: MyNode, context: Context): boolean
    self.path = Path.new()
    self.paint = Paint.with({ style = "fill", color = Color.rgb(255, 0, 0) })
    return true
end

local function update(self: MyNode)
    -- Rebuild geometry when inputs change
    self.path:reset()
    -- ... rebuild path using self.radius
end

local function advance(self: MyNode, seconds: number): boolean
    return true  -- Keep alive
end

local function draw(self: MyNode, renderer: Renderer)
    renderer:drawPath(self.path, self.paint)
end

return function(): Node<MyNode>
    return {
        radius = 50,
        path = late(),
        paint = late(),
        init = init,
        update = update,
        advance = advance,
        draw = draw,
    }
end
```

---

## 3D Real-Time Rendering

### Blender to Rive Workflow
1. **Analyze model**: Get vertex/polygon count, materials via Blender MCP
2. **Extract materials**: Convert Blender materials → category indices (1-5)
3. **Export geometry**: Vertices as `{ x, y, z }`, faces as `{ verts, c }`
4. **Fragment if needed**: Split at 350 polygon boundary
5. **Generate scripts**: Data Util files + main Node Script
6. **Map colors**: Expose material colors in Property Group

### Data Structure (Optimized)

Face format uses **category index** instead of RGB:
```luau
-- ❌ WRONG: Verbose, requires runtime color detection
{ verts = { 198, 135, 134, 202 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Compact, direct category mapping
{ verts = { 99, 131, 129, 97 }, c = 1 }  -- c = category index
```

### Category Mapping
| Index | Material Type | Example Use |
|-------|--------------|-------------|
| 1 | Primary metal | Blade, hull, main body |
| 2 | Primary wood/organic | Handle, panels, wrap |
| 3 | Secondary dark | Details, shadows, accents |
| 4 | Highlight metal | Guards, trim, highlights |
| 5 | Edge/trim | Edges, borders, pommel |

### Fragmentation Rules
- **Max 350 polygons per data file** (Rive script limit)
- **Max 500 vertices per data file**
- Split into `ModelPartAData.luau`, `ModelPartBData.luau`, etc.
- Main script loads all parts via `require()` and processes sequentially

### CRITICAL: Vertex Optimization per Part
**Problem:** Sharing all vertices across parts causes "Code is too complex to typecheck" error.

```luau
-- ❌ WRONG: Each part contains ALL 1524 vertices (causes typecheck failure)
NavettePartAData.vertices = { ... 1524 vertices ... }  -- 337 faces use only ~440
NavettePartBData.vertices = { ... 1524 vertices ... }  -- 337 faces use only ~470

-- ✅ CORRECT: Each part contains ONLY its used vertices (indices remapped)
NavettePartAData.vertices = { ... 442 vertices ... }   -- Only what Part A needs
NavettePartBData.vertices = { ... 472 vertices ... }   -- Only what Part B needs
```

**Solution:** When fragmenting, extract only the vertices used by each part and remap face indices:

```python
# Blender export algorithm
def extract_used_vertices(faces, all_vertices):
    # 1. Collect used vertex indices from faces
    used_indices = set()
    for face in faces:
        for v in face["verts"]:
            used_indices.add(v)

    # 2. Create old→new index mapping (1-based for Luau)
    sorted_indices = sorted(used_indices)
    index_map = {old: new + 1 for new, old in enumerate(sorted_indices)}

    # 3. Extract only used vertices
    extracted = [all_vertices[i - 1] for i in sorted_indices]

    # 4. Remap face indices
    remapped_faces = []
    for face in faces:
        new_verts = [index_map[v] for v in face["verts"]]
        remapped_faces.append({"verts": new_verts, "c": face["c"]})

    return extracted, remapped_faces
```

**Result:** ~60% reduction in file size, typecheck passes

### Required Files Structure
```
Model.luau           -- Main Node Script (rendering + Property Group)
ModelPartAData.luau  -- Util: vertices + faces (≤350 polygons)
ModelPartBData.luau  -- Util: vertices + faces (≤350 polygons)
Mesh3DUtil.luau      -- Util: shared 3D math functions
```

### Property Group Template (3D Node Script)

**IMPORTANT:** Parameters must match 3DHandler.luau for consistency.

```luau
export type Model3D = {
  -- Rotation controls
  rotationSpeed: Input<number>,      -- Auto-rotation speed (0 = disabled)
  baseRotationX: Input<number>,      -- Pitch in degrees
  baseRotationY: Input<number>,      -- Yaw in degrees
  baseRotationZ: Input<number>,      -- Roll in degrees
  joystickPitch: Input<number>,      -- Interactive pitch offset
  joystickYaw: Input<number>,        -- Interactive yaw offset
  joystickRoll: Input<number>,       -- Interactive roll offset
  -- Scale and projection (MUST match 3DHandler defaults)
  scale: Input<number>,              -- Multiplier on autoScale (default: 1)
  fov: Input<number>,                -- Field of view for perspective (default: 800)
  cameraDistance: Input<number>,     -- Camera distance for perspective (default: 400)
  usePerspective: Input<boolean>,    -- false = orthographic, true = perspective (default: false)
  -- Anchor position (model center, divided by 100 internally)
  anchorX: Input<number>,
  anchorY: Input<number>,
  anchorZ: Input<number>,
  -- Rendering (MUST match 3DHandler defaults)
  brightness: Input<number>,         -- 0-100, divided by 100 (default: 30 = 0.3)
  faceExpansion: Input<number>,      -- Expand faces from centroid (default: 0.005)
  backfaceCulling: Input<boolean>,   -- Hide back faces (default: true)
  wireframe: Input<boolean>,         -- Show wireframe (default: false)
  -- Animation controls
  animationEnabled: Input<boolean>,
  animationName: Input<string>,
  animationSpeed: Input<number>,
  -- Material colors (one Input<Color> per category, RGBA supported)
  primaryColor: Input<Color>,        -- c=1
  secondaryColor: Input<Color>,      -- c=2
  accentColor: Input<Color>,         -- c=3
  highlightColor: Input<Color>,      -- c=4
  edgeColor: Input<Color>,           -- c=5
  -- Internal state (auto-calculated)
  autoAngleY: number,
  autoScale: number,                 -- Computed: 200 / maxDimension
  boundMinX: number,                 -- Bounding box
  boundMaxX: number,
  boundMinY: number,
  boundMaxY: number,
  boundMinZ: number,
  boundMaxZ: number,
  projectedFaces: { ProjectedFace },
}
```

### Default Values (matching 3DHandler.luau)
| Parameter | Default | Description |
|-----------|---------|-------------|
| `scale` | 1 | Multiplier on autoScale (1 = fit to ~200px) |
| `fov` | 800 | Field of view for perspective mode |
| `cameraDistance` | 400 | Camera distance for perspective mode |
| `usePerspective` | false | false = orthographic (cleaner), true = perspective |
| `brightness` | 30 | Divided by 100 internally (30 = 0.3) |
| `faceExpansion` | 0.005 | Expand faces to eliminate z-fighting gaps |
| `backfaceCulling` | true | Hide faces pointing away from camera |
| `wireframe` | false | Show wireframe instead of filled faces |

### Color Mapping Function
```luau
local function getTintColor(self: Model3D, category: number): Color
  if category == 1 then return self.primaryColor end
  if category == 2 then return self.secondaryColor end
  if category == 3 then return self.accentColor end
  if category == 4 then return self.highlightColor end
  if category == 5 then return self.edgeColor end
  return self.primaryColor  -- fallback
end
```

### Common 3D Export Pitfalls
| Issue | Cause | Solution |
|-------|-------|----------|
| Faces manquantes | Wrong winding order | Reverse vertex order in transformFaceVerts |
| Couleurs incorrectes | Using RGB instead of category | Use `c = index` format in face data |
| Script trop lourd | >350 polygons | Fragment into multiple data files |
| Z-fighting | Faces at same depth | Adjust `faceExpansion` parameter (default: 0.005) |
| Model offset | Wrong anchor point | Use `anchorX/Y/Z` or let auto-center compute from bounds |
| Model too small/large | Wrong scale | Use `autoScale` calculation: `200 / maxDimension` |
| Perspective distortion | Using perspective | Set `usePerspective = false` for cleaner orthographic view |
| Too dark/bright | Wrong brightness | Use `brightness = 30` (divided by 100 = 0.3) |
| **"Code too complex to typecheck"** | **Shared vertices across all parts** | **Extract only used vertices per part + remap indices** |

### Critical: Parameter Consistency with 3DHandler.luau

When creating 3D Node Scripts, parameters **MUST** match 3DHandler.luau defaults for consistent behavior:

```luau
-- Factory return values (matching 3DHandler)
return {
  scale = 1,              -- NOT 30! Uses autoScale multiplier
  fov = 800,              -- NOT 300!
  cameraDistance = 400,   -- REQUIRED for perspective
  usePerspective = false, -- REQUIRED, default = orthographic
  brightness = 30,        -- NOT 0.4! Divided by 100 internally
  faceExpansion = 0.005,
  backfaceCulling = true,
  wireframe = false,
  -- ...
}
```

### Projection Function (matching 3DHandler)
```luau
local function project(x, y, z, fov, distance, usePerspective)
  if usePerspective and distance + z > 0.001 then
    local factor = fov / (distance + z)
    return x * factor, y * factor
  else
    -- Orthographic: just return x, y (scale already applied)
    return x, y
  end
end
```

### Transform Function (GLB-style Y-up coordinates)
```luau
local function transformVertex(vx, vy, vz, ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ)
  local x, y, z = vx - ax, vy - ay, vz - az
  -- Yaw (Y rotation)
  local rx = x * cosY + z * sinY
  local rz = -x * sinY + z * cosY
  x, z = rx, rz
  -- Pitch (X rotation)
  local ry = y * cosX - z * sinX
  local rz2 = y * sinX + z * cosX
  y, z = ry, rz2
  -- Roll (Z rotation)
  local rx2 = x * cosZ - y * sinZ
  local ry2 = x * sinZ + y * cosZ
  return rx2, ry2, z
end
```

---

## RGBA Transparency Support

Colors in Property Group now support alpha channel for transparency:

```luau
-- In Property Group factory
clothingColor = Color.rgba(97, 73, 119, 255),   -- Opaque
ghostColor = Color.rgba(200, 200, 255, 128),    -- 50% transparent
invisibleColor = Color.rgba(0, 0, 0, 0),        -- Fully transparent
```

The alpha value flows through `Mesh3DUtil.mapColorWithTint()` and is preserved in the final rendered color.

---

## Skeletal Animation System

### Required Files
```
Model.luau              -- Main Node Script
ModelPartXData.luau     -- Util: vertices, faces, skeleton, skinning, animations
Mesh3DUtil.luau         -- Util: 3D math + matrix/quaternion functions
SkeletalAnimUtil.luau   -- Util: skeleton building, animation sampling, skinning
```

### Data Structure for Animated Models

```luau
-- In your Data file (e.g., CloudPartAData.luau)

ModelData.skeleton = {
  jointCount = 5,
  jointParents = { nil, 1, 2, 2, 1 },  -- nil for root joints
  inverseBindMatrices = {
    { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 },  -- Mat4 per joint
    -- ...
  },
  restPose = {
    { translation = {0,0,0}, rotation = {0,0,0,1}, scale = {1,1,1} },
    -- ...
  },
}

ModelData.skinning = {
  joints = { 0,0,0,0, 1,2,0,0, ... },   -- 4 joint indices per vertex
  weights = { 1,0,0,0, 0.5,0.5,0,0, ... }, -- 4 weights per vertex (sum to 1)
}

ModelData.animations = {
  ["idle"] = {
    name = "idle",
    duration = 2.0,
    channels = {
      {
        jointIndex = 1,
        path = "translation",  -- or "rotation" or "scale"
        times = { 0, 1, 2 },
        values = { 0,0,0, 0,0.1,0, 0,0,0 },  -- 3 floats per keyframe (vec3)
      },
      {
        jointIndex = 2,
        path = "rotation",
        times = { 0, 0.5, 1 },
        values = { 0,0,0,1, 0,0,0.38,0.92, 0,0,0,1 },  -- 4 floats per keyframe (quat)
      },
    },
  },
  ["walk"] = { ... },
}
```

### Animation Property Group Inputs

```luau
export type Model3D = {
  -- Animation controls
  animationEnabled: Input<boolean>,  -- Toggle animation on/off
  animationName: Input<string>,      -- Name of clip to play ("idle", "walk", etc.)
  animationSpeed: Input<number>,     -- Playback speed multiplier (1.0 = normal)
  -- ...
}
```

### Animation Functions (SkeletalAnimUtil)

```luau
local SkelAnim = require('SkeletalAnimUtil')

-- Build skeleton from data
local skeleton = SkelAnim.buildSkeleton(data.skeleton)

-- Sample animation at current time
SkelAnim.sampleAnimation(skeleton, animationClip, time)

-- Update world/skin matrices
SkelAnim.updateSkeleton(skeleton)

-- Skin vertices
local skinnedVerts = SkelAnim.skinVertices(skeleton, originalVertices, skinningData)

-- Blend between two animations
SkelAnim.blendAnimations(skeleton, clipA, clipB, timeA, timeB, blendFactor)

-- Reset to rest pose
SkelAnim.resetToRestPose(skeleton, data.skeleton.restPose)
```

### Skeleton Initialization Pattern (Nil-Safe)

**CRITICAL:** When initializing skeleton and animations, avoid accessing properties on nullable types. Use local variables to capture non-nil values:

```luau
-- ❌ WRONG: self.skeleton could be nil when accessing jointCount
local function initSkeleton(self: Model3D)
  local skeletonData = (DataFile :: any).skeleton
  if skeletonData then
    self.skeleton = SkelAnim.buildSkeleton(skeletonData)
    print("Joints:", self.skeleton.jointCount)  -- ERROR: could be nil

    local animations = (DataFile :: any).animations
    if animations then
      self.currentAnimation = animations["idle"]
      print("Duration:", self.currentAnimation.duration)  -- ERROR: could be nil
    end
  end
end

-- ✅ CORRECT: Use local variables to capture non-nil values
local function initSkeleton(self: Model3D)
  local skeletonData = (DataFile :: any).skeleton
  if skeletonData then
    local skeleton = SkelAnim.buildSkeleton(skeletonData)
    self.skeleton = skeleton
    print("Joints:", skeleton.jointCount)  -- OK: skeleton is not nil here

    -- Cast animations to proper type for type safety
    local animations = (DataFile :: any).animations :: { [string]: SkelAnim.AnimationClip }?
    if animations then
      local clip = animations["idle"]
      if clip then
        self.currentAnimation = clip
        print("Duration:", clip.duration)  -- OK: clip is not nil here
      end
    end
  end
end
```

**Key patterns:**
1. Store function result in local variable before assigning to `self`
2. Use type cast `:: { [string]: SkelAnim.AnimationClip }?` for untyped data
3. Always check if value exists before accessing its properties

### Blender Export Workflow for Animations

1. **Rig your model** with an Armature
2. **Paint vertex weights** for each bone
3. **Create animations** (Actions) in the Action Editor
4. **Export** using Python script to extract:
   - Skeleton hierarchy (parent indices)
   - Inverse bind matrices (from `bone.matrix_local.inverted()`)
   - Rest pose TRS (from `bone.matrix_local.decompose()`)
   - Skinning data (vertex groups → joints/weights)
   - Animation keyframes (fcurves → times/values per channel)

### Animation Pitfalls
| Issue | Cause | Solution |
|-------|-------|----------|
| **Model explodes during animation** | **Quaternion format mismatch (WXYZ vs XYZW)** | **Blender exports WXYZ `{w,x,y,z}`, convert to XYZW `{x,y,z,w}` for SkeletalAnimUtil** |
| **Animation amplified/stretched** | **Armature scale ≠ 1 in Blender** | **Extract skeleton with scale=1 (see section below)** |
| Model explodes | Wrong inverse bind matrices | Check matrix export order (column-major) |
| Animation wrong speed | Duration mismatch | Verify duration matches last keyframe time |
| Jerky motion | Missing keyframes | Ensure smooth interpolation in Blender |
| Wrong rotation | Quaternion sign flip | Use `quatSlerp` for proper interpolation |
| Joints don't affect mesh | Missing skinning data | Check vertex weights sum to 1.0 |
| **"could be nil" typecheck** | Accessing `.property` on nullable `self.field` | Use local variable: `local x = func(); self.x = x; print(x.prop)` |
| **"Expected AnimationClip, got unknown"** | Untyped `animations` table from `any` | Cast: `(Data :: any).animations :: { [string]: SkelAnim.AnimationClip }?` |
| **table.sort comparator error** | Inline function in `table.sort` not supported | Use manual bubble sort (see below) |
| **"Path was modified between draws"** | Calling `path:reset()` in `draw()` | Build paths in `advance()`, store in ProjectedFace, only draw in `draw()` |
| **"Key joints not found in skeleton"** | Using `skeleton.joints[i]` | Use `skeleton.skinMatrices[i]` - Skeleton type has no `joints` field |

### CRITICAL: Armature Scale Problem

When Blender's armature has `scale ≠ 1` (common in GLB imports), the skeleton transforms get mixed with the scale factor, causing animation to be amplified or distorted.

**Problem scenario:**
- Armature has scale = 100 (from GLB import)
- Vertices are normalized to ~200 units (scale factor = 17)
- Combined scale = 100 × 17 = 1700 gets baked into bone matrices
- Animation rotations apply at this huge scale, causing explosion

**Solution: Extract skeleton with scale = 1**

```python
# In Blender Python export script:

# 1. Get normalized bone world matrix
bone_world = arm_world @ bone.matrix_local
bone_norm = normalize_mat @ bone_world  # includes center + scale

# 2. Decompose and FORCE scale to 1
loc, rot, scl = bone_norm.decompose()
world_mat_no_scale = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

# 3. Calculate local transform relative to parent (also with scale=1)
if bone.parent:
    parent_world = arm_world @ bone.parent.matrix_local
    parent_norm = normalize_mat @ parent_world
    _, parent_rot, _ = parent_norm.decompose()
    parent_mat = Matrix.LocRotScale(parent_norm.translation, parent_rot, Vector((1,1,1)))
    local_mat = parent_mat.inverted() @ world_mat_no_scale
else:
    local_mat = world_mat_no_scale

# 4. Extract rest pose from local matrix
local_loc, local_rot, _ = local_mat.decompose()
rest_pose = {
    "translation": [local_loc.x, local_loc.y, local_loc.z],
    "rotation": [local_rot.w, local_rot.x, local_rot.y, local_rot.z],  # WXYZ
    "scale": [1.0, 1.0, 1.0]  # ALWAYS 1
}

# 5. IBM = inverse of world_mat_no_scale
ibm = world_mat_no_scale.inverted()
```

**Key insight:** The skeleton works in the SAME normalized space as vertices, with scale=1 everywhere. The normalization scale is already baked into the vertex positions, so the skeleton should NOT re-apply it.

### CRITICAL: Quaternion Format Conversion
Blender exports quaternions in **WXYZ** format `{w, x, y, z}`, but `Mesh3DUtil.mat4FromQuat()` expects **XYZW** format `{x, y, z, w}`.

**SkeletalAnimUtil handles this automatically** for:
- Rest pose rotations (in `buildSkeleton`)
- Animation keyframe rotations (in `sampleQuat`)
- Reset to rest pose (in `resetToRestPose`)

**If exporting raw data from Blender, quaternions must be converted:**
```luau
-- Blender WXYZ: { w, x, y, z }
-- Internal XYZW: { x, y, z, w }
local blenderQuat = { 1.0, 0.0, 0.0, 0.0 }  -- Identity in WXYZ
local internalQuat = { blenderQuat[2], blenderQuat[3], blenderQuat[4], blenderQuat[1] }  -- XYZW
```

### Rive Luau Restrictions for 3D Scripts

**1. CRITICAL: Path modification in draw() is FORBIDDEN**
```luau
-- ❌ WRONG: Modifying path in draw() causes "Path was modified between draws"
local function draw(self: Model, renderer: Renderer)
    for _, face in ipairs(self.projectedFaces) do
        self.path:reset()  -- ERROR! Cannot modify in draw()
        self.path:moveTo(...)
        renderer:drawPath(self.path, paint)
    end
end

-- ✅ CORRECT: Create paths in advance(), store in ProjectedFace
export type ProjectedFace = {
    path: Path,  -- Each face has its own pre-built path
    depth: number,
    color: Color,
}

local function processFaces(self: Model, ...)
    -- Build path here, in advance()
    local facePath = Path.new()
    facePath:moveTo(Vector.xy(projected2D[1][1], projected2D[1][2]))
    for idx = 2, #projected2D do
        facePath:lineTo(Vector.xy(projected2D[idx][1], projected2D[idx][2]))
    end
    facePath:close()

    table.insert(self.projectedFaces, {
        path = facePath,
        depth = avgZ,
        color = litColor,
    })
end

local function draw(self: Model, renderer: Renderer)
    for _, face in ipairs(self.projectedFaces) do
        local fillPaint = Paint.with({ style = "fill", color = face.color })
        renderer:drawPath(face.path, fillPaint)  -- Just draw, no modification
    end
end
```

**2. table.sort with custom comparator NOT supported**
```luau
-- ❌ WRONG: Rive Luau doesn't support inline comparators
table.sort(faces, function(a, b)
  return a.depth < b.depth
end)

-- ✅ CORRECT: Use manual bubble sort
local n = #faces
for i = 1, n - 1 do
  for j = 1, n - i do
    if faces[j].depth > faces[j + 1].depth then
      faces[j], faces[j + 1] = faces[j + 1], faces[j]
    end
  end
end
```

**2. Type casting for untyped data tables**
```luau
-- ❌ WRONG: Direct access to animations table
local animations = PartAData.animations
local clip = animations["swim"]
self.currentAnimation = clip  -- ERROR: type mismatch

-- ✅ CORRECT: Cast through `any` with explicit type
local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
if animations then
  local clip = animations["swim"]
  if clip then
    self.currentAnimation = clip  -- OK: type is now correct
  end
end
```

**3. Skeleton initialization pattern**
```luau
-- ❌ WRONG: Accessing property on potentially nil self.skeleton
local skeletonData = PartAData.skeleton
if skeletonData then
  self.skeleton = SkelAnim.buildSkeleton(skeletonData)
  print(self.skeleton.jointCount)  -- ERROR: could be nil
end

-- ✅ CORRECT: Use local variable first
local skeletonData = PartAData.skeleton
if skeletonData then
  local skeleton = SkelAnim.buildSkeleton(skeletonData)
  self.skeleton = skeleton
  print(skeleton.jointCount)  -- OK: skeleton is not nil here
end
```

**4. Skeleton structure: use skinMatrices NOT joints**
```luau
-- ❌ WRONG: skeleton.joints doesn't exist!
local joint = skeleton.joints[jointIdx]
local skinMat = joint.skinMatrix

-- ✅ CORRECT: Access skinMatrices directly
local skinMat = skeleton.skinMatrices[jointIdx]
if skinMat then
    local tx, ty, tz = M.mat4TransformPoint(skinMat, v.x, v.y, v.z)
end
```

The `Skeleton` type from SkeletalAnimUtil has this structure:
```luau
export type Skeleton = {
  jointCount: number,
  jointParents: { number? },
  inverseBindMatrices: { Mat4 },
  localTransforms: { JointState },
  worldMatrices: { Mat4 },
  skinMatrices: { Mat4 },  -- USE THIS for vertex skinning
}
```

**5. Skinning data format options**

Two formats exist - choose based on your data structure:

```luau
-- Format A: Flat arrays (SkeletalAnimUtil.skinVertices expects this)
ModelData.skinning = {
  joints = { 0,0,0,0, 1,2,0,0, ... },   -- 4 joint indices per vertex (flat)
  weights = { 1,0,0,0, 0.5,0.5,0,0, ... }, -- 4 weights per vertex (flat)
}

-- Format B: Per-vertex objects (requires custom skinVertices function)
type SkinEntry = { j: { number }, w: { number } }
ModelData.skinning = {
  { j = { 0, 1, 9, 6 }, w = { 0.786714, 0.105125, 0.054674, 0.053487 } },
  { j = { 1, 2, 6, 9 }, w = { 0.873805, 0.06892, 0.036851, 0.020424 } },
  -- ...
}

-- Custom skinVertices for Format B:
local function skinVertices(
    skeleton: SkelAnim.Skeleton,
    vertices: { { x: number, y: number, z: number } },
    skinning: { SkinEntry }
): { { x: number, y: number, z: number } }
    local result: { { x: number, y: number, z: number } } = {}

    for i, v in ipairs(vertices) do
        local skin = skinning[i]
        local sx, sy, sz = 0.0, 0.0, 0.0

        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- 0-based to 1-based
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

        local vert: { x: number, y: number, z: number } = { x = sx, y = sy, z = sz }
        table.insert(result, vert)
    end

    return result
end
```

### Mesh3DUtil Functions (Reference)
```luau
M.toRadians(degrees)                    -- Convert to radians
M.project(x, y, z, fov, dist)           -- Perspective projection
M.calculateNormal(x1,y1,z1, x2,y2,z2, x3,y3,z3)  -- Face normal
M.calculateLighting(nx, ny, nz, base)   -- Diffuse lighting
M.transformVertex(vx,vy,vz, ax,ay,az, cosX,sinX, cosY,sinY, cosZ,sinZ)
```

---

### Interactive with Hit Detection
```luau
--!strict

export type Button = {
    isPressed: boolean,
    context: Context?,
    path: Path,
    paint: Paint,
}

local function init(self: Button, context: Context): boolean
    self.context = context
    self.path = Path.new()
    self.paint = Paint.with({ style = "fill", color = Color.rgb(80, 140, 220) })
    -- Build initial path...
    return true
end

local function pointerDown(self: Button, event: PointerEvent)
    if event:hit() then
        self.isPressed = true
        self.paint = Paint.with({ style = "fill", color = Color.rgb(60, 120, 200) })
    end
end

local function pointerUp(self: Button, event: PointerEvent)
    if event:hit() then
        self.isPressed = false
        self.paint = Paint.with({ style = "fill", color = Color.rgb(80, 140, 220) })
    end
end

local function draw(self: Button, renderer: Renderer)
    renderer:drawPath(self.path, self.paint)
end

return function(): Node<Button>
    return {
        isPressed = false,
        context = nil,
        path = late(),
        paint = late(),
        init = init,
        pointerDown = pointerDown,
        pointerUp = pointerUp,
        draw = draw,
    }
end
```

### ViewModel Listener with markNeedsUpdate
```luau
--!strict

export type ReactiveNode = {
    context: Context?,
    score: number,
    scoreProp: Property<number>?,
}

local function init(self: ReactiveNode, context: Context): boolean
    self.context = context

    local vm = context:viewModel()
    if vm then
        local prop = vm:getNumber("score")
        if prop then
            self.scoreProp = prop
            self.score = prop.value

            prop:addListener(function()
                self.score = prop.value
                -- Wake render loop (we're outside advance)
                if self.context then
                    self.context:markNeedsUpdate()
                end
            end)
        end
    end

    return true
end

local function advance(self: ReactiveNode, seconds: number): boolean
    return true
end

return function(): Node<ReactiveNode>
    return {
        context = nil,
        score = 0,
        scoreProp = nil,
        init = init,
        advance = advance,
    }
end
```

### State Machine Pattern
```luau
--!strict

export type ButtonState = "idle" | "hover" | "pressed"

export type StatefulButton = {
    state: ButtonState,
    targetScale: number,
    paint: Paint,
}

local SCALE: { [ButtonState]: number } = {
    idle = 1.0,
    hover = 1.1,
    pressed = 0.95,
}

local COLOR: { [ButtonState]: Color } = {
    idle = Color.rgb(80, 140, 220),
    hover = Color.rgb(100, 160, 240),
    pressed = Color.rgb(60, 120, 200),
}

local function setState(self: StatefulButton, newState: ButtonState)
    self.state = newState
    self.targetScale = SCALE[newState]
    self.paint = Paint.with({ style = "fill", color = COLOR[newState] })
end
```

### Util Script (Module)
```luau
--!strict
-- File: Easing.lua (Util Script)

local Easing = {}

function Easing.lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

function Easing.easeInQuad(t: number): number
    return t * t
end

function Easing.easeOutQuad(t: number): number
    return 1 - (1 - t) * (1 - t)
end

function Easing.easeInOutQuad(t: number): number
    if t < 0.5 then
        return 2 * t * t
    else
        return 1 - ((-2 * t + 2) ^ 2) / 2
    end
end

return Easing

-- Usage in Node script:
-- local Easing = require("Easing")
-- local eased = Easing.easeInOutQuad(t)
```

---

## API Quick Reference

### Constructors
```luau
Vector.xy(x, y)              -- 2D vector (alias: Vec2D)
Vector.origin()              -- (0, 0)
Path.new()                   -- Empty path
Paint.new()                  -- Default paint
Paint.with({ ... })          -- Paint with options
Color.rgb(r, g, b)           -- Opaque (0-255 each)
Color.rgba(r, g, b, a)       -- With alpha
Mat2D.identity()
Mat2D.withTranslation(x, y)
Mat2D.withRotation(radians)
Mat2D.withScale(sx, sy)
Gradient.linear(from, to, stops)
Gradient.radial(center, radius, stops)
```

### Color (Static Accessors)
```luau
-- Get channel
Color.red(c)      -- returns number
Color.green(c)
Color.blue(c)
Color.alpha(c)    -- 0-255
Color.opacity(c)  -- 0.0-1.0

-- Set channel (returns NEW color)
Color.red(c, 128)     -- new color with red=128
Color.opacity(c, 0.5) -- new color with 50% opacity

-- Interpolate
Color.lerp(from, to, t)
```

### Paint Options
```luau
Paint.with({
    style = "fill" | "stroke",
    color = Color.rgb(255, 0, 0),
    thickness = 2,              -- stroke only
    cap = "butt" | "round" | "square",
    join = "miter" | "round" | "bevel",
    blendMode = "srcOver" | "multiply" | ...,
    gradient = Gradient.linear(...),
    feather = 0,
})

-- Copy with overrides
local highlight = basePaint:copy({ color = Color.rgb(255, 255, 0) })
```

### Path Methods
```luau
path:moveTo(Vector)
path:lineTo(Vector)
path:quadTo(control, to)
path:cubicTo(ctrlOut, ctrlIn, to)
path:close()
path:reset()                    -- Clear (don't call in draw!)
path:add(otherPath, transform?)
path:measure() -> PathMeasure
path:contours() -> ContourMeasure?
#path                           -- Command count
```

### PathMeasure
```luau
measure.length                  -- Total length
measure.isClosed                -- Single closed contour?
measure:positionAndTangent(distance) -> (Vector, Vector)
measure:warp(point)             -- X=distance along, Y=perpendicular offset
measure:extract(start, end, destPath, startWithMove?)
```

### Vector Operations
```luau
v.x, v.y                        -- Components (read-only)
v[1], v[2]                      -- Index access
v:length()
v:lengthSquared()               -- Faster for comparisons
v:normalized()
v:distance(other)
v:distanceSquared(other)
v:dot(other)
v:lerp(other, t)

-- Operators
v1 + v2, v1 - v2
v * scalar, v / scalar
-v                              -- Negation
v1 == v2
```

### Mat2D
```luau
mat.xx, mat.xy, mat.yx, mat.yy  -- Scale/rotation
mat.tx, mat.ty                  -- Translation
mat:invert() -> Mat2D?
mat:isIdentity() -> boolean
mat * vector                    -- Transform point
mat1 * mat2                     -- Combine (mat2 first, then mat1)
```

### Renderer
```luau
renderer:drawPath(path, paint)
renderer:drawImage(image, sampler, blendMode, opacity)
renderer:save()                 -- Push state
renderer:restore()              -- Pop state (MUST pair with save!)
renderer:transform(mat)
renderer:clipPath(path)
```

### ViewModel Access
```luau
local vm = context:viewModel()
vm:getNumber("name")    -> Property<number>?
vm:getString("name")    -> Property<string>?
vm:getBoolean("name")   -> Property<boolean>?
vm:getColor("name")     -> Property<Color>?
vm:getTrigger("name")   -> PropertyTrigger?
vm:getList("name")      -> PropertyList?
vm:getEnum("name")      -> PropertyEnum?

-- Property usage
prop.value              -- get/set
prop:addListener(fn)
prop:removeListener(fn)

-- Trigger
trigger:fire()
trigger:addListener(fn)
```

### PointerEvent
```luau
event.position          -- Vector (local coords)
event.id                -- Pointer ID (multitouch)
event:hit()             -- Consume, stop propagation
event:hit(true)         -- Translucent, may continue

-- Forward to nested artboard
local childEvent = PointerEvent.new(event.id, transformedPos)
```

---

## Performance Rules

### DO
- Create Path/Paint **once** in `init()` for static shapes
- For dynamic 3D: create paths in `advance()`, store in data structures
- Rebuild geometry in `update()` using `path:reset()` (NOT in `draw()`)
- Keep `draw()` lightweight (render only, NO modifications)
- Reuse objects, pool particles
- Use `lengthSquared()` for distance comparisons

### DON'T
- **NEVER** call `path:reset()` or modify paths in `draw()`
- Allocate in `draw()` or tight loops
- `print()` in loops
- Define functions inside lifecycle callbacks
- Create unbounded tables (lists that only grow)

```luau
-- BAD: allocation every frame
function draw(self, renderer)
    local path = Path.new()  -- NO!
end

-- BAD: modifying path in draw()
function draw(self, renderer)
    self.path:reset()  -- NO! Causes "Path was modified between draws"
    self.path:moveTo(...)
end

-- GOOD: for static shapes
function draw(self, renderer)
    renderer:drawPath(self.path, self.paint)
end

-- GOOD: for dynamic 3D (paths created in advance)
function advance(self, seconds)
    self.projectedFaces = {}
    for _, face in ipairs(faces) do
        local facePath = Path.new()
        facePath:moveTo(...)
        facePath:close()
        table.insert(self.projectedFaces, { path = facePath, color = c })
    end
    return true
end

function draw(self, renderer)
    for _, face in ipairs(self.projectedFaces) do
        renderer:drawPath(face.path, Paint.with({ color = face.color }))
    end
end
```

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `advance()` returns nothing | Always `return true` or `false` |
| `event.hit` | Use `event:hit()` (method call) |
| Script not child of shape | Hierarchy matters for hit detection |
| Using `self.input.value` | `Input<T>` reads directly: `self.input` |
| Forgetting `markNeedsUpdate()` | Call it in listeners/callbacks |
| Unbalanced `save()`/`restore()` | Always pair them |
| Color via `c.red` | Use `Color.red(c)` (static) |
| **Modifying Path in `draw()`** | **Build paths in `advance()`, only render in `draw()`** |
| **`path:reset()` in `draw()`** | **Causes "Path was modified between draws" error** |

---

## Anti-Patterns

### Mixing Concerns
```luau
-- BAD: helpers inside lifecycle
function advance(self, seconds)
    local function lerp(a, b, t)  -- Recreated every frame!
        return a + (b - a) * t
    end
end

-- GOOD: use Util script or local at module level
local function lerp(a, b, t)
    return a + (b - a) * t
end
```

### God Util Scripts
```luau
-- BAD: one massive Utils.lua with everything
-- GOOD: separate by domain (Easing.lua, Colors.lua, Math.lua)
```

### Circular Dependencies
```luau
-- BAD: A requires B, B requires A
-- GOOD: extract shared code to third module
```

---

## Tests Pattern
```luau
--!strict

function setup(test: Tester)
    test.group("Math operations", function()
        test.case("lerp works", function(expect)
            expect(lerp(0, 100, 0.5)).is(50)
        end)

        test.case("comparisons", function(expect)
            expect(5).greaterThan(3)
            expect(2).lessThanOrEqual(2)
            expect(1).never.is(2)
        end)
    end)
end

return function(): Tests
    return setup
end
```

---

## Rive MCP Tools (if connected)

| Tool | Purpose |
|------|---------|
| `text_editor` | View/edit scripts |
| `script_diagnostics` | Linting |
| `compile_script` | Apply to VM |
| `read_console` | Debug output |
| `animation_editor` | Animations |
| `layout_editor` | Flexbox |
| `viewmodel_editor` | Data binding |

**Workflow:** Create or Edit → Diagnostics → Compile → Debug
