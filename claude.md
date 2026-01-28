# Using Claude to Import Blender Meshes into Rive

## Overview

This guide explains how to use Claude AI to help with importing Blender mesh data (vertices and faces) into Rive. Claude can assist with converting Blender's mesh format into the appropriate format for Rive's runtime.

## Workflow

### 1. Export Mesh Data from Blender

In Blender, you can export mesh data using Python scripts:

```python
import bpy

# Get the active mesh object
obj = bpy.context.active_object

# Get mesh data
mesh = obj.data

# Access vertices
vertices = [(v.co.x, v.co.y, v.co.z) for v in mesh.vertices]

# Access faces (triangulated)
faces = [(f.vertices[0], f.vertices[1], f.vertices[2]) for f in mesh.polygons]
```

### 2. Use Claude to Transform Data

Claude can help with:
- Converting coordinate systems (Blender to Rive)
- Optimizing mesh data
- Generating Rive-compatible format
- Validating mesh integrity

### 3. Import into Rive

Use the generated code or data to create vertices and faces in Rive runtime.

## Prompts for Claude

See the `prompts/` directory for pre-made prompts that help Claude understand your mesh import needs.

## Mesh Utilities

The `mesh_utils/` directory contains helper scripts and utilities for:
- Mesh validation
- Format conversion
- Optimization
- Coordinate transformations

## Examples

Check the `examples/` directory for complete workflows demonstrating:
- Simple cube import
- Complex mesh with UV mapping
- Animated mesh sequences
