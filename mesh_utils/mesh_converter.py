"""
Mesh Format Converter
Convert between different mesh data formats for Rive compatibility
"""

import json


def blender_to_rive_coordinates(vertices):
    """
    Convert Blender coordinate system to Rive coordinate system
    Blender uses Z-up, right-handed coordinate system.
    
    IMPORTANT: This performs a basic Z-up to Y-up conversion. You MUST verify
    this matches Rive's actual coordinate system requirements and adjust accordingly.
    Common conversions:
    - Z-up to Y-up: x'=x, y'=z, z'=-y (current implementation)
    - Identity: x'=x, y'=y, z'=z (no conversion needed)
    - Other custom transforms as needed
    
    Args:
        vertices (list): List of vertex dictionaries with x, y, z coordinates
        
    Returns:
        list: Converted vertices
    """
    converted = []
    for v in vertices:
        # Z-up to Y-up conversion - VERIFY this matches Rive's requirements
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
    
    NOTE: This uses a naive O(n²) algorithm. For large meshes (>1000 vertices),
    this may be slow. Consider implementing spatial hashing for better performance
    with large meshes.
    
    Args:
        vertices (list): List of vertices
        faces (list): List of faces
        tolerance (float): Distance threshold for duplicate detection
        
    Returns:
        tuple: (optimized_vertices, optimized_faces)
    """
    # Simple implementation - can be enhanced with spatial hashing for large meshes
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
        
    Raises:
        FileNotFoundError: If the file doesn't exist
        json.JSONDecodeError: If the file is not valid JSON
    """
    try:
        with open(filepath, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        raise FileNotFoundError(f"Mesh file not found: {filepath}")
    except json.JSONDecodeError as e:
        raise json.JSONDecodeError(
            f"Invalid JSON in mesh file {filepath}: {e.msg}",
            e.doc,
            e.pos
        )


def save_mesh_json(mesh_data, filepath):
    """
    Save mesh data to JSON file
    
    Args:
        mesh_data (dict): Mesh data
        filepath (str): Output file path
        
    Raises:
        PermissionError: If the file cannot be written
        IOError: If there's an error writing the file
    """
    try:
        with open(filepath, 'w') as f:
            json.dump(mesh_data, f, indent=2)
    except PermissionError:
        raise PermissionError(f"Permission denied writing to: {filepath}")
    except IOError as e:
        raise IOError(f"Error writing mesh file {filepath}: {e}")
