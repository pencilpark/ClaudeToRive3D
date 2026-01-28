"""
Example: Converting and Importing a Simple Cube from Blender to Rive

This example demonstrates the complete workflow of exporting a cube from Blender
and preparing it for import into Rive.
"""

import sys
import os

# Add mesh_utils to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'mesh_utils'))

from mesh_converter import (
    load_mesh_json,
    blender_to_rive_coordinates,
    flatten_vertices,
    flatten_faces,
    optimize_mesh
)


def convert_cube_example():
    """
    Load the simple cube and convert it for Rive
    """
    # Load the cube mesh data
    cube_path = os.path.join(os.path.dirname(__file__), 'simple_cube.json')
    mesh_data = load_mesh_json(cube_path)
    
    print("Original mesh:")
    print(f"  Vertices: {mesh_data['vertex_count']}")
    print(f"  Faces: {mesh_data['face_count']}")
    
    # Convert coordinate system
    print("\nConverting coordinate system...")
    rive_vertices = blender_to_rive_coordinates(mesh_data['vertices'])
    
    # Optimize mesh (remove duplicates)
    print("Optimizing mesh...")
    optimized_verts, optimized_faces = optimize_mesh(
        rive_vertices,
        mesh_data['faces']
    )
    
    print(f"  Optimized vertices: {len(optimized_verts)}")
    print(f"  Optimized faces: {len(optimized_faces)}")
    
    # Flatten for Rive runtime
    print("\nFlattening data for Rive...")
    vertex_array = flatten_vertices(optimized_verts)
    index_array = flatten_faces(optimized_faces)
    
    print(f"  Vertex array length: {len(vertex_array)} ({len(vertex_array)//3} vertices)")
    print(f"  Index array length: {len(index_array)} ({len(index_array)//3} triangles)")
    
    # Print sample Rive code
    print("\n" + "="*60)
    print("SAMPLE RIVE RUNTIME CODE (JavaScript/TypeScript):")
    print("="*60)
    print(f"""
// Vertex data (x, y, z positions)
const vertices = [{', '.join(map(str, vertex_array[:30]))}...];

// Index data (triangle indices)
const indices = [{', '.join(map(str, index_array[:30]))}...];

// Create mesh in Rive runtime
// NOTE: Replace with actual Rive API - this is a placeholder example
const mesh = rive.createMesh({{
    vertices: vertices,
    indices: indices,
    vertexCount: {len(optimized_verts)},
    triangleCount: {len(optimized_faces)}
}});

// Consult Rive documentation for the correct API methods
""")
    
    return {
        'vertices': vertex_array,
        'indices': index_array,
        'vertex_count': len(optimized_verts),
        'triangle_count': len(optimized_faces)
    }


if __name__ == "__main__":
    result = convert_cube_example()
    print("\nConversion complete!")
