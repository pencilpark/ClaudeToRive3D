# Blender to Rive 3D Animation Pipeline

Import rigged 3D models with skeletal animations from Blender into Rive using Luau scripts.

![Pipeline Overview](https://img.shields.io/badge/Blender-Rive-blue)
![Blender MCP](https://img.shields.io/badge/MCP-Blender-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## VIDEO TUTORIAL
https://x.com/fredberria/status/2016568637310513207?s=20

---
## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Requirements](#requirements)
4. [Tutorial: Step by Step](#tutorial-step-by-step)
   - [Method 1: Using Blender MCP (Recommended)](#method-1-using-blender-mcp-recommended)
   - [Method 2: Using Standalone Script](#method-2-using-standalone-script)
5. [File Structure](#file-structure)
6. [Data Format](#data-format)
7. [Configuration Reference](#configuration-reference)
8. [Property Group Reference](#property-group-reference)
9. [Troubleshooting](#troubleshooting)
10. [Advanced Topics](#advanced-topics)

---

## Overview

This pipeline allows you to:
- Export rigged 3D models from Blender with skeletal animations
- Render them in real-time in Rive using Luau scripts
- Control animations via Rive Inputs (play, pause, switch animations)
- Customize colors and rendering parameters

**Key Features:**
- Automatic mesh normalization (~200 units)
- Automatic fragmentation for large meshes (~1900 faces per part)
- Multiple animation support with runtime switching
- Full skeletal animation with vertex skinning
- Customizable material colors via Property Group
- **Optimized flat array format** for vertices and faces (~33% file size reduction)
- **Factorized skinning** (patterns + index, ~40% smaller)
- **Blender MCP integration** for AI-assisted conversion

---

## Quick Start

### With Blender MCP (Recommended)

```
1. Install Blender MCP in your Claude Code environment
2. Open your .blend file in Blender
3. Use Claude Code with the prompt from prompt.md
4. AI extracts geometry, skeleton, and animations automatically
5. Copy generated .luau files to Rive
```

### With Standalone Script

```bash
# 1. In Blender: Configure and run the export script
# Edit MODEL_NAME in blender_to_rive.py, then run with Alt+P

# 2. Optimize data files to flat arrays
python3 convert_flat.py

# 3. Copy generated files to your Rive project

# 4. Create your main Node Script based on the example template

# 5. In Rive: Set animationName Input to play animations
```

---

## Requirements

### For Blender MCP Method
- **Claude Code** with Blender MCP installed
- **Blender 3.0+** running with MCP connection
- Model with Armature, vertex weights, and Actions

### For Standalone Script Method
- **Blender 3.0+** (tested on 4.x)
- **Python 3** (for `convert_flat.py` post-processing)
- Model must have:
  - Armature (skeleton)
  - Vertex weights painted
  - At least one Action (animation)

### For Rive
- Rive Editor with Scripting enabled
- Luau runtime support

---

## Tutorial: Step by Step

### Method 1: Using Blender MCP (Recommended)

The Blender MCP allows AI to directly interact with your Blender scene, extracting all necessary data automatically.

#### Step 1: Setup

1. Install [Blender MCP](https://github.com/ahujasid/blender-mcp) in your environment
2. Open your `.blend` file in Blender
3. Ensure MCP connection is active

#### Step 2: Use Claude Code

Copy the prompt from `prompt.md` and provide your model details:

```
I want to import a rigged 3D model with skeletal animation from Blender to Rive.

Model details:
- Model name: MyCharacter
- Blender file: character.blend
- Expected animations: Idle, Walk, Run
- Material categories: Skin, Clothing, Hair

Please extract the geometry, skeleton, and animations using Blender MCP.
```

#### Step 3: AI Extraction

Claude Code will:
1. Analyze your scene with `mcp__blender__get_scene_info`
2. Extract geometry with `mcp__blender__execute_blender_code`
3. Extract skeleton hierarchy and IBMs
4. Extract skinning weights
5. Extract all animation clips
6. Generate ready-to-use `.luau` files with flat array format

#### Step 4: Copy to Rive

Copy the generated files:
- `ModelPartAData.luau`, `ModelPartBData.luau`, etc.
- Create/adapt the main Node Script
- Copy utility scripts if not already present

---

### Method 2: Using Standalone Script

#### Step 1: Prepare Your Model in Blender

Your model needs:
- **Armature** (skeleton with bones)
- **Mesh** parented to the armature
- **Vertex Groups** matching bone names
- **Weight painting** for smooth deformation

**CRITICAL: Verify Armature Scale**

```
1. Select the Armature
2. Press Ctrl+A -> Apply All Transforms
3. Verify in Properties panel: Scale = 1.000, 1.000, 1.000
```

#### Step 2: Create Animations

1. Open the **Action Editor** (Shift+F12)
2. Create a **New Action** for each animation
3. Name your actions clearly (e.g., "Swim", "Idle", "Walk")
4. Keyframe your bone poses

**Note:** Animation names will be exported as `"Armature|ActionName"`

#### Step 3: Configure the Export Script

Open `blender_to_rive.py` and edit:

```python
MODEL_NAME = "YourModel"       # Output file prefix
TARGET_SIZE = 200.0            # Normalize to ~200 units
OUTPUT_DIR = "//"              # Output directory
MAX_FACES_PER_PART = 1900     # Auto-fragment threshold
```

#### Step 4: Run the Export

1. Go to **Scripting** workspace in Blender
2. Click **Open** and select `blender_to_rive.py`
3. **Select your Armature** (or Mesh)
4. Press **Alt+P** to run

#### Step 5: Optimize to Flat Arrays

```bash
python3 convert_flat.py
```

This converts vertices from `{x=N, y=N, z=N}` to flat `N, N, N,` and faces from `{verts={a,b,c}, c=N}` to flat `a, b, c, N,` — saving ~33% file size.

#### Step 6: Copy to Rive

Copy these files to your Rive project:
- `YourModelPartAData.luau`, `YourModelPartBData.luau`, etc.
- `Mesh3DUtil.luau`
- `SkeletalAnimUtil.luau`

---

## File Structure

```
project/
├── blender_to_rive.py        # Standalone Blender export script
├── convert_flat.py           # Convert data files to flat arrays (post-export)
├── prompt.md                 # AI prompt for Blender MCP workflow
├── Mesh3DUtil.luau           # 3D math (matrices, quaternions, projection)
├── SkeletalAnimUtil.luau     # Skeleton building, animation, skinning
├── Model.luau                # Main Node Script (rendering + Property Group)
├── ModelPartAData.luau       # Generated data: vertices, faces, skeleton, skinning
├── ModelPartBData.luau       # Generated data: vertices, faces, skinning
├── ModelAnim1Data.luau       # Generated data: animation clips
├── CLAUDE.md                 # Full technical documentation
└── README.md                 # This file
```

---

## Data Format

### Flat Arrays (Optimized)

Vertices and faces use **flat number arrays** for ~33% smaller file sizes:

```luau
-- Vertices: flat array, stride 3 (x, y, z per vertex)
ModelData.vertices = {
    10.825, -18.875, -1.141,
    11.296, -19.324, 1.685,
    -- ...
}
-- Access vertex i: base = (i - 1) * 3
-- vx = vertices[base + 1], vy = vertices[base + 2], vz = vertices[base + 3]

-- Faces: flat array, stride 4 (v1, v2, v3, category per face)
ModelData.faces = {
    4150, 4151, 4152, 1,
    4151, 4150, 4153, 1,
    -- ...
}
-- Access face fi (0-based): fBase = fi * 4
-- vi1 = faces[fBase + 1], category = faces[fBase + 4]
```

### Skeleton & Skinning

```luau
ModelData.skeleton = {
    jointCount = 13,
    jointParents = { nil, 1, 2, 2, 1, ... },
    inverseBindMatrices = { { 16 floats }, ... },
    restPose = {
        { translation = {x,y,z}, rotation = {w,x,y,z}, scale = {1,1,1} },
        ...
    },
}

-- Factorized skinning: patterns + per-vertex index
ModelData.skinningPatterns = {
    [0] = { j = {0,0,0,0}, w = {1.0,0,0,0} },
    [1] = { j = {1,0,0,0}, w = {1.0,0,0,0} },
    ...
}
ModelData.skinningIndex = { 1, 1, 1, 6, 6, 2, ... }  -- Per vertex
```

### Animations

```luau
ModelData.animations = {
    ["Armature|Swim"] = {
        name = "Armature|Swim",
        duration = 4.21,
        channels = { ... }
    },
}
```

---

## Configuration Reference

### blender_to_rive.py Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `MODEL_NAME` | "Model" | Output file prefix |
| `TARGET_SIZE` | 200.0 | Normalize mesh to this size |
| `OUTPUT_DIR` | "//" | Output directory (// = relative to .blend) |
| `MAX_FACES_PER_PART` | 1900 | Fragment threshold for faces |

### convert_flat.py

| Setting | Default | Description |
|---------|---------|-------------|
| `FILES` | (list) | Part data files to convert |
| `BASE_DIR` | script dir | Directory containing .luau files |

Edit the `FILES` list at the top of `convert_flat.py` to match your model's Part data files.

---

## Property Group Reference

### Rotation Controls
| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `rotationSpeed` | Number | 0 | Auto-rotation speed (0 = disabled) |
| `baseRotationX` | Number | 0 | Pitch in degrees |
| `baseRotationY` | Number | 0 | Yaw in degrees |
| `baseRotationZ` | Number | 0 | Roll in degrees |
| `joystickPitch` | Number | 0 | Interactive pitch offset |
| `joystickYaw` | Number | 0 | Interactive yaw offset |
| `joystickRoll` | Number | 0 | Interactive roll offset |

### Scale and Projection
| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `scale` | Number | 1 | Scale multiplier |
| `fov` | Number | 800 | Field of view (perspective mode) |
| `cameraDistance` | Number | 400 | Camera distance (perspective mode) |
| `usePerspective` | Boolean | false | false = orthographic, true = perspective |

### Rendering
| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `brightness` | Number | 50 | Brightness (0-100, divided by 100) |
| `faceExpansion` | Number | 0.05 | Expand faces to eliminate gaps |
| `backfaceCulling` | Boolean | true | Hide back-facing faces |
| `wireframe` | Boolean | false | Wireframe mode |

### Animation
| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `animationEnabled` | Boolean | true | Enable/disable animation |
| `animationName` | String | "" | Animation to play (empty = first available) |
| `animationSpeed` | Number | 1 | Playback speed multiplier |

---

## Troubleshooting

### Model Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Model twisted when animated | Coordinate space mismatch | Re-export with posed rest reference |
| Model explodes during animation | Armature scale != 1 | Apply transforms in Blender (Ctrl+A) |
| Body parts scattered | Different reference poses | Use posed rest for ALL exports |
| Some faces missing | Wrong winding order | Check normals in Blender |
| Z-fighting (flickering) | Faces at same depth | Use anti-flickering (depthBias + Z_EPSILON) |

### Animation Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Animation doesn't play | Wrong animation name | Check console for available names |
| Animation plays wrong | Multiple actions exported | Set correct `animationName` |
| Arms in T-pose | `matrix_basis` reset | Never reset matrix_basis |
| Body frozen in partial anim | Only some bones keyed | Use animation composition with Idle |
| Animation too fast/slow | Wrong speed | Adjust `animationSpeed` Input |

### Script Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| "Code too complex to typecheck" | Too many vertices per part | Reduce MAX_FACES_PER_PART |
| "Path was modified between draws" | `path:reset()` in `draw()` | Build paths in `advance()` only |
| Type errors | Untyped data access | Cast through `:: any` then to `:: { number }` |

### Export Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| No output files | Script error | Check Blender console for errors |
| Missing animations | Actions not linked | Ensure actions are in Action Editor |
| Wrong vertex count | Modifiers not applied | Apply modifiers before export |
| File still large | Old table-of-tables format | Run `convert_flat.py` |

---

## Advanced Topics

### Using Blender MCP for Modifications

With Blender MCP, you can also:
- Modify materials and re-export
- Adjust animations directly
- Create new animation clips
- Extract texture colors from screenshots

### Multiple Models

You can have multiple 3D models in the same Rive file:
1. Export each model separately with different `MODEL_NAME`
2. Create separate Node Scripts for each
3. They share the same utility scripts (`Mesh3DUtil.luau`, `SkeletalAnimUtil.luau`)

### Animation Blending

For smooth transitions between animations:
```luau
-- In advance(), blend between two clips
local blendFactor = 0.5  -- 0 = clipA, 1 = clipB
SkelAnim.blendAnimations(skeleton, clipA, clipB, timeA, timeB, blendFactor)
```

### Performance Optimization

For better performance:
- Reduce polygon count in Blender (decimate modifier)
- Use flat arrays (`convert_flat.py`) for ~33% smaller data files
- Use `table.create(n, 0)` for pre-allocated flat arrays in skinning
- Use orthographic projection (`usePerspective = false`)
- Keep `brightness` calculation simple

---

## Critical Rules Summary

1. **Coordinate Space Consistency**: ALL data (vertices, IBMs, rest pose, animations) must use the SAME normalized space ("posed rest")
2. **Scale = 1**: Always force scale to 1 on bone matrices
3. **Quaternion Format**: Blender exports WXYZ, SkeletalAnimUtil converts to XYZW automatically
4. **Animation Format**: Store FINAL local transforms, not deltas
5. **Flat Arrays**: Vertices stride 3, faces stride 4 for optimal file size
6. **Rive Restrictions**: Type annotations on `table.sort`, no `path:reset()` in `draw()`

---

## License

MIT License - Feel free to use in personal and commercial projects.

---

## Credits

- Pipeline developed by Fred Berria & Claude
- Inspired by Luigi Rosso's approach (Rive coFounder)
- LERP documentation: https://forge.mograph.life/apps/lerp/
