# Examples

This directory contains example mesh data and conversion scripts demonstrating the Blender to Rive import workflow.

## Files

### simple_cube.json

A basic cube mesh exported from Blender. This is the simplest example showing:
- 8 vertices (cube corners)
- 12 triangular faces (2 per cube face)
- Face normals

**Use this example to:**
- Understand the mesh data format
- Test your conversion pipeline
- Learn the basic workflow

### cube_conversion.py

A complete Python script demonstrating how to:
1. Load mesh data from JSON
2. Convert coordinate systems
3. Optimize the mesh
4. Generate Rive runtime code

**Running the example:**
```bash
cd examples
python cube_conversion.py
```

**Expected output:**
- Original and optimized mesh statistics
- Flattened vertex and index arrays
- Sample Rive runtime code

## Workflow Demonstration

This example shows the complete pipeline:

```
Blender Export → JSON File → mesh_utils → Rive Runtime
```

1. **Export from Blender**: Use `mesh_utils/blender_export.py`
2. **Convert format**: Use `mesh_utils/mesh_converter.py`
3. **Import to Rive**: Use generated code in your Rive project

## Creating Your Own Examples

To add more examples:

1. Export your mesh from Blender using `blender_export.py`
2. Save the JSON file in this directory
3. Create a conversion script based on `cube_conversion.py`
4. Document any special requirements or features

## Advanced Examples (Future)

Planned examples:
- Textured mesh with UV coordinates
- Animated mesh sequence
- Complex multi-mesh scene
- LOD (Level of Detail) mesh sets
