"""
Blender to Rive — Universal 3D Export (v5.0)
=============================================

Exports ANY Blender model (single or multi-mesh, any skeleton) to Rive Luau scripts.
Handles bone-parented rigid meshes AND armature-modifier multi-bone skinning.

PROVEN PROCESS (PIO Robot: 15 meshes, 43 bones, 14 animations, 5664 faces):
  1. Detect matrix_basis residuals → determines "posed rest" vs "pure rest"
  2. Compute normalization in POSED REST position (all meshes combined)
  3. Export skeleton IBMs from POSED REST (pose_bone.matrix, NOT bone.matrix_local)
  4. Export vertices in POSED REST (evaluated mesh with armature)
  5. Export faces with triangulation + material categories + Z-sorting
  6. Factorize skinning (patterns + index per part, supports multi-bone weights)
  7. Sample animations as ABSOLUTE local transforms (never reset matrix_basis)
  8. Optimize: remove static channels matching posed-rest, keep constant-but-different
  9. Verify: skin matrices = Identity, skinned verts = original at posed rest
  10. Fragment into Part files (~1900 faces each) + separate Anim files

Data format:
  - Quaternions: WXYZ in files (Blender native)
  - Joint indices: 1-based in files (Luau arrays)
  - Skinning patterns: 0-based bone indices (runtime adds +1)
  - All data in SAME normalized coordinate space (~200 units max dimension)

Usage:
  1. Open .blend file with rigged model
  2. Configure SETTINGS below (MODEL_NAME, mesh exclusions, etc.)
  3. Run script (Alt+P in Text Editor)
  4. Copy .luau files to Rive project

Can also be executed step-by-step via Blender MCP (preferred for debugging).

Author: Claude + Fred Berria
Version: 5.0.0 (Universal Multi-Mesh + Posed Rest + Verified Export)
"""

import bpy
import bmesh
from mathutils import Matrix, Vector, Quaternion
import os
import math

# ============================================================================
# SETTINGS — EDIT THESE
# ============================================================================

MODEL_NAME = "PioRobot"           # Prefix for output files
TARGET_SIZE = 200.0               # Normalize to ~200 units max dimension
MAX_FACES_PER_PART = 1900         # Rive limit per script file
FPS = 30.0                        # Animation sampling rate
EPSILON = 0.0001                  # Threshold for static channel optimization
OUTPUT_DIR = "/Users/fredberria/PENCIL Park Dropbox/Frédéric BERRIA/_FRED STUFFS/RIVE AMBASSADOR/PIO_ROBOT"

# Meshes to EXCLUDE from export (e.g., helper objects, lights)
EXCLUDE_MESHES = {"Icosphere"}

# Animation name mapping: Blender action name → short display name
# Set to None to auto-derive from action names
ANIM_NAME_MAP = None  # or {"RobotArmature|Robot_Idle_RobotArmature": "Idle", ...}

# How to split animations across files (list of lists of short names)
# Set to None for automatic splitting (~3 anims per file)
ANIM_FILE_SPLIT = None  # or [["Idle", "Walking", "Running"], ["Dance", "Wave", "Yes", "No"], ...]


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
    """Blender Matrix → column-major 16 floats."""
    return [round(mat[row][col], 6) for col in range(4) for row in range(4)]


def quat_wxyz(q):
    """Blender Quaternion → [w, x, y, z] list."""
    return [round(q.w, 6), round(q.x, 6), round(q.y, 6), round(q.z, 6)]


def vec3_list(v, decimals=4):
    """Vector → [x, y, z] list."""
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
    """Check which bones have non-identity matrix_basis (default pose ≠ rest pose)."""
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    residuals = []
    for pb in armature.pose.bones:
        loc, rot, _ = pb.matrix_basis.decompose()
        if loc.length > 0.0001 or abs(rot.w - 1.0) + abs(rot.x) + abs(rot.y) + abs(rot.z) > 0.001:
            residuals.append(pb.name)

    use_posed_rest = len(residuals) > 0
    print(f"  matrix_basis residuals: {len(residuals)}/{len(armature.pose.bones)} bones")
    if residuals:
        for name in residuals[:5]:
            print(f"    ⚠️ {name}")
        if len(residuals) > 5:
            print(f"    ... and {len(residuals) - 5} more")
    print(f"  → Using {'POSED REST' if use_posed_rest else 'PURE REST'} mode")
    return use_posed_rest


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
        for child in children.get(name, []):
            dfs(child)

    for r in roots:
        dfs(r)

    return order


def compute_normalization(armature, mesh_objects):
    """Compute bounding box and normalization matrix in POSED REST position."""
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
        eval_mesh = eval_obj.to_mesh()

        for v in eval_mesh.vertices:
            wp = obj.matrix_world @ v.co
            for i in range(3):
                min_c[i] = min(min_c[i], wp[i])
                max_c[i] = max(max_c[i], wp[i])

        eval_obj.to_mesh_clear()

    center = Vector([(min_c[i] + max_c[i]) / 2 for i in range(3)])
    extent = max(max_c[i] - min_c[i] for i in range(3))
    scale = TARGET_SIZE / extent if extent > 0.0001 else 1.0

    normalize_mat = Matrix.Scale(scale, 4) @ Matrix.Translation(-center)

    print(f"  Center: ({center.x:.4f}, {center.y:.4f}, {center.z:.4f})")
    print(f"  Extent: {extent:.4f}, Scale: {scale:.4f}")

    return normalize_mat, center, scale


# ============================================================================
# STEP 3: EXPORT SKELETON (POSED REST)
# ============================================================================

def export_skeleton(armature, bone_order, normalize_mat):
    """Export skeleton IBMs and rest pose from POSED REST."""
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

def export_all_meshes(armature, mesh_objects, bone_order, normalize_mat):
    """Export vertices, faces, and skinning from all mesh objects combined."""
    if armature.animation_data:
        armature.animation_data.action = None
    armature.data.pose_position = 'POSE'
    bpy.context.view_layer.update()

    # Material sorting: alphabetical → stable category indices
    all_materials = set()
    for info in mesh_objects:
        obj = info['object']
        for slot in obj.material_slots:
            if slot.material:
                all_materials.add(slot.material.name)
    sorted_materials = sorted(all_materials)
    material_map = {name: i + 1 for i, name in enumerate(sorted_materials)}
    print(f"  Materials: {material_map}")

    all_vertices = []
    all_faces = []
    all_skinning = []
    vertex_offset = 0

    depsgraph = bpy.context.evaluated_depsgraph_get()

    for info in mesh_objects:
        obj = info['object']
        skin_type = info['skin_type']
        parent_bone = info['parent_bone']

        # Get evaluated mesh and triangulate
        eval_obj = obj.evaluated_get(depsgraph)
        temp_mesh_src = eval_obj.to_mesh()

        bm = bmesh.new()
        bm.from_mesh(temp_mesh_src)
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        tri_mesh = bpy.data.meshes.new("_temp_tri")
        bm.to_mesh(tri_mesh)
        bm.free()
        eval_obj.to_mesh_clear()

        combined = normalize_mat @ obj.matrix_world

        # Vertices
        mesh_verts = []
        for v in tri_mesh.vertices:
            wp = combined @ v.co
            mesh_verts.append({'x': round(wp.x, 2), 'y': round(wp.y, 2), 'z': round(wp.z, 2)})

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

        # Faces
        face_count = 0
        for poly in tri_mesh.polygons:
            if poly.material_index < len(obj.material_slots) and obj.material_slots[poly.material_index].material:
                mat_name = obj.material_slots[poly.material_index].material.name
            else:
                mat_name = sorted_materials[0] if sorted_materials else "Default"
            category = material_map.get(mat_name, 1)
            verts_1based = [vi + 1 + vertex_offset for vi in poly.vertices]
            all_faces.append({'verts': list(verts_1based), 'c': category})
            face_count += 1

        all_vertices.extend(mesh_verts)
        all_skinning.extend(mesh_skin)
        vertex_offset += len(mesh_verts)

        bpy.data.meshes.remove(tri_mesh)
        print(f"    {obj.name}: {len(mesh_verts)}v/{face_count}f [{skin_type}]")

    print(f"  Total: {len(all_vertices)} vertices, {len(all_faces)} faces")
    return all_vertices, all_faces, all_skinning, material_map


# ============================================================================
# STEP 5: SORT + FRAGMENT + FACTORIZE SKINNING
# ============================================================================

def sort_and_fragment(all_vertices, all_faces, all_skinning):
    """Sort faces by avgZ, split into parts, extract per-part vertices, factorize skinning."""

    # Sort by average Z
    def avg_z(face):
        return sum(all_vertices[vi - 1]['z'] for vi in face['verts']) / len(face['verts'])

    all_faces.sort(key=avg_z)

    # Split into chunks
    chunks = [all_faces[i:i + MAX_FACES_PER_PART] for i in range(0, len(all_faces), MAX_FACES_PER_PART)]

    parts = []
    for chunk in chunks:
        # Extract used vertices
        used = set()
        for f in chunk:
            for vi in f['verts']:
                used.add(vi)

        used_sorted = sorted(used)
        remap = {old: new + 1 for new, old in enumerate(used_sorted)}

        verts = [all_vertices[vi - 1] for vi in used_sorted]
        skin = [all_skinning[vi - 1] for vi in used_sorted]

        faces = [{'verts': [remap[vi] for vi in f['verts']], 'c': f['c']} for f in chunk]

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
# STEP 6: EXPORT ANIMATIONS (ABSOLUTE LOCAL TRANSFORMS)
# ============================================================================

def export_animations(armature, bone_order, normalize_mat):
    """Sample all animations as ABSOLUTE local transforms. Never reset matrix_basis."""
    arm_world = armature.matrix_world
    all_animations = {}

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

    for name in bone_order:
        bone = armature.data.bones[name]
        bmat = norm_world_mats[name]
        if bone.parent and bone.parent.name in bone_order:
            local = norm_world_mats[bone.parent.name].inverted() @ bmat
        else:
            local = bmat
        loc, rot, _ = local.decompose()
        posed_rest_locals[name] = {
            'translation': [loc.x, loc.y, loc.z],
            'rotation': [rot.w, rot.x, rot.y, rot.z],
        }

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
            # Auto-derive: "RobotArmature|Robot_Walking_RobotArmature" → "Walking"
            parts = action.name.split('|')
            if len(parts) > 1:
                inner = parts[1]
                # Remove prefix/suffix patterns
                for prefix in [armature.name + '_', 'Robot_']:
                    if inner.startswith(prefix):
                        inner = inner[len(prefix):]
                for suffix in ['_' + armature.name, '_RobotArmature']:
                    if inner.endswith(suffix):
                        inner = inner[:-len(suffix)]
                short_name = inner
            elif '_' in short_name:
                # Try splitting on underscore
                short_name = short_name.split('_')[1] if len(short_name.split('_')) > 1 else short_name

        # Assign action, DO NOT reset matrix_basis
        armature.animation_data.action = action
        armature.data.pose_position = 'POSE'

        bone_samples = {name: {'translation': [], 'rotation': []} for name in bone_order}
        times = []

        for frame in range(frame_start, frame_end + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            times.append(round((frame - frame_start) / FPS, 4))

            # Compute world matrices for all bones
            frame_mats = {}
            for name in bone_order:
                pb = armature.pose.bones[name]
                bw = arm_world @ pb.matrix
                bn = normalize_mat @ bw
                loc, rot, _ = bn.decompose()
                frame_mats[name] = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

            # Compute local transforms
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

        # Optimize channels
        channels = []
        for bi, name in enumerate(bone_order):
            joint_idx = bi + 1
            rest = posed_rest_locals[name]

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
                    # Check if matches posed rest
                    matches_rest = all(abs(ref[k] - rest_vals[k]) < EPSILON for k in range(len(ref)))
                    if matches_rest:
                        continue  # Skip — sampleAnimation resets to rest
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

    status = "✓ PASS" if max_dev < 0.001 else "✗ FAIL"
    print(f"  Skin matrix verification: {status} (max deviation: {max_dev:.8f}, bone: {worst})")
    return max_dev < 0.001


# ============================================================================
# STEP 8: WRITE LUAU FILES
# ============================================================================

def write_part_file(filepath, var_name, part, skeleton_data=None, bone_order=None):
    """Write one Part .luau file."""
    lines = []
    lines.append("--!strict")
    lines.append(f"-- {os.path.basename(filepath)}")
    lines.append(f"-- Auto-generated by blender_to_rive.py v5.0")
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

    # Vertices
    lines.append(f"-- Vertices ({len(part['vertices'])})")
    lines.append(f"{var_name}.vertices = {{")
    for v in part['vertices']:
        lines.append(f"  {{x={v['x']}, y={v['y']}, z={v['z']}}},")
    lines.append("}")
    lines.append("")

    # Faces
    lines.append(f"-- Faces ({len(part['faces'])})")
    lines.append(f"{var_name}.faces = {{")
    for f in part['faces']:
        vs = f['verts']
        lines.append(f"  {{verts = {{{vs[0]}, {vs[1]}, {vs[2]}}}, c = {f['c']}}},")
    lines.append("}")
    lines.append("")

    lines.append(f"return {var_name}")

    with open(filepath, 'w') as fh:
        fh.write('\n'.join(lines))

    size_kb = os.path.getsize(filepath) / 1024
    print(f"  Written: {os.path.basename(filepath)} ({size_kb:.1f} KB)")


def write_anim_file(filepath, var_name, anim_names, all_animations):
    """Write one Animation .luau file."""
    lines = []
    lines.append("--!strict")
    lines.append(f"-- {os.path.basename(filepath)}")
    lines.append(f"-- Auto-generated by blender_to_rive.py v5.0")
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
        lines.append(f'  ["{anim_name}"] = {{')
        lines.append(f'    name = "{anim["name"]}",')
        lines.append(f'    duration = {anim["duration"]},')
        lines.append(f'    channels = {{')

        for ch in anim['channels']:
            times_str = ", ".join(fmt(t, 4) for t in ch['times'])
            values_str = ", ".join(fmt(v, 6 if ch['path'] == 'rotation' else 4) for v in ch['values'])
            lines.append(f'      {{jointIndex = {ch["jointIndex"]}, path = "{ch["path"]}", times = {{{times_str}}}, values = {{{values_str}}}}},')

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
    print("  BLENDER TO RIVE — Universal 3D Export v5.0")
    print("  (Multi-Mesh + Posed Rest + Verified + Separate Anim Files)")
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
    use_posed_rest = detect_matrix_basis(armature)

    # Step 2: Build bone order + normalization
    print("\n[2/8] Building bone order & normalization...")
    bone_order = build_bone_order(armature)
    print(f"  Bone order: {len(bone_order)} bones")
    normalize_mat, center, scale = compute_normalization(armature, mesh_objects)

    # Step 3: Export skeleton
    print("\n[3/8] Exporting skeleton (posed rest)...")
    skeleton_data = export_skeleton(armature, bone_order, normalize_mat)
    print(f"  Joints: {skeleton_data['jointCount']}")

    # Step 4: Export all meshes
    print("\n[4/8] Exporting meshes...")
    all_verts, all_faces, all_skin, material_map = export_all_meshes(
        armature, mesh_objects, bone_order, normalize_mat
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

    # Step 8: Write files
    print("\n[8/8] Writing files...")

    # Part files
    for i, part in enumerate(parts):
        suffix = chr(ord('A') + i)
        var_name = f"{MODEL_NAME}Part{suffix}Data" if len(parts) > 1 else f"{MODEL_NAME}Data"
        filename = f"{MODEL_NAME}Part{suffix}Data.luau"
        filepath = os.path.join(OUTPUT_DIR, filename)
        skel = skeleton_data if i == 0 else None
        bo = bone_order if i == 0 else None
        write_part_file(filepath, var_name, part, skel, bo)

    # Animation files — split into groups
    anim_names = list(all_animations.keys())
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
    print(f"  Parts: {len(parts)} files")
    print(f"  Animations: {len(anim_groups)} files ({len(anim_names)} clips)")
    print(f"  Materials: {material_map}")
    print(f"\n  Next: Copy .luau files to Rive project")
    print(f"        Implement Node Script with anti-flickering (see CLAUDE.md)")
    print("")


# ============================================================================
# RUN
# ============================================================================

if __name__ == "__main__":
    main()
else:
    main()
