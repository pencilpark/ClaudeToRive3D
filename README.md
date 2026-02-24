# Blender to Rive 3D Animation Pipeline

Import rigged 3D models with skeletal animations from Blender into Rive using Luau scripts.

![Pipeline Overview](https://img.shields.io/badge/Blender-Rive-blue)
![Blender MCP](https://img.shields.io/badge/MCP-Blender-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## VIDEO TUTORIAL
https://x.com/fredberria/status/2016568637310513207?s=20

---

## Overview

This pipeline allows you to:
- Export rigged 3D models from Blender with skeletal animations
- Render them in real-time in Rive using Luau scripts
- Control animations via Rive Inputs (play, pause, switch animations)
- Customize colors and rendering parameters

**Key Features:**
- Automatic mesh normalization (~200 units)
- Automatic fragmentation for large meshes (~2950 faces per part)
- Multiple animation support with runtime switching
- Full skeletal animation with vertex skinning
- Customizable material colors via Property Group
- Optimized flat array format (~60% file size reduction)
- Factorized skinning (patterns + index, ~40% smaller)
- Blender MCP integration for AI-assisted conversion

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

# 2. Optimize data files
python3 convert_flat.py           # Flat arrays (~60% smaller)
python3 convert_shared_times.py   # Shared time arrays (~10% smaller)

# 3. Copy generated files to your Rive project

# 4. Create your main Node Script based on the example template

# 5. In Rive: Set animationName Input to play animations
```

---

## Requirements

### For Blender MCP Method
- **Claude Code** with Blender MCP installed
- **Blender 3.0+** running with MCP connection
- Model with mesh (Armature, vertex weights, and Actions are optional for static models)

### For Standalone Script Method
- **Blender 3.0+** (tested on 4.x)
- **Python 3** (for `convert_flat.py` and `convert_shared_times.py` post-processing)
- Model must have:
  - Armature (skeleton) — optional for static models
  - Vertex weights painted (if rigged)
  - Actions (animations) — optional, static models work without

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
2. Extract geometry, skeleton, skinning weights, and animations
3. Generate ready-to-use `.luau` files with flat array format

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
MAX_FACES_PER_PART = 2950     # Auto-fragment threshold (flat arrays)
```

#### Step 4: Run the Export

1. Go to **Scripting** workspace in Blender
2. Click **Open** and select `blender_to_rive.py`
3. **Select your Armature** (or Mesh)
4. Press **Alt+P** to run

#### Step 5: Optimize Data Files

```bash
python3 convert_flat.py           # Vertices/faces -> flat arrays (~60% smaller)
python3 convert_shared_times.py   # Factorize duplicate times in animations (~10% smaller)
```

#### Step 6: Copy to Rive

Copy these files to your Rive project:
- `YourModelPartAData.luau`, `YourModelPartBData.luau`, etc.
- `Mesh3DUtil.luau`
- `SkeletalAnimUtil.luau`

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

Common issues and quick fixes:

| Problem | Solution |
|---------|----------|
| Model explodes during animation | Apply transforms in Blender (Ctrl+A), re-export |
| Animation doesn't play | Check console for available animation names |
| Arms stuck in T-pose | Never reset `matrix_basis` before sampling |
| Z-fighting (flickering) | Use anti-flickering: depthBias + Z_EPSILON sort |
| "Code too complex to typecheck" | Reduce `MAX_FACES_PER_PART` |
| Runtime error on `table.create()` | Use `{}` instead (Rive Luau, not Roblox) |
| File too large | Run `convert_flat.py` for flat array format |

For a comprehensive troubleshooting table and technical details, see [CLAUDE.md](CLAUDE.md).

---

## Advanced Topics

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

For full technical documentation (data format, export process, coordinate systems, anti-flickering, performance optimization, etc.), see [CLAUDE.md](CLAUDE.md).

---

## License

MIT License - Feel free to use in personal and commercial projects.

---

## Credits

- Pipeline developed by Fred Berria & Claude
- Inspired by Luigi Rosso's approach (Rive coFounder)
- LERP documentation: https://forge.mograph.life/apps/lerp/
