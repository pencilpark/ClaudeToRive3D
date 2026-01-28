# Mesh Utilities

This directory contains utility scripts for working with mesh data when importing from Blender to Rive.

## Files

### blender_export.py

Blender script to export mesh data from the active object.

**Usage in Blender:**
```python
import sys
sys.path.append('/path/to/mesh_utils')

from blender_export import export_to_json
export_to_json('/path/to/output.json')
```

**Functions:**
- `get_active_mesh_data()` - Extract vertices and faces from active mesh
- `export_to_json(filepath)` - Export mesh to JSON file

### mesh_converter.py

Standalone converter for transforming mesh data formats.

**Usage:**
```python
from mesh_converter import (
    blender_to_rive_coordinates,
    flatten_vertices,
    flatten_faces,
    optimize_mesh
)

# Load mesh data
mesh_data = load_mesh_json('input.json')

# Convert coordinates
rive_vertices = blender_to_rive_coordinates(mesh_data['vertices'])

# Optimize mesh
optimized_verts, optimized_faces = optimize_mesh(
    rive_vertices, 
    mesh_data['faces']
)

# Flatten for Rive
vertex_array = flatten_vertices(optimized_verts)
index_array = flatten_faces(optimized_faces)
```

## Features

- **Coordinate System Conversion**: Convert between Blender and Rive coordinate systems
- **Mesh Optimization**: Remove duplicate vertices
- **Format Conversion**: Convert to flattened arrays for Rive runtime
- **Triangulation**: Automatically convert quads to triangles
