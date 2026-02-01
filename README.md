# Blender to Rive 3D Animation Pipeline

Import rigged 3D models with skeletal animations from Blender into Rive using Luau scripts.

![Pipeline Overview](https://img.shields.io/badge/Blender-Rive-blue)
![Blender MCP](https://img.shields.io/badge/MCP-Blender-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Requirements](#requirements)
4. [Tutorial: Step by Step](#tutorial-step-by-step)
   - [Method 1: Using Blender MCP (Recommended)](#method-1-using-blender-mcp-recommended)
   - [Method 2: Using Standalone Script](#method-2-using-standalone-script)
5. [File Structure](#file-structure)
6. [Configuration Reference](#configuration-reference)
7. [Property Group Reference](#property-group-reference)
8. [Troubleshooting](#troubleshooting)
9. [Advanced Topics](#advanced-topics)

---

## Overview

This pipeline allows you to:
- Export rigged 3D models from Blender with skeletal animations
- Render them in real-time in Rive using Luau scripts
- Control animations via Rive Inputs (play, pause, switch animations)
- Customize colors and rendering parameters

**Key Features:**
- Automatic mesh normalization (~200 units)
- Automatic fragmentation for large meshes (>350 faces)
- Multiple animation support with runtime switching
- Full skeletal animation with vertex skinning
- Customizable material colors via Property Group
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

# 2. Copy generated files to your Rive project

# 3. Create your main Node Script based on the example template

# 4. In Rive: Set animationName Input to play animations
```

---

## Requirements

### For Blender MCP Method
- **Claude Code** with Blender MCP installed
- **Blender 3.0+** running with MCP connection
- Model with Armature, vertex weights, and Actions

### For Standalone Script Method
- **Blender 3.0+** (tested on 4.x)
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
6. Generate ready-to-use `.luau` files

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
2. Press Ctrl+A → Apply All Transforms
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
MAX_FACES_PER_PART = 350       # Auto-fragment threshold
MAX_VERTS_PER_PART = 500       # Auto-fragment threshold
```

#### Step 4: Run the Export

1. Go to **Scripting** workspace in Blender
2. Click **Open** and select `blender_to_rive.py`
3. **Select your Armature** (or Mesh)
4. Press **Alt+P** to run

#### Step 5: Copy to Rive

The script generates:
```
YourModel.blend (same folder)
├── YourModelPartAData.luau
├── YourModelPartBData.luau (if fragmented)
└── ...
```

Copy these files to your Rive project along with:
- `Mesh3DUtil.luau`
- `SkeletalAnimUtil.luau`

---

## File Structure

```
project/
├── blender_to_rive.py        # Standalone Blender export script
├── prompt.md                 # AI prompt for Blender MCP workflow
├── Mesh3DUtil.luau           # 3D math (matrices, quaternions, projection)
├── SkeletalAnimUtil.luau     # Skeleton building, animation, skinning
├── Example.luau              # Example: Main Node Script
├── ExamplePartAData.luau     # Example: Generated data (part A)
├── ExamplePartBData.luau     # Example: Generated data (part B)
├── CLAUDE.md                 # Full technical documentation
└── README.md                 # This file
```

---

## Configuration Reference

### blender_to_rive.py Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `MODEL_NAME` | "Model" | Output file prefix |
| `TARGET_SIZE` | 200.0 | Normalize mesh to this size |
| `OUTPUT_DIR` | "//" | Output directory (// = relative to .blend) |
| `MAX_FACES_PER_PART` | 350 | Fragment threshold for faces |
| `MAX_VERTS_PER_PART` | 500 | Fragment threshold for vertices |

### Generated Data Structure

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

ModelData.skinning = {
    { j = {0,1,2,0}, w = {0.8,0.1,0.1,0} },  -- per vertex
    ...
}

ModelData.vertices = {
    { x = 0, y = 0, z = 0 },
    ...
}

ModelData.faces = {
    { verts = {1,2,3}, c = 1 },  -- c = material category
    ...
}

ModelData.animations = {
    ["Armature|Swim"] = {
        name = "Armature|Swim",
        duration = 4.21,
        channels = { ... }
    },
}
```

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
| `brightness` | Number | 30 | Brightness (0-100, divided by 100) |
| `faceExpansion` | Number | 0.005 | Expand faces to eliminate gaps |
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
| Model twisted when animated | Coordinate space mismatch | Re-export with `blender_to_rive.py` |
| Model explodes during animation | Armature scale ≠ 1 | Apply transforms in Blender (Ctrl+A) |
| Animation amplified/stretched | Scale baked into bones | Force scale=1 in export (automatic) |
| Some faces missing | Wrong winding order | Check normals in Blender |
| Z-fighting (flickering) | Faces at same depth | Increase `faceExpansion` |

### Animation Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Animation doesn't play | Wrong animation name | Check console for available names |
| Animation plays wrong | Multiple actions exported | Set correct `animationName` |
| Jerky animation | Missing keyframes | Add more keyframes in Blender |
| Animation too fast/slow | Wrong speed | Adjust `animationSpeed` Input |

### Script Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| "Code too complex to typecheck" | Too many vertices per part | Reduce `MAX_VERTS_PER_PART` |
| "Path was modified between draws" | `path:reset()` in `draw()` | Build paths in `advance()` only |
| Type errors | Untyped data access | Cast through `:: any` then to type |
| table.sort error | Inline comparator | Use manual bubble sort |

### Export Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| No output files | Script error | Check Blender console for errors |
| Missing animations | Actions not linked | Ensure actions are in Action Editor |
| Wrong vertex count | Modifiers not applied | Apply modifiers before export |

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
3. They share the same utility scripts

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
- Use orthographic projection (`usePerspective = false`)
- Disable `backfaceCulling` only if needed
- Keep `brightness` calculation simple

---

## Critical Rules Summary

1. **Coordinate Space Consistency**: ALL data (vertices, IBMs, rest pose, animations) must use the SAME normalized space
2. **Scale = 1**: Always force scale to 1 on bone matrices
3. **Quaternion Format**: Blender exports WXYZ, SkeletalAnimUtil converts to XYZW automatically
4. **Animation Format**: Store FINAL local transforms, not deltas
5. **Rive Restrictions**: No `table.sort` comparators, no `path:reset()` in `draw()`

---

## License

MIT License - Feel free to use in personal and commercial projects.

---

## Credits

- Pipeline developed by Fred Berria & Claude
- Built for the Rive Ambassador program
- LERP documentation: https://forge.mograph.life/apps/lerp/
