"""
Mesh Format Converter
Convert between different mesh data formats for Rive compatibility
"""

import json


def blender_to_rive_coordinates(vertices):
    """
    Convert Blender coordinate system to Rive coordinate system
    Blender uses Z-up, right-handed. Adjust based on Rive's requirements.
    
    Args:
        vertices (list): List of vertex dictionaries with x, y, z coordinates
        
    Returns:
        list: Converted vertices
    """
    converted = []
    for v in vertices:
        # Example conversion - adjust based on actual Rive requirements
        converted.append({
            'x': v['x'],
            'y': v['z'],  # Swap Y and Z for Z-up to Y-up
            'z': -v['y']
        })
    return converted


def flatten_vertices(vertices):
    """
    Flatten vertex data to a simple array format
    
    Args:
        vertices (list): List of vertex dictionaries
        
    Returns:
        list: Flattened [x1, y1, z1, x2, y2, z2, ...] array
    """
    flattened = []
    for v in vertices:
        flattened.extend([v['x'], v['y'], v['z']])
    return flattened


def flatten_faces(faces):
    """
    Flatten face indices to a simple array format
    
    Args:
        faces (list): List of face dictionaries with indices
        
    Returns:
        list: Flattened [i1, i2, i3, i4, i5, i6, ...] array
    """
    flattened = []
    for f in faces:
        flattened.extend(f['indices'])
    return flattened


def optimize_mesh(vertices, faces, tolerance=0.0001):
    """
    Remove duplicate vertices and update face indices
    
    Args:
        vertices (list): List of vertices
        faces (list): List of faces
        tolerance (float): Distance threshold for duplicate detection
        
    Returns:
        tuple: (optimized_vertices, optimized_faces)
    """
    # Simple implementation - can be enhanced with spatial hashing
    unique_vertices = []
    vertex_map = {}
    
    for i, v in enumerate(vertices):
        is_duplicate = False
        for j, uv in enumerate(unique_vertices):
            dx = v['x'] - uv['x']
            dy = v['y'] - uv['y']
            dz = v['z'] - uv['z']
            dist_sq = dx*dx + dy*dy + dz*dz
            
            if dist_sq < tolerance * tolerance:
                vertex_map[i] = j
                is_duplicate = True
                break
        
        if not is_duplicate:
            vertex_map[i] = len(unique_vertices)
            unique_vertices.append(v)
    
    # Update face indices
    optimized_faces = []
    for f in faces:
        new_indices = [vertex_map[idx] for idx in f['indices']]
        optimized_faces.append({
            'indices': new_indices,
            'normal': f.get('normal', [0, 0, 1])
        })
    
    return unique_vertices, optimized_faces


def load_mesh_json(filepath):
    """
    Load mesh data from JSON file
    
    Args:
        filepath (str): Input file path
        
    Returns:
        dict: Mesh data
    """
    with open(filepath, 'r') as f:
        return json.load(f)


def save_mesh_json(mesh_data, filepath):
    """
    Save mesh data to JSON file
    
    Args:
        mesh_data (dict): Mesh data
        filepath (str): Output file path
    """
    with open(filepath, 'w') as f:
        json.dump(mesh_data, f, indent=2)
