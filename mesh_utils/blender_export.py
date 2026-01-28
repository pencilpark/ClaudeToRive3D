"""
Blender Mesh Export Utility
Export mesh data from Blender in a format ready for Rive import
"""

import bpy
import json


def get_active_mesh_data():
    """
    Extract mesh data from the active Blender object
    
    Returns:
        dict: Mesh data containing vertices and faces
    """
    obj = bpy.context.active_object
    
    if obj is None or obj.type != 'MESH':
        raise ValueError("No active mesh object selected")
    
    mesh = obj.data
    
    # Extract vertices
    vertices = []
    for v in mesh.vertices:
        vertices.append({
            'index': v.index,
            'x': v.co.x,
            'y': v.co.y,
            'z': v.co.z
        })
    
    # Extract faces (convert to triangles if needed)
    faces = []
    for f in mesh.polygons:
        if len(f.vertices) == 3:
            # Already a triangle
            faces.append({
                'indices': list(f.vertices),
                'normal': list(f.normal)
            })
        elif len(f.vertices) == 4:
            # Convert quad to two triangles
            v = list(f.vertices)
            faces.append({
                'indices': [v[0], v[1], v[2]],
                'normal': list(f.normal)
            })
            faces.append({
                'indices': [v[0], v[2], v[3]],
                'normal': list(f.normal)
            })
    
    return {
        'vertices': vertices,
        'faces': faces,
        'vertex_count': len(vertices),
        'face_count': len(faces)
    }


def export_to_json(filepath):
    """
    Export active mesh to JSON file
    
    Args:
        filepath (str): Output file path
    """
    mesh_data = get_active_mesh_data()
    
    with open(filepath, 'w') as f:
        json.dump(mesh_data, f, indent=2)
    
    print(f"Exported mesh to {filepath}")


if __name__ == "__main__":
    # Example usage
    export_to_json("/tmp/mesh_export.json")
