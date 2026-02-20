"""
Blender to Rive — Universal 3D Export (v6.0)
=============================================

Exports ANY Blender model (single or multi-mesh, any skeleton) to Rive Luau scripts.
Handles bone-parented rigid meshes AND armature-modifier multi-bone skinning.
Outputs FLAT ARRAYS (stride 3 vertices, stride 4 faces) + sharedTimes factorization.

PROVEN PROCESS (FinnTheFrog: 1 mesh, 13 bones, 17 animations, 5846 faces,
                PIO Robot: 15 meshes, 43 bones, 14 animations, 5664 faces):
  1. Detect matrix_basis residuals -> determines "posed rest"
  2. Compute normalization in POSED REST position (evaluated mesh, all meshes combined)
  3. Export skeleton IBMs from POSED REST (pose_bone.matrix, NOT bone.matrix_local)
  4. Export vertices in POSED REST (evaluated mesh with armature)
  5. Detect color zones: multiple materials OR Atlas texture UV sampling (QUANT_STEP=0.005)
  6. Export faces with triangulation + color categories + Z-sorting
  7. Factorize skinning (patterns + index per part, supports multi-bone weights)
  8. Sample animations as ABSOLUTE local transforms (never reset matrix_basis)
  9. Optimize: remove static channels matching rest pose, keep constant-but-different
  10. Verify: skin matrices = Identity at posed rest
  11. Fragment into Part files (~2950 faces each) + separate Anim files with sharedTimes

CRITICAL: Steps 2-10 run in sequence — same Python execution ensures same depsgraph.
When using Blender MCP, all steps MUST be in ONE single execute_blender_code call.

Data format:
  - Vertices: flat arrays (stride 3: x, y, z)
  - Faces: flat arrays (stride 4: v1, v2, v3, category)
  - Quaternions: WXYZ in files (Blender native)
  - Joint indices: 1-based in files (Luau arrays)
  - Skinning patterns: 0-based bone indices (runtime adds +1)
  - Animation times: sharedTimes + timeRef (factorized)
  - All data in SAME normalized coordinate space (~200 units max dimension)

Usage:
  1. Open .blend file with rigged model
  2. Configure SETTINGS below (MODEL_NAME, mesh exclusions, etc.)
  3. Run script (Alt+P in Text Editor)
  4. Copy .luau files to Rive project

Can also be executed step-by-step via Blender MCP (preferred for debugging).

Author: Claude + Fred Berria
Version: 6.0.0 (Flat Arrays + sharedTimes + Atlas UV + Universal)
"""

import bpy
import bmesh
from mathutils import Matrix, Vector, Quaternion
import os
import math

# ============================================================================
# SETTINGS — EDIT THESE
# ============================================================================

MODEL_NAME = "Model"              # Prefix for output files (e.g., "FinnTheFrog", "PioRobot")
TARGET_SIZE = 200.0               # Normalize to ~200 units max dimension
MAX_FACES_PER_PART = 2950         # ~2950 with flat arrays (~1900 with table-of-tables)
FPS = 30.0                        # Animation sampling rate
EPSILON = 0.0001                  # Threshold for static channel optimization
QUANT_STEP = 0.005                # Color quantization step for Atlas UV sampling (0.005 preserves distinct zones)
OUTPUT_DIR = os.path.dirname(bpy.data.filepath) if bpy.data.filepath else "/tmp"

# Meshes to EXCLUDE from export (e.g., helper objects, lights)
EXCLUDE_MESHES = set()

# Animation name mapping: Blender action name -> short display name
# Set to None to auto-derive from action names
ANIM_NAME_MAP = None  # or {"RobotArmature|Robot_Idle_RobotArmature": "Idle", ...}

# How to split animations across files (list of lists of short names)
# Set to None for automatic splitting (~4-5 anims per file)
ANIM_FILE_SPLIT = None  # or [["Idle", "Walk", "Run"], ["Dance", "Wave", "Yes", "No"], ...]

# ============================================================================
# RE-EXPORT MODE (for adding/fixing animations when Part files already exist)
# ============================================================================
# When True: uses three-tier hybrid sampling to handle quaternion sign ambiguity
# - Non-keyed bones -> exact file rest values
# - Keyed + good match (dot >= 0.95) -> world-space delta
# - Keyed + mismatch (dot < 0.95) -> matrix_basis delta
# When False: standard export (original behavior, used for first-time exports)
RE_EXPORT_MODE = False
RE_EXPORT_REST_FILE = None  # Path to existing PartA .luau file with skeleton data
MISMATCH_THRESHOLD = 0.95   # Quaternion dot product threshold for mismatch detection


# ============================================================================
# HELPERS
# ============================================================================

def fmt(n, decimals=6):
    """Format number: strip trailing zeros."""
    if isinstance(n, float):
        if abs(n) < 1e-7:
            return "0"
        s = f"{n:.{decimals}f}".rstrip('0').rstrip('.')
        return s
    return str(n)


def mat4_to_colmajor(mat):
    """Blender Matrix -> column-major 16 floats."""
    return [round(mat[row][col], 6) for col in range(4) for row in range(4)]


def quat_wxyz(q):
    """Blender Quaternion -> [w, x, y, z] list."""
    return [round(q.w, 6), round(q.x, 6), round(q.y, 6), round(q.z, 6)]


def vec3_list(v, decimals=4):
    """Vector -> [x, y, z] list."""
    return [round(v.x, decimals), round(v.y, decimals), round(v.z, decimals)]


# ============================================================================
# STEP 0: DISCOVER MODEL
# ============================================================================

def discover_model():
    """Find armature and all associated mesh objects."""
    armature = None
    for obj in bpy.context.scene.objects:
        if obj.type == 'ARMATURE':
            armature = obj
            break

    if not armature:
        raise RuntimeError("No armature found in scene!")

    # Find all mesh objects (children of armature, or with armature modifier)
    mesh_objects = []
    for obj in bpy.context.scene.objects:
        if obj.type != 'MESH':
            continue
        if obj.name in EXCLUDE_MESHES:
            continue

        # Check if related to armature
        is_child = (obj.parent == armature)
        has_mod = any(m.type == 'ARMATURE' and m.object == armature for m in obj.modifiers)

        if is_child or has_mod:
            # Determine skinning type
            if has_mod:
                skin_type = "ARMATURE_MOD"  # Multi-bone via vertex groups
                parent_bone = None
            elif obj.parent_type == 'BONE' and obj.parent_bone:
                skin_type = "BONE_PARENT"   # Rigid, single bone
                parent_bone = obj.parent_bone
            else:
                skin_type = "OBJECT_PARENT"  # Treat as rigid to root
                parent_bone = None

            mesh_objects.append({
                'name': obj.name,
                'object': obj,
                'skin_type': skin_type,
                'parent_bone': parent_bone,
            })

    if not mesh_objects:
        raise RuntimeError(f"No mesh objects found for armature '{armature.name}'!")

    return armature, mesh_objects


# ============================================================================
# STEP 1: DETECT MATRIX_BASIS RESIDUALS
# ============================================================================

def detect_matrix_basis(armature):
    """Check which bones have non-identity matrix_basis (default pose != rest pose)."""
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    residuals = []
    for pb in armature.pose.bones:
        loc, rot, _ = pb.matrix_basis.decompose()
        if loc.length > 0.0001 or abs(rot.w - 1.0) + abs(rot.x) + abs(rot.y) + abs(rot.z) > 0.001:
            residuals.append(pb.name)

    print(f"  matrix_basis residuals: {len(residuals)}/{len(armature.pose.bones)} bones")
    if residuals:
        for name in residuals[:5]:
            print(f"    {name}")
        if len(residuals) > 5:
            print(f"    ... and {len(residuals) - 5} more")
    print(f"  -> Using POSED REST mode (always recommended)")
    return len(residuals) > 0


# ============================================================================
# STEP 2: BUILD BONE ORDER + NORMALIZATION
# ============================================================================

def build_bone_order(armature):
    """DFS traversal to build consistent bone order. Returns list of bone names."""
    bones = armature.data.bones
    children = {}
    roots = []
    for b in bones:
        if b.parent is None:
            roots.append(b.name)
        else:
            children.setdefault(b.parent.name, []).append(b.name)

    order = []
    def dfs(name):
        order.append(name)
        for child in sorted(children.get(name, [])):
            dfs(child)

    for r in sorted(roots):
        dfs(r)

    return order


def compute_normalization(armature, mesh_objects):
    """Compute bounding box and normalization matrix from EVALUATED mesh (POSED REST)."""
    # Ensure posed rest
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    min_c = [float('inf')] * 3
    max_c = [float('-inf')] * 3

    depsgraph = bpy.context.evaluated_depsgraph_get()

    for info in mesh_objects:
        obj = info['object']
        eval_obj = obj.evaluated_get(depsgraph)
        eval_mesh = bpy.data.meshes.new_from_object(eval_obj)

        for v in eval_mesh.vertices:
            wp = obj.matrix_world @ v.co
            for i in range(3):
                min_c[i] = min(min_c[i], wp[i])
                max_c[i] = max(max_c[i], wp[i])

        bpy.data.meshes.remove(eval_mesh)

    center = Vector([(min_c[i] + max_c[i]) / 2 for i in range(3)])
    extent = max(max_c[i] - min_c[i] for i in range(3))
    scale = TARGET_SIZE / extent if extent > 0.0001 else 1.0

    normalize_mat = Matrix.Scale(scale, 4) @ Matrix.Translation(-center)

    print(f"  Center: ({center.x:.4f}, {center.y:.4f}, {center.z:.4f})")
    print(f"  Extent: {extent:.4f}, Scale: {scale:.4f}")

    return normalize_mat, center, scale, depsgraph


# ============================================================================
# STEP 3: EXPORT SKELETON (POSED REST — pose_bone.matrix)
# ============================================================================

def export_skeleton(armature, bone_order, normalize_mat):
    """Export skeleton IBMs and rest pose from POSED REST (pose_bone.matrix)."""
    arm_world = armature.matrix_world

    # Ensure posed rest
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    # Compute normalized world matrices (scale=1)
    bone_norm_mats = {}
    for name in bone_order:
        pb = armature.pose.bones[name]
        bw = arm_world @ pb.matrix
        bn = normalize_mat @ bw
        loc, rot, _ = bn.decompose()
        bone_norm_mats[name] = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

    # Compute IBMs and local transforms
    ibms = []
    rest_pose = []
    parent_indices = []

    for name in bone_order:
        bone = armature.data.bones[name]
        bmat = bone_norm_mats[name]

        # Parent index (1-based, None for root)
        if bone.parent and bone.parent.name in bone_order:
            pidx = bone_order.index(bone.parent.name) + 1
        else:
            pidx = None
        parent_indices.append(pidx)

        # IBM
        ibm = bmat.inverted()
        ibms.append(mat4_to_colmajor(ibm))

        # Local transform
        if bone.parent and bone.parent.name in bone_norm_mats:
            local_mat = bone_norm_mats[bone.parent.name].inverted() @ bmat
        else:
            local_mat = bmat

        loc, rot, _ = local_mat.decompose()
        rest_pose.append({
            'translation': vec3_list(loc),
            'rotation': quat_wxyz(rot),
            'scale': [1, 1, 1],
        })

    return {
        'jointCount': len(bone_order),
        'jointParents': parent_indices,
        'inverseBindMatrices': ibms,
        'restPose': rest_pose,
        'boneNormMats': bone_norm_mats,  # kept for verification
    }


# ============================================================================
# STEP 4: EXPORT VERTICES, FACES, SKINNING (ALL MESHES)
# ============================================================================

def detect_atlas_colors(mesh_obj, tri_mesh):
    """Detect color zones from Atlas texture UV sampling.
    Returns dict: face_index -> category (1-based), and zone info.
    Returns None if no Atlas texture found."""

    obj = mesh_obj
    if not obj.material_slots or not obj.material_slots[0].material:
        return None

    mat = obj.material_slots[0].material
    if not mat.node_tree:
        return None

    # Find texture image
    tex_image = None
    for node in mat.node_tree.nodes:
        if node.type == 'TEX_IMAGE' and node.image:
            tex_image = node.image
            break

    if not tex_image:
        return None

    # Get UV layer
    if not tri_mesh.uv_layers:
        return None
    uv_layer = tri_mesh.uv_layers.active

    # Read all pixels
    img = tex_image
    pixels = list(img.pixels)  # RGBA flat array
    w, h = img.size

    # Sample per-face color
    face_colors = []
    for poly in tri_mesh.polygons:
        r_sum, g_sum, b_sum = 0, 0, 0
        for li in poly.loop_indices:
            uv = uv_layer.data[li].uv
            px = int(uv.x * w) % w
            py = int(uv.y * h) % h
            idx = (py * w + px) * 4
            r_sum += pixels[idx]
            g_sum += pixels[idx + 1]
            b_sum += pixels[idx + 2]
        n = len(poly.loop_indices)
        face_colors.append((r_sum / n, g_sum / n, b_sum / n))

    # Quantize colors
    def quantize(c):
        return tuple(round(round(v / QUANT_STEP) * QUANT_STEP, 4) for v in c)

    quant_colors = [quantize(c) for c in face_colors]

    # Find unique colors and assign categories
    unique_colors = sorted(set(quant_colors))
    color_to_cat = {c: i + 1 for i, c in enumerate(unique_colors)}

    # Name zones by visual appearance
    def name_zone(rgb):
        r, g, b = rgb
        brightness = (r + g + b) / 3
        if brightness > 0.7:
            return "White"
        elif brightness < 0.15:
            return "NearBlack"
        elif g > r * 1.2 and g > b * 1.2:
            return "Green"
        elif r > g * 1.3 and r > b * 1.3:
            if g > 0.3:
                return "Orange"
            return "Red"
        elif abs(r - g) < 0.05 and abs(g - b) < 0.05:
            if brightness > 0.4:
                return "LightGray"
            elif brightness > 0.3:
                return "MediumGray"
            else:
                return "DarkGray"
        return f"Color_{brightness:.2f}"

    zone_info = {}
    for color in unique_colors:
        cat = color_to_cat[color]
        name = name_zone(color)
        count = quant_colors.count(color)
        zone_info[cat] = {'name': name, 'color': color, 'count': count}
        print(f"    Zone {cat}: {name} RGB({color[0]:.3f},{color[1]:.3f},{color[2]:.3f}) -> {count} faces")

    # Build face->category mapping
    face_categories = {i: color_to_cat[quant_colors[i]] for i in range(len(quant_colors))}

    return face_categories, zone_info


def export_all_meshes(armature, mesh_objects, bone_order, normalize_mat, depsgraph):
    """Export vertices, faces, and skinning from all mesh objects combined.
    Uses evaluated mesh from the SAME depsgraph as normalization + skeleton."""
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    # Material sorting: alphabetical -> stable category indices
    all_materials = set()
    for info in mesh_objects:
        obj = info['object']
        for slot in obj.material_slots:
            if slot.material:
                all_materials.add(slot.material.name)
    sorted_materials = sorted(all_materials)
    material_map = {name: i + 1 for i, name in enumerate(sorted_materials)}
    print(f"  Materials: {material_map}")

    all_vertices = []   # List of (x, y, z) tuples
    all_faces = []      # List of (v1, v2, v3, category) tuples
    all_skinning = []   # List of {'j': [...], 'w': [...]}
    vertex_offset = 0
    all_zone_info = {}

    for info in mesh_objects:
        obj = info['object']
        skin_type = info['skin_type']
        parent_bone = info['parent_bone']

        # Get evaluated mesh and triangulate
        eval_obj = obj.evaluated_get(depsgraph)
        eval_mesh = bpy.data.meshes.new_from_object(eval_obj)

        bm = bmesh.new()
        bm.from_mesh(eval_mesh)
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        tri_mesh = bpy.data.meshes.new("_temp_tri")
        bm.to_mesh(tri_mesh)
        bm.free()

        combined = normalize_mat @ obj.matrix_world

        # Try Atlas UV sampling for color zones (single material + texture)
        atlas_categories = None
        if len(sorted_materials) == 1 or (len(obj.material_slots) == 1):
            result = detect_atlas_colors(obj, tri_mesh)
            if result:
                atlas_categories, zone_info = result
                all_zone_info.update(zone_info)

        # Vertices (flat: just store x, y, z)
        mesh_verts = []
        for v in tri_mesh.vertices:
            wp = combined @ v.co
            mesh_verts.append((round(wp.x, 3), round(wp.y, 3), round(wp.z, 3)))

        # Skinning
        mesh_skin = []
        if skin_type == "ARMATURE_MOD":
            # Multi-bone skinning from vertex groups
            for v in tri_mesh.vertices:
                groups = sorted(v.groups, key=lambda g: g.weight, reverse=True)[:4]
                joints = [0, 0, 0, 0]
                weights = [0.0, 0.0, 0.0, 0.0]
                total_w = 0
                for k, g in enumerate(groups):
                    gname = obj.vertex_groups[g.group].name
                    if gname in bone_order:
                        joints[k] = bone_order.index(gname)  # 0-based
                        weights[k] = round(g.weight, 4)
                        total_w += g.weight
                if total_w > 0:
                    weights = [round(w / total_w, 4) for w in weights]
                mesh_skin.append({'j': joints, 'w': weights})
        else:
            # Single bone (rigid binding)
            if parent_bone and parent_bone in bone_order:
                bidx = bone_order.index(parent_bone)
            else:
                bidx = 0  # fallback to root
            for _ in tri_mesh.vertices:
                mesh_skin.append({'j': [bidx, 0, 0, 0], 'w': [1.0, 0.0, 0.0, 0.0]})

        # Faces (flat: v1, v2, v3, category)
        face_count = 0
        for fi, poly in enumerate(tri_mesh.polygons):
            if atlas_categories is not None:
                category = atlas_categories.get(fi, 1)
            elif poly.material_index < len(obj.material_slots) and obj.material_slots[poly.material_index].material:
                mat_name = obj.material_slots[poly.material_index].material.name
                category = material_map.get(mat_name, 1)
            else:
                category = 1
            verts_1based = [vi + 1 + vertex_offset for vi in poly.vertices]
            all_faces.append((verts_1based[0], verts_1based[1], verts_1based[2], category))
            face_count += 1

        all_vertices.extend(mesh_verts)
        all_skinning.extend(mesh_skin)
        vertex_offset += len(mesh_verts)

        bpy.data.meshes.remove(tri_mesh)
        bpy.data.meshes.remove(eval_mesh)
        print(f"    {obj.name}: {len(mesh_verts)}v/{face_count}f [{skin_type}]")

    print(f"  Total: {len(all_vertices)} vertices, {len(all_faces)} faces")
    if all_zone_info:
        print(f"  Color zones: {len(all_zone_info)}")
    return all_vertices, all_faces, all_skinning, material_map, all_zone_info


# ============================================================================
# STEP 5: SORT + FRAGMENT + FACTORIZE SKINNING
# ============================================================================

def sort_and_fragment(all_vertices, all_faces, all_skinning):
    """Sort faces by avgZ, split into parts, extract per-part vertices, factorize skinning."""

    # Sort by average Z
    def avg_z(face):
        v1, v2, v3, _ = face
        return (all_vertices[v1 - 1][2] + all_vertices[v2 - 1][2] + all_vertices[v3 - 1][2]) / 3

    all_faces.sort(key=avg_z)

    # Split into chunks
    chunks = [all_faces[i:i + MAX_FACES_PER_PART] for i in range(0, len(all_faces), MAX_FACES_PER_PART)]

    parts = []
    for chunk in chunks:
        # Extract used vertices
        used = set()
        for v1, v2, v3, _ in chunk:
            used.add(v1)
            used.add(v2)
            used.add(v3)

        used_sorted = sorted(used)
        remap = {old: new + 1 for new, old in enumerate(used_sorted)}

        verts = [all_vertices[vi - 1] for vi in used_sorted]
        skin = [all_skinning[vi - 1] for vi in used_sorted]

        faces = [(remap[v1], remap[v2], remap[v3], c) for v1, v2, v3, c in chunk]

        # Factorize skinning
        patterns, indices = factorize_skinning(skin)

        parts.append({
            'vertices': verts,
            'faces': faces,
            'skinningPatterns': patterns,
            'skinningIndex': indices,
        })

    return parts


def factorize_skinning(skin_data):
    """Deduplicate skinning entries into patterns + index array."""
    patterns = {}
    pattern_keys = {}
    indices = []

    for entry in skin_data:
        key = (tuple(entry['j']), tuple(entry['w']))
        if key not in pattern_keys:
            idx = len(patterns)
            patterns[idx] = entry
            pattern_keys[key] = idx
        indices.append(pattern_keys[key])

    return patterns, indices


# ============================================================================
# STEP 5b: RE-EXPORT HELPERS (Quaternion mismatch detection + file parsing)
# ============================================================================

def parse_rest_pose_from_file(filepath):
    """Parse rest pose data from an existing Part .luau file.
    Returns dict: {joint_index(1-based): {translation: [x,y,z], rotation: [w,x,y,z]}}
    """
    import re
    rest_data = {}
    with open(filepath, 'r') as f:
        content = f.read()

    # Find restPose block
    rest_match = re.search(r'restPose\s*=\s*\{(.*?)\n\s*\}', content, re.DOTALL)
    if not rest_match:
        raise RuntimeError(f"Could not find restPose in {filepath}")

    entries = re.findall(
        r'\{translation\s*=\s*\{([^}]+)\},\s*rotation\s*=\s*\{([^}]+)\},\s*scale\s*=\s*\{[^}]+\}\}',
        rest_match.group(1)
    )

    for i, (trans_str, rot_str) in enumerate(entries):
        trans = [float(x.strip()) for x in trans_str.split(',')]
        rot = [float(x.strip()) for x in rot_str.split(',')]
        rest_data[i + 1] = {'translation': trans, 'rotation': rot}

    print(f"  Parsed {len(rest_data)} joints from {os.path.basename(filepath)}")
    return rest_data


def detect_mismatched_bones(armature, bone_order, normalize_mat, file_rest_locals):
    """Compare Blender rest local quaternions vs file rest locals.
    Returns set of joint indices (1-based) where dot product < MISMATCH_THRESHOLD.
    """
    arm_world = armature.matrix_world

    # Ensure posed rest
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    # Compute Blender's current rest locals
    norm_world_mats = {}
    for name in bone_order:
        pb = armature.pose.bones[name]
        bw = arm_world @ pb.matrix
        bn = normalize_mat @ bw
        loc, rot, _ = bn.decompose()
        norm_world_mats[name] = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

    mismatched = set()
    for idx, name in enumerate(bone_order):
        joint_idx = idx + 1
        bone = armature.data.bones[name]

        # Compute Blender rest local
        bmat = norm_world_mats[name]
        if bone.parent and bone.parent.name in bone_order:
            local = norm_world_mats[bone.parent.name].inverted() @ bmat
        else:
            local = bmat
        _, blender_rot, _ = local.decompose()

        # File rest local
        if joint_idx not in file_rest_locals:
            continue
        fr = file_rest_locals[joint_idx]['rotation']
        file_rot = Quaternion((fr[0], fr[1], fr[2], fr[3]))  # WXYZ

        dot = abs(blender_rot.dot(file_rot))
        if dot < MISMATCH_THRESHOLD:
            mismatched.add(joint_idx)
            print(f"    J{joint_idx}({name}): dot={dot:.3f} -> MISMATCHED")

    print(f"  Mismatched bones: {len(mismatched)}/{len(bone_order)}")
    return mismatched


def get_animated_bones(action):
    """Return set of bone names that have actual keyframes in this action."""
    animated = set()
    for fc in action.fcurves:
        if fc.data_path.startswith("pose.bones["):
            parts = fc.data_path.split('"')
            if len(parts) >= 2:
                animated.add(parts[1])
    return animated


# ============================================================================
# STEP 6: EXPORT ANIMATIONS (ABSOLUTE LOCAL TRANSFORMS)
# ============================================================================

def export_animations(armature, bone_order, normalize_mat):
    """Sample all animations as ABSOLUTE local transforms. Never reset matrix_basis.

    When RE_EXPORT_MODE is True, uses three-tier hybrid sampling:
    - Non-keyed bones -> exact file rest values
    - Keyed + good match (dot >= 0.95) -> world-space delta
    - Keyed + mismatch (dot < 0.95) -> matrix_basis delta
    """
    arm_world = armature.matrix_world
    all_animations = {}

    # --- RE-EXPORT: load file rest pose and detect mismatches ---
    file_rest_locals = None
    mismatched_bones = set()
    if RE_EXPORT_MODE:
        if not RE_EXPORT_REST_FILE:
            raise RuntimeError("RE_EXPORT_MODE=True but RE_EXPORT_REST_FILE is not set!")
        print(f"  RE-EXPORT MODE: loading rest pose from {os.path.basename(RE_EXPORT_REST_FILE)}")
        file_rest_locals = parse_rest_pose_from_file(RE_EXPORT_REST_FILE)
        mismatched_bones = detect_mismatched_bones(armature, bone_order, normalize_mat, file_rest_locals)

    # Compute posed-rest locals for static channel optimization
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    posed_rest_locals = {}
    norm_world_mats = {}
    for name in bone_order:
        pb = armature.pose.bones[name]
        bw = arm_world @ pb.matrix
        bn = normalize_mat @ bw
        loc, rot, _ = bn.decompose()
        bmat = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))
        norm_world_mats[name] = bmat

    # Blender rest local matrices (for delta computation in re-export mode)
    blender_rest_local_mats = {}
    for name in bone_order:
        bone = armature.data.bones[name]
        bmat = norm_world_mats[name]
        if bone.parent and bone.parent.name in bone_order:
            local = norm_world_mats[bone.parent.name].inverted() @ bmat
        else:
            local = bmat
        loc, rot, _ = local.decompose()
        blender_rest_local_mats[name] = local
        posed_rest_locals[name] = {
            'translation': [loc.x, loc.y, loc.z],
            'rotation': [rot.w, rot.x, rot.y, rot.z],
        }

    # --- RE-EXPORT: capture rest matrix_basis for mismatched bones ---
    rest_basis_map = {}
    file_rest_local_mats = {}
    if RE_EXPORT_MODE and file_rest_locals:
        for idx, name in enumerate(bone_order):
            joint_idx = idx + 1
            pb = armature.pose.bones[name]
            rest_basis_map[name] = pb.matrix_basis.copy()
            if joint_idx in file_rest_locals:
                fr = file_rest_locals[joint_idx]
                t = Vector(fr['translation'])
                r = Quaternion((fr['rotation'][0], fr['rotation'][1], fr['rotation'][2], fr['rotation'][3]))
                file_rest_local_mats[name] = Matrix.LocRotScale(t, r, Vector((1, 1, 1)))

    # Find actions to export (skip non-armature actions)
    actions = []
    for action in bpy.data.actions:
        if any(fc.data_path.startswith("pose.bones") for fc in action.fcurves):
            actions.append(action)

    print(f"  Found {len(actions)} armature actions")

    for action in actions:
        frame_start = int(action.frame_range[0])
        frame_end = int(action.frame_range[1])
        duration = round((frame_end - frame_start) / FPS, 4)

        # Derive short name
        short_name = action.name
        if ANIM_NAME_MAP and action.name in ANIM_NAME_MAP:
            short_name = ANIM_NAME_MAP[action.name]
        else:
            # Auto-derive: "RobotArmature|Robot_Walking_RobotArmature" -> "Walking"
            name_parts = action.name.split('|')
            if len(name_parts) > 1:
                inner = name_parts[1]
                # Remove prefix/suffix patterns
                for prefix in [armature.name + '_', 'Robot_']:
                    if inner.startswith(prefix):
                        inner = inner[len(prefix):]
                for suffix in ['_' + armature.name, '_RobotArmature']:
                    if inner.endswith(suffix):
                        inner = inner[:-len(suffix)]
                short_name = inner
            elif '_' in short_name:
                short_name = short_name.split('_')[1] if len(short_name.split('_')) > 1 else short_name

        # --- RE-EXPORT: detect animated bones for this action ---
        animated_bone_names = set()
        animated_indices = set()
        if RE_EXPORT_MODE:
            animated_bone_names = get_animated_bones(action)
            animated_indices = {i + 1 for i, b in enumerate(bone_order) if b in animated_bone_names}
            print(f"    {short_name}: {len(animated_indices)} keyed bones")

        # Assign action, DO NOT reset matrix_basis
        armature.animation_data.action = action
        armature.data.pose_position = 'POSE'

        bone_samples = {name: {'translation': [], 'rotation': []} for name in bone_order}
        times = []

        for frame in range(frame_start, frame_end + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            times.append(round((frame - frame_start) / FPS, 4))

            if RE_EXPORT_MODE and file_rest_locals:
                # --- RE-EXPORT: Three-tier hybrid sampling ---
                for bi, name in enumerate(bone_order):
                    joint_idx = bi + 1
                    pb = armature.pose.bones[name]

                    if joint_idx not in animated_indices:
                        # Tier 1: NOT keyed -> exact file rest values
                        fr = file_rest_locals[joint_idx]
                        bone_samples[name]['translation'].append(
                            [round(fr['translation'][0], 4),
                             round(fr['translation'][1], 4),
                             round(fr['translation'][2], 4)]
                        )
                        bone_samples[name]['rotation'].append(
                            [round(fr['rotation'][0], 6),
                             round(fr['rotation'][1], 6),
                             round(fr['rotation'][2], 6),
                             round(fr['rotation'][3], 6)]
                        )
                    elif joint_idx in mismatched_bones:
                        # Tier 3: Keyed + MISMATCHED -> matrix_basis delta
                        rest_basis = rest_basis_map[name]
                        frame_basis = pb.matrix_basis.copy()
                        delta_basis = rest_basis.inverted() @ frame_basis
                        corrected = file_rest_local_mats[name] @ delta_basis
                        loc, rot, _ = corrected.decompose()
                        bone_samples[name]['translation'].append(vec3_list(loc))
                        bone_samples[name]['rotation'].append(quat_wxyz(rot))
                    else:
                        # Tier 2: Keyed + GOOD MATCH -> world-space delta
                        bw = arm_world @ pb.matrix
                        bn = normalize_mat @ bw
                        loc_w, rot_w, _ = bn.decompose()
                        anim_world = Matrix.LocRotScale(loc_w, rot_w, Vector((1, 1, 1)))

                        bone = armature.data.bones[name]
                        if bone.parent and bone.parent.name in bone_order:
                            parent_pb = armature.pose.bones[bone.parent.name]
                            pw = arm_world @ parent_pb.matrix
                            pn = normalize_mat @ pw
                            pl, pr, _ = pn.decompose()
                            parent_mat = Matrix.LocRotScale(pl, pr, Vector((1, 1, 1)))
                            anim_local = parent_mat.inverted() @ anim_world
                        else:
                            anim_local = anim_world

                        delta = blender_rest_local_mats[name].inverted() @ anim_local
                        corrected = file_rest_local_mats[name] @ delta
                        loc, rot, _ = corrected.decompose()
                        bone_samples[name]['translation'].append(vec3_list(loc))
                        bone_samples[name]['rotation'].append(quat_wxyz(rot))
            else:
                # --- STANDARD MODE: Sample absolute local transforms ---
                frame_mats = {}
                for name in bone_order:
                    pb = armature.pose.bones[name]
                    bw = arm_world @ pb.matrix
                    bn = normalize_mat @ bw
                    loc, rot, _ = bn.decompose()
                    frame_mats[name] = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

                for name in bone_order:
                    bone = armature.data.bones[name]
                    bmat = frame_mats[name]
                    if bone.parent and bone.parent.name in bone_order:
                        local = frame_mats[bone.parent.name].inverted() @ bmat
                    else:
                        local = bmat

                    loc, rot, _ = local.decompose()
                    bone_samples[name]['translation'].append(vec3_list(loc))
                    bone_samples[name]['rotation'].append(quat_wxyz(rot))

        # Optimize channels (same logic for both modes)
        ref_rest = {}
        if RE_EXPORT_MODE and file_rest_locals:
            for bi, name in enumerate(bone_order):
                joint_idx = bi + 1
                if joint_idx in file_rest_locals:
                    ref_rest[name] = file_rest_locals[joint_idx]
                else:
                    ref_rest[name] = posed_rest_locals[name]
        else:
            ref_rest = posed_rest_locals

        channels = []
        for bi, name in enumerate(bone_order):
            joint_idx = bi + 1
            rest = ref_rest[name]

            for path in ['translation', 'rotation']:
                samples = bone_samples[name][path]
                rest_vals = rest[path]

                # Check if constant across frames
                ref = samples[0]
                is_constant = all(
                    all(abs(s[k] - ref[k]) < EPSILON for k in range(len(ref)))
                    for s in samples[1:]
                )

                if is_constant:
                    # Check if matches rest
                    matches_rest = all(abs(ref[k] - rest_vals[k]) < EPSILON for k in range(len(ref)))
                    if matches_rest:
                        continue  # Skip -- sampleAnimation resets to rest
                    else:
                        # Keep as 2-keyframe
                        flat = []
                        for v in ref:
                            flat.append(round(v, 6 if path == 'rotation' else 4))
                        channels.append({
                            'jointIndex': joint_idx,
                            'path': path,
                            'times': [0, round(duration, 4)],
                            'values': flat + flat,
                        })
                else:
                    # Keep full
                    flat = []
                    for s in samples:
                        for v in s:
                            flat.append(round(v, 6 if path == 'rotation' else 4))
                    channels.append({
                        'jointIndex': joint_idx,
                        'path': path,
                        'times': times,
                        'values': flat,
                    })

        all_animations[short_name] = {
            'name': short_name,
            'duration': duration,
            'channels': channels,
        }
        print(f"    {short_name}: {len(channels)} channels, {duration}s")

    # Cleanup
    armature.animation_data.action = None
    bpy.context.view_layer.update()

    return all_animations


# ============================================================================
# STEP 7: VERIFICATION
# ============================================================================

def verify_skeleton(skeleton_data, bone_order):
    """Verify skin matrices = Identity at posed rest."""
    from mathutils import Matrix as M

    ibms = skeleton_data['inverseBindMatrices']
    norm_mats = skeleton_data['boneNormMats']

    max_dev = 0
    worst = ""

    for i, name in enumerate(bone_order):
        wm = norm_mats[name]
        # Reconstruct IBM as Blender matrix (from column-major)
        ibm_flat = ibms[i]
        ibm = M()
        for col in range(4):
            for row in range(4):
                ibm[row][col] = ibm_flat[col * 4 + row]

        skin = wm @ ibm
        for r in range(4):
            for c in range(4):
                expected = 1.0 if r == c else 0.0
                dev = abs(skin[r][c] - expected)
                if dev > max_dev:
                    max_dev = dev
                    worst = name

    status = "PASS" if max_dev < 0.001 else "FAIL"
    print(f"  Skin matrix verification: {status} (max deviation: {max_dev:.8f}, bone: {worst})")
    return max_dev < 0.001


# ============================================================================
# STEP 8: WRITE LUAU FILES (FLAT ARRAYS + sharedTimes)
# ============================================================================

def write_part_file(filepath, var_name, part, skeleton_data=None, bone_order=None):
    """Write one Part .luau file with flat arrays."""
    lines = []
    lines.append("--!strict")
    lines.append(f"-- {os.path.basename(filepath)}")
    lines.append(f"-- Auto-generated by blender_to_rive.py v6.0")
    lines.append(f"-- Vertices: {len(part['vertices'])}, Faces: {len(part['faces'])}")
    lines.append("")
    lines.append(f"local {var_name} = {{}}")
    lines.append("")

    # Skinning patterns
    lines.append("-- Skinning patterns")
    lines.append("local S = {")
    for idx in sorted(part['skinningPatterns'].keys()):
        p = part['skinningPatterns'][idx]
        j = p['j']
        w = p['w']
        lines.append(f"  [{idx}] = {{j = {{{j[0]}, {j[1]}, {j[2]}, {j[3]}}}, w = {{{w[0]}, {w[1]}, {w[2]}, {w[3]}}}}},")
    lines.append("}")
    lines.append("")
    lines.append(f"{var_name}.skinningPatterns = S")
    idx_str = ', '.join(str(i) for i in part['skinningIndex'])
    lines.append(f"{var_name}.skinningIndex = {{{idx_str}}}")
    lines.append("")

    # Skeleton (first part only)
    if skeleton_data and bone_order:
        lines.append(f"{var_name}.skeleton = {{")
        lines.append(f"  jointCount = {skeleton_data['jointCount']},")

        parents = []
        for p in skeleton_data['jointParents']:
            parents.append("nil" if p is None else str(p))
        lines.append(f"  jointParents = {{{', '.join(parents)}}},")

        lines.append("  inverseBindMatrices = {")
        for i, ibm_vals in enumerate(skeleton_data['inverseBindMatrices']):
            vals_str = ", ".join(fmt(v) for v in ibm_vals)
            lines.append(f"    {{{vals_str}}},")
        lines.append("  },")

        lines.append("  restPose = {")
        for rp in skeleton_data['restPose']:
            t = rp['translation']
            r = rp['rotation']
            lines.append(f"    {{translation = {{{t[0]}, {t[1]}, {t[2]}}}, rotation = {{{r[0]}, {r[1]}, {r[2]}, {r[3]}}}, scale = {{1, 1, 1}}}},")
        lines.append("  },")
        lines.append("}")
        lines.append("")

    # Vertices (flat array: stride 3)
    lines.append(f"-- Vertices ({len(part['vertices'])}) — flat array stride 3: x, y, z")
    lines.append(f"{var_name}.vertices = {{")
    # Write ~10 vertices per line for readability
    vals = []
    for x, y, z in part['vertices']:
        vals.extend([fmt(x, 3), fmt(y, 3), fmt(z, 3)])
    # Wrap at ~120 chars per line
    current_line = []
    current_len = 0
    vert_lines = []
    for val in vals:
        entry = val + ","
        if current_len + len(entry) + 1 > 120 and current_line:
            vert_lines.append("  " + " ".join(current_line))
            current_line = [entry]
            current_len = len(entry)
        else:
            current_line.append(entry)
            current_len += len(entry) + 1
    if current_line:
        vert_lines.append("  " + " ".join(current_line))
    lines.extend(vert_lines)
    lines.append("}")
    lines.append("")

    # Faces (flat array: stride 4)
    lines.append(f"-- Faces ({len(part['faces'])}) — flat array stride 4: v1, v2, v3, category")
    lines.append(f"{var_name}.faces = {{")
    face_vals = []
    for v1, v2, v3, c in part['faces']:
        face_vals.extend([str(v1), str(v2), str(v3), str(c)])
    current_line = []
    current_len = 0
    face_lines = []
    for val in face_vals:
        entry = val + ","
        if current_len + len(entry) + 1 > 120 and current_line:
            face_lines.append("  " + " ".join(current_line))
            current_line = [entry]
            current_len = len(entry)
        else:
            current_line.append(entry)
            current_len += len(entry) + 1
    if current_line:
        face_lines.append("  " + " ".join(current_line))
    lines.extend(face_lines)
    lines.append("}")
    lines.append("")

    lines.append(f"return {var_name}")

    with open(filepath, 'w') as fh:
        fh.write('\n'.join(lines))

    size_kb = os.path.getsize(filepath) / 1024
    print(f"  Written: {os.path.basename(filepath)} ({size_kb:.1f} KB)")


def factorize_shared_times(channels):
    """Factorize duplicate times arrays within a clip's channels.
    Returns (shared_times_list, modified_channels) where channels use timeRef instead of times."""
    unique_times = []
    times_to_ref = {}  # tuple of times -> 1-based ref

    for ch in channels:
        times_key = tuple(ch['times'])
        if times_key not in times_to_ref:
            unique_times.append(ch['times'])
            times_to_ref[times_key] = len(unique_times)  # 1-based

    new_channels = []
    for ch in channels:
        times_key = tuple(ch['times'])
        ref = times_to_ref[times_key]
        new_ch = {
            'jointIndex': ch['jointIndex'],
            'path': ch['path'],
            'timeRef': ref,
            'values': ch['values'],
        }
        new_channels.append(new_ch)

    return unique_times, new_channels


def write_anim_file(filepath, var_name, anim_names, all_animations):
    """Write one Animation .luau file with sharedTimes factorization."""
    lines = []
    lines.append("--!strict")
    lines.append(f"-- {os.path.basename(filepath)}")
    lines.append(f"-- Auto-generated by blender_to_rive.py v6.0")
    lines.append(f"-- Animations: {', '.join(anim_names)}")
    lines.append("")
    lines.append(f"local {var_name} = {{}}")
    lines.append("")
    lines.append(f"{var_name}.animations = {{")

    for anim_name in anim_names:
        if anim_name not in all_animations:
            print(f"  WARNING: Animation '{anim_name}' not found, skipping")
            continue
        anim = all_animations[anim_name]

        # Factorize times
        shared_times, factorized_channels = factorize_shared_times(anim['channels'])

        lines.append(f'  ["{anim_name}"] = {{')
        lines.append(f'    name = "{anim["name"]}",')
        lines.append(f'    duration = {anim["duration"]},')

        # sharedTimes
        lines.append(f'    sharedTimes = {{')
        for st in shared_times:
            times_str = ", ".join(fmt(t, 4) for t in st)
            lines.append(f'      {{{times_str}}},')
        lines.append(f'    }},')

        # Channels with timeRef
        lines.append(f'    channels = {{')
        for ch in factorized_channels:
            values_str = ", ".join(fmt(v, 6 if ch['path'] == 'rotation' else 4) for v in ch['values'])
            lines.append(f'      {{jointIndex = {ch["jointIndex"]}, path = "{ch["path"]}", timeRef = {ch["timeRef"]}, values = {{{values_str}}}}},')
        lines.append(f'    }},')

        lines.append(f'  }},')

    lines.append("}")
    lines.append("")
    lines.append(f"return {var_name}")

    with open(filepath, 'w') as fh:
        fh.write('\n'.join(lines))

    size_kb = os.path.getsize(filepath) / 1024
    print(f"  Written: {os.path.basename(filepath)} ({size_kb:.1f} KB)")


# ============================================================================
# MAIN
# ============================================================================

def main():
    print("\n" + "=" * 70)
    print("  BLENDER TO RIVE — Universal 3D Export v6.0")
    print("  (Flat Arrays + sharedTimes + Atlas UV + Posed Rest)")
    print("=" * 70)

    # Step 0: Discover model
    print("\n[0/8] Discovering model...")
    armature, mesh_objects = discover_model()
    print(f"  Armature: {armature.name}")
    print(f"  Meshes: {len(mesh_objects)}")
    for info in mesh_objects:
        print(f"    {info['name']} [{info['skin_type']}] bone={info['parent_bone']}")

    # Step 1: Detect matrix_basis
    print("\n[1/8] Detecting matrix_basis residuals...")
    detect_matrix_basis(armature)

    # Step 2: Build bone order + normalization
    print("\n[2/8] Building bone order & normalization...")
    bone_order = build_bone_order(armature)
    print(f"  Bone order: {len(bone_order)} bones")
    normalize_mat, center, scale, depsgraph = compute_normalization(armature, mesh_objects)

    # Step 3: Export skeleton
    print("\n[3/8] Exporting skeleton (posed rest: pose_bone.matrix)...")
    skeleton_data = export_skeleton(armature, bone_order, normalize_mat)
    print(f"  Joints: {skeleton_data['jointCount']}")

    # Step 4: Export all meshes
    print("\n[4/8] Exporting meshes (evaluated mesh, same depsgraph)...")
    all_verts, all_faces, all_skin, material_map, zone_info = export_all_meshes(
        armature, mesh_objects, bone_order, normalize_mat, depsgraph
    )

    # Step 5: Sort + fragment + factorize
    print("\n[5/8] Sorting faces & fragmenting...")
    parts = sort_and_fragment(all_verts, all_faces, all_skin)
    for i, part in enumerate(parts):
        suffix = chr(ord('A') + i)
        print(f"  Part {suffix}: {len(part['vertices'])}v, {len(part['faces'])}f, {len(part['skinningPatterns'])} patterns")

    # Step 6: Export animations
    print("\n[6/8] Exporting animations...")
    all_animations = export_animations(armature, bone_order, normalize_mat)
    print(f"  Total: {len(all_animations)} animations")

    # Step 7: Verify
    print("\n[7/8] Verifying...")
    verify_skeleton(skeleton_data, bone_order)

    # Step 8: Write files (flat arrays + sharedTimes)
    print("\n[8/8] Writing files...")

    # Part files
    for i, part in enumerate(parts):
        suffix = chr(ord('A') + i)
        var_name = f"{MODEL_NAME}Part{suffix}Data" if len(parts) > 1 else f"{MODEL_NAME}Data"
        filename = f"{MODEL_NAME}Part{suffix}Data.luau" if len(parts) > 1 else f"{MODEL_NAME}Data.luau"
        filepath = os.path.join(OUTPUT_DIR, filename)
        skel = skeleton_data if i == 0 else None
        bo = bone_order if i == 0 else None
        write_part_file(filepath, var_name, part, skel, bo)

    # Animation files -- split into groups
    anim_names = sorted(all_animations.keys())
    if ANIM_FILE_SPLIT:
        anim_groups = ANIM_FILE_SPLIT
    else:
        # Auto-split: ~4-5 animations per file
        group_size = max(3, len(anim_names) // 3 + (1 if len(anim_names) % 3 else 0))
        anim_groups = [anim_names[i:i + group_size] for i in range(0, len(anim_names), group_size)]

    for gi, group in enumerate(anim_groups):
        num = gi + 1
        var_name = f"{MODEL_NAME}Anim{num}Data"
        filename = f"{MODEL_NAME}Anim{num}Data.luau"
        filepath = os.path.join(OUTPUT_DIR, filename)
        write_anim_file(filepath, var_name, group, all_animations)

    # Summary
    print("\n" + "=" * 70)
    print("  EXPORT COMPLETE!")
    print("=" * 70)
    print(f"\n  Output: {OUTPUT_DIR}")
    print(f"  Parts: {len(parts)} files (~{MAX_FACES_PER_PART} faces/part)")
    print(f"  Animations: {len(anim_groups)} files ({len(anim_names)} clips)")
    if material_map:
        print(f"  Materials: {material_map}")
    if zone_info:
        print(f"  Color zones: {len(zone_info)}")
        for cat, info in sorted(zone_info.items()):
            print(f"    {cat}: {info['name']} ({info['count']} faces)")
    print(f"\n  Data format: flat arrays (stride 3 verts, stride 4 faces) + sharedTimes")
    print(f"  Next: Copy .luau files to Rive project")
    print(f"        Implement Node Script with anti-flickering (see CLAUDE.md)")
    print("")


# ============================================================================
# RUN
# ============================================================================

if __name__ == "__main__":
    main()
else:
    main()
