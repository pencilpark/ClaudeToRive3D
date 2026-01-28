# ClaudeToRive3D

A complete toolkit for importing Blender mesh data (vertices and faces) into Rive, with AI assistance from Claude.

## Overview

This repository provides everything you need to export 3D meshes from Blender and import them into Rive runtime:

- **📄 Documentation** - Guide for using Claude AI to assist with imports
- **🛠️ Mesh Utilities** - Python scripts for mesh export and conversion
- **💬 Prompt Templates** - Pre-made prompts for Claude to help with different scenarios
- **📚 Examples** - Working examples demonstrating the complete workflow

## Quick Start

### 1. Export from Blender

Use the Blender export utility:

```python
# In Blender's Python console
import sys
sys.path.append('/path/to/ClaudeToRive3D/mesh_utils')

from blender_export import export_to_json
export_to_json('/path/to/output.json')
```

### 2. Convert for Rive

Use the mesh converter:

```python
from mesh_utils.mesh_converter import *

# Load exported mesh
mesh_data = load_mesh_json('output.json')

# Convert coordinates
rive_vertices = blender_to_rive_coordinates(mesh_data['vertices'])

# Optimize
optimized_verts, optimized_faces = optimize_mesh(rive_vertices, mesh_data['faces'])

# Flatten for Rive
vertex_array = flatten_vertices(optimized_verts)
index_array = flatten_faces(optimized_faces)
```

### 3. Use Claude for Assistance

See the `prompts/` directory for templates to help Claude understand your mesh import needs.

## Repository Structure

```
ClaudeToRive3D/
├── claude.md              # Guide for using Claude AI
├── mesh_utils/            # Utility scripts
│   ├── blender_export.py  # Export from Blender
│   ├── mesh_converter.py  # Format conversion
│   └── README.md          # Utilities documentation
├── prompts/               # Claude prompt templates
│   ├── basic_import.md    # Simple mesh import
│   ├── uv_mapping.md      # Textured meshes
│   ├── animation.md       # Animated sequences
│   └── README.md          # Prompts documentation
├── examples/              # Example files and workflows
│   ├── simple_cube.json   # Sample mesh data
│   ├── cube_conversion.py # Conversion example
│   └── README.md          # Examples documentation
└── README.md              # This file
```

## Features

### Mesh Utilities

- **Export from Blender** - Extract vertices, faces, and normals
- **Coordinate Conversion** - Convert between Blender and Rive coordinate systems
- **Mesh Optimization** - Remove duplicate vertices
- **Format Conversion** - Generate flattened arrays for Rive runtime
- **Auto-triangulation** - Convert quads to triangles automatically

### Claude Integration

- **Prompt Templates** - Ready-to-use prompts for different scenarios
- **AI-Assisted Conversion** - Let Claude help with complex transformations
- **Code Generation** - Generate Rive runtime code with Claude's help

## Use Cases

### Static Meshes
Import simple 3D geometry for use in Rive projects
- UI elements with 3D depth
- Background geometry
- Static decorations

### Textured Meshes
Import meshes with UV coordinates for texture mapping:
- Textured 3D objects
- Image-mapped surfaces

### Animated Meshes
Import vertex animation sequences
- Morph targets
- Vertex animations
- Frame-by-frame sequences

## Documentation

- **[claude.md](claude.md)** - Complete guide for using Claude AI
- **[mesh_utils/README.md](mesh_utils/README.md)** - Utilities documentation
- **[prompts/README.md](prompts/README.md)** - Prompt templates guide
- **[examples/README.md](examples/README.md)** - Example workflows

## Example Workflow

See a complete working example:

```bash
cd examples
python cube_conversion.py
```

This demonstrates:
1. Loading mesh data
2. Converting coordinate systems
3. Optimizing the mesh
4. Generating Rive runtime code

## Requirements

- **Blender** (for mesh export)
- **Python 3.6+** (for utilities)
- **Rive Runtime** (for import)

## Contributing

Contributions welcome! Feel free to:
- Add more example meshes
- Improve conversion utilities
- Create additional prompt templates
- Enhance documentation

## License

See LICENSE file for details.

## Support

For questions or issues, please open an issue on GitHub.
