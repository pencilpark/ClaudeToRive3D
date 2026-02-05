"""
Blender to Rive - Skeletal Animation Exporter
==============================================

Exports any Blender mesh with skeleton, skinning, and animations for Rive Luau scripts.

CRITICAL: All data is exported in the SAME normalized coordinate space:
- Vertices: Centered, scaled to TARGET_SIZE units max dimension
- IBMs: Calculated in the same normalized space with scale=1
- Rest Pose: Local transforms in the same normalized space
- Animations: Final local transforms per keyframe (not deltas!)

Features (v2.2):
- Factorized skinning format for smaller file sizes (~40% reduction)
- Coordinate system: Blender Z-up → Rive (Yaw = XY rotation)
- Anti-flickering: Implement in Node Script with:
  * ProjectedFace type with index field
  * partDepthOffset per Part (0, 10, 20)
  * table.sort with typed comparator + Z_EPSILON (0.001)

Quaternion format: WXYZ (Blender native) - SkeletalAnimUtil handles conversion to XYZW

Usage:
1. Open your .blend file with rigged mesh
2. Configure MODEL_NAME and other settings below
3. Select your armature OR mesh (script finds both automatically)
4. Run this script (Alt+P in Text Editor)
5. Copy output from generated file to your Luau Data file
6. In Node Script: implement anti-flickering (see CLAUDE.md for details)

Output structure:
- ModelData.skeleton (jointCount, jointParents, inverseBindMatrices, restPose)
- ModelData.skinningPatterns (factorized - one entry per bone)
- ModelData.skinningIndex (bone index per vertex)
- ModelData.vertices (x, y, z in normalized space)
- ModelData.faces (verts indices 1-based, c = material category)
- ModelData.animations (channels with times and values)

Author: Claude + Fred Berria
Version: 2.2.0 (Anti-Flickering Documentation)
"""

import bpy
from mathutils import Matrix, Vector, Quaternion
import os

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================================

MODEL_NAME = "Model"           # Name prefix for output (e.g., "MantaRay", "Character")
TARGET_SIZE = 200.0            # Normalize mesh to fit in ~200 units (Rive standard)
OUTPUT_DIR = "//"              # // = relative to .blend file, or absolute path
MAX_FACES_PER_PART = 1800      # Fragment if more faces (Rive script limit)
MAX_VERTS_PER_PART = 2400      # Fragment if more vertices

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def get_armature_and_mesh():
    """Find the armature and its associated mesh automatically."""
    armature = None
    mesh_obj = None

    # Try selected object first
    if bpy.context.active_object:
        if bpy.context.active_object.type == 'ARMATURE':
            armature = bpy.context.active_object
        elif bpy.context.active_object.type == 'MESH':
            mesh_obj = bpy.context.active_object

    # Find armature from mesh modifier
    if mesh_obj and not armature:
        for mod in mesh_obj.modifiers:
            if mod.type == 'ARMATURE' and mod.object:
                armature = mod.object
                break

    # Find mesh from armature children
    if armature and not mesh_obj:
        for child in armature.children:
            if child.type == 'MESH':
                mesh_obj = child
                break

    # Fallback: search all objects
    if not armature:
        for obj in bpy.context.scene.objects:
            if obj.type == 'ARMATURE':
                armature = obj
                break

    if not mesh_obj:
        for obj in bpy.context.scene.objects:
            if obj.type == 'MESH':
                for mod in obj.modifiers:
                    if mod.type == 'ARMATURE':
                        mesh_obj = obj
                        break
                if mesh_obj:
                    break

    return armature, mesh_obj


def calculate_normalization(mesh_obj):
    """Calculate center and scale factor to normalize mesh to TARGET_SIZE."""
    mesh = mesh_obj.data
    world_mat = mesh_obj.matrix_world

    min_coords = [float('inf')] * 3
    max_coords = [float('-inf')] * 3

    for vert in mesh.vertices:
        world_pos = world_mat @ vert.co
        for i in range(3):
            min_coords[i] = min(min_coords[i], world_pos[i])
            max_coords[i] = max(max_coords[i], world_pos[i])

    center = Vector([
        (min_coords[i] + max_coords[i]) / 2.0
        for i in range(3)
    ])

    dimensions = [max_coords[i] - min_coords[i] for i in range(3)]
    max_dim = max(dimensions)
    scale_factor = TARGET_SIZE / max_dim if max_dim > 0.0001 else 1.0

    print(f"  Mesh bounds: {[f'{x:.2f}' for x in min_coords]} to {[f'{x:.2f}' for x in max_coords]}")
    print(f"  Center: ({center.x:.2f}, {center.y:.2f}, {center.z:.2f})")
    print(f"  Max dimension: {max_dim:.2f}")
    print(f"  Scale factor: {scale_factor:.4f}")

    return center, scale_factor


def build_normalization_matrix(center, scale_factor):
    """Build transformation matrix: Scale @ Translate(-center)."""
    translate_mat = Matrix.Translation(-center)
    scale_mat = Matrix.Scale(scale_factor, 4)
    return scale_mat @ translate_mat


def mat4_to_list(mat):
    """Convert Blender Matrix to column-major list of 16 floats."""
    result = []
    for col in range(4):
        for row in range(4):
            result.append(mat[row][col])
    return result


def quat_to_wxyz(q):
    """Convert Blender quaternion to WXYZ list."""
    return [q.w, q.x, q.y, q.z]


def vec3_to_list(v):
    """Convert Vector to list."""
    return [v.x, v.y, v.z]


# ============================================================================
# SKELETON EXPORT
# ============================================================================

def export_skeleton(armature, normalize_mat):
    """Export skeleton data in normalized space."""
    bones = armature.data.bones
    arm_world = armature.matrix_world

    bone_names = [bone.name for bone in bones]
    bone_index = {name: i + 1 for i, name in enumerate(bone_names)}

    joint_count = len(bones)
    joint_parents = []
    inverse_bind_matrices = []
    rest_pose = []

    for bone in bones:
        # Parent index (nil for roots, 1-based)
        parent_idx = bone_index.get(bone.parent.name) if bone.parent else None
        joint_parents.append(parent_idx)

        # Bone world matrix in normalized space
        bone_world = arm_world @ bone.matrix_local
        bone_normalized = normalize_mat @ bone_world

        # CRITICAL: Force scale to 1 to avoid animation amplification
        loc, rot, _ = bone_normalized.decompose()
        bone_mat_no_scale = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

        # IBM = inverse of normalized world matrix
        ibm = bone_mat_no_scale.inverted()
        inverse_bind_matrices.append(mat4_to_list(ibm))

        # Rest pose = local transform relative to parent
        if bone.parent:
            parent_world = arm_world @ bone.parent.matrix_local
            parent_normalized = normalize_mat @ parent_world
            parent_loc, parent_rot, _ = parent_normalized.decompose()
            parent_mat = Matrix.LocRotScale(parent_loc, parent_rot, Vector((1, 1, 1)))
            local_mat = parent_mat.inverted() @ bone_mat_no_scale
        else:
            local_mat = bone_mat_no_scale

        local_loc, local_rot, _ = local_mat.decompose()
        rest_pose.append({
            "translation": vec3_to_list(local_loc),
            "rotation": quat_to_wxyz(local_rot),
            "scale": [1.0, 1.0, 1.0]
        })

    return {
        "jointCount": joint_count,
        "jointParents": joint_parents,
        "inverseBindMatrices": inverse_bind_matrices,
        "restPose": rest_pose,
        "boneNames": bone_names,
        "boneIndex": bone_index
    }


# ============================================================================
# SKINNING EXPORT (FACTORIZED)
# ============================================================================

def export_skinning_factorized(mesh_obj, bone_index, bone_count):
    """
    Export vertex skinning data in FACTORIZED format.

    Returns:
        skinning_patterns: Dict of {bone_index: {j: [indices], w: [weights]}}
        skinning_index: List of bone index per vertex
    """
    mesh = mesh_obj.data
    vgroup_names = {vg.index: vg.name for vg in mesh_obj.vertex_groups}

    # Create patterns table (one entry per bone)
    skinning_patterns = {}
    for i in range(bone_count):
        skinning_patterns[i] = {"j": [i, 0, 0, 0], "w": [1.0, 0.0, 0.0, 0.0]}

    # For each vertex, find primary bone
    skinning_index = []
    for vert in mesh.vertices:
        weights = []
        for vg in vert.groups:
            vg_name = vgroup_names.get(vg.group)
            if vg_name and vg_name in bone_index:
                joint_idx = bone_index[vg_name] - 1  # 0-based
                weights.append((joint_idx, vg.weight))

        # Sort by weight descending, get primary bone
        weights.sort(key=lambda x: -x[1])

        if weights:
            primary_bone = weights[0][0]
        else:
            primary_bone = 0  # Default to root if no weights

        skinning_index.append(primary_bone)

    return skinning_patterns, skinning_index


# ============================================================================
# VERTICES & FACES EXPORT
# ============================================================================

def export_vertices(mesh_obj, normalize_mat):
    """Export vertices in normalized space."""
    mesh = mesh_obj.data
    combined_mat = normalize_mat @ mesh_obj.matrix_world

    vertices = []
    for vert in mesh.vertices:
        pos = combined_mat @ vert.co
        vertices.append({"x": pos.x, "y": pos.y, "z": pos.z})

    return vertices


def export_faces(mesh_obj):
    """Export faces with 1-based vertex indices and material category."""
    mesh = mesh_obj.data
    mesh.calc_loop_triangles()

    faces = []
    for poly in mesh.polygons:
        verts = [v + 1 for v in poly.vertices]  # 1-based for Luau
        mat_idx = poly.material_index + 1       # 1-based category
        faces.append({"verts": verts, "c": mat_idx})

    return faces


# ============================================================================
# ANIMATION EXPORT
# ============================================================================

def export_animations(armature, normalize_mat, bone_index):
    """Export all animations as final local transforms."""
    animations = {}

    if not bpy.data.actions:
        print("  No animations found")
        return animations

    arm_world = armature.matrix_world

    for action in bpy.data.actions:
        # Skip non-armature actions
        if not any(fc.data_path.startswith("pose.bones") for fc in action.fcurves):
            continue

        print(f"  Processing: {action.name}")

        frame_start, frame_end = action.frame_range
        frame_start, frame_end = int(frame_start), int(frame_end)

        # Temporarily assign action
        if armature.animation_data is None:
            armature.animation_data_create()
        old_action = armature.animation_data.action
        armature.animation_data.action = action

        bone_channels = {name: {"translation": [], "rotation": []}
                        for name in bone_index.keys()}

        fps = bpy.context.scene.render.fps

        for frame in range(frame_start, frame_end + 1):
            bpy.context.scene.frame_set(frame)
            time = (frame - frame_start) / fps

            for bone_name in bone_index.keys():
                pose_bone = armature.pose.bones.get(bone_name)
                if not pose_bone:
                    continue

                pose_world = arm_world @ pose_bone.matrix
                pose_normalized = normalize_mat @ pose_world

                loc, rot, _ = pose_normalized.decompose()
                pose_mat = Matrix.LocRotScale(loc, rot, Vector((1, 1, 1)))

                if pose_bone.parent:
                    parent_world = arm_world @ pose_bone.parent.matrix
                    parent_normalized = normalize_mat @ parent_world
                    parent_loc, parent_rot, _ = parent_normalized.decompose()
                    parent_mat = Matrix.LocRotScale(parent_loc, parent_rot, Vector((1, 1, 1)))
                    local_mat = parent_mat.inverted() @ pose_mat
                else:
                    local_mat = pose_mat

                local_loc, local_rot, _ = local_mat.decompose()
                bone_channels[bone_name]["translation"].append((time, vec3_to_list(local_loc)))
                bone_channels[bone_name]["rotation"].append((time, quat_to_wxyz(local_rot)))

        # Convert to animation format
        duration = (frame_end - frame_start) / fps
        channels = []

        for bone_name, data in bone_channels.items():
            joint_idx = bone_index[bone_name]

            if data["translation"]:
                times = [t for t, _ in data["translation"]]
                values = [v for _, vals in data["translation"] for v in vals]
                channels.append({
                    "jointIndex": joint_idx,
                    "path": "translation",
                    "times": times,
                    "values": values
                })

            if data["rotation"]:
                times = [t for t, _ in data["rotation"]]
                values = [v for _, vals in data["rotation"] for v in vals]
                channels.append({
                    "jointIndex": joint_idx,
                    "path": "rotation",
                    "times": times,
                    "values": values
                })

        animations[action.name] = {
            "name": action.name,
            "duration": duration,
            "channels": channels
        }

        armature.animation_data.action = old_action

    bpy.context.scene.frame_set(1)
    return animations


# ============================================================================
# FRAGMENTATION (for large meshes)
# ============================================================================

def fragment_data(vertices, faces, skinning_index, max_faces, max_verts):
    """Split data into multiple parts if exceeding limits."""
    if len(faces) <= max_faces and len(vertices) <= max_verts:
        return [{"vertices": vertices, "faces": faces, "skinning_index": skinning_index}]

    parts = []
    face_chunks = [faces[i:i+max_faces] for i in range(0, len(faces), max_faces)]

    for chunk_idx, face_chunk in enumerate(face_chunks):
        # Find used vertex indices
        used_indices = set()
        for face in face_chunk:
            for v in face["verts"]:
                used_indices.add(v)

        sorted_indices = sorted(used_indices)
        index_map = {old: new + 1 for new, old in enumerate(sorted_indices)}

        # Extract vertices and skinning for this part
        part_vertices = [vertices[i - 1] for i in sorted_indices]
        part_skinning_index = [skinning_index[i - 1] for i in sorted_indices]

        # Remap face indices
        part_faces = []
        for face in face_chunk:
            new_verts = [index_map[v] for v in face["verts"]]
            part_faces.append({"verts": new_verts, "c": face["c"]})

        parts.append({
            "vertices": part_vertices,
            "faces": part_faces,
            "skinning_index": part_skinning_index
        })

    return parts


# ============================================================================
# LUAU OUTPUT FORMATTING
# ============================================================================

def fmt(n):
    """Format number for Luau output."""
    if isinstance(n, float):
        if abs(n) < 0.000001:
            return "0"
        return f"{n:.6f}".rstrip('0').rstrip('.')
    return str(n)


def generate_luau_output(data, part_name="ModelData", bone_count=0):
    """Generate Luau-formatted output string with factorized skinning."""
    lines = []
    lines.append(f"-- Generated by blender_to_rive.py v2.2")
    lines.append(f"-- Model: {MODEL_NAME}")
    lines.append(f"-- Vertices: {len(data['vertices'])}, Faces: {len(data['faces'])}")
    lines.append(f"-- Using factorized skinning format for smaller file size")
    lines.append("")

    # Skinning patterns table (factorized - one per bone)
    lines.append("-- Skinning patterns (one per bone)")
    lines.append("local S = {")
    for i in range(bone_count):
        lines.append(f"  [{i}] = {{j = {{{i}, 0, 0, 0}}, w = {{1.0, 0.0, 0.0, 0.0}}}},")
    lines.append("}")
    lines.append("")

    # Skeleton (only in first part)
    if "skeleton" in data:
        skel = data["skeleton"]
        lines.append("-- " + "=" * 76)
        lines.append("-- SKELETON")
        lines.append("-- " + "=" * 76)
        lines.append("")
        lines.append(f"{part_name}.skeleton = {{")
        lines.append(f"  jointCount = {skel['jointCount']},")

        parents = ", ".join("nil" if p is None else str(p) for p in skel['jointParents'])
        lines.append(f"  jointParents = {{ {parents} }},")

        lines.append("  inverseBindMatrices = {")
        for i, ibm in enumerate(skel['inverseBindMatrices']):
            nums = ", ".join(fmt(n) for n in ibm)
            lines.append(f"    {{ {nums} }},  -- {skel['boneNames'][i]}")
        lines.append("  },")

        lines.append("  restPose = {")
        for i, rp in enumerate(skel['restPose']):
            t = ", ".join(fmt(n) for n in rp['translation'])
            r = ", ".join(fmt(n) for n in rp['rotation'])
            s = ", ".join(fmt(n) for n in rp['scale'])
            lines.append(f"    {{ translation = {{ {t} }}, rotation = {{ {r} }}, scale = {{ {s} }} }},  -- {skel['boneNames'][i]}")
        lines.append("  },")
        lines.append("}")
        lines.append("")

    # Vertices
    lines.append("-- " + "=" * 76)
    lines.append("-- VERTICES")
    lines.append("-- " + "=" * 76)
    lines.append("")
    lines.append(f"{part_name}.vertices = {{")
    for v in data['vertices']:
        lines.append(f"  {{ x = {fmt(v['x'])}, y = {fmt(v['y'])}, z = {fmt(v['z'])} }},")
    lines.append("}")
    lines.append("")

    # Skinning (FACTORIZED format)
    lines.append("-- " + "=" * 76)
    lines.append("-- SKINNING (Factorized)")
    lines.append("-- " + "=" * 76)
    lines.append("")
    lines.append(f"{part_name}.skinningPatterns = S")
    lines.append(f"{part_name}.skinningIndex = {{{', '.join(str(i) for i in data['skinning_index'])}}}")
    lines.append("")

    # Faces
    lines.append("-- " + "=" * 76)
    lines.append("-- FACES")
    lines.append("-- " + "=" * 76)
    lines.append("")
    lines.append(f"{part_name}.faces = {{")
    for f in data['faces']:
        verts = ", ".join(str(v) for v in f['verts'])
        lines.append(f"  {{ verts = {{ {verts} }}, c = {f['c']} }},")
    lines.append("}")
    lines.append("")

    # Animations (only in first part)
    if "animations" in data and data["animations"]:
        lines.append("-- " + "=" * 76)
        lines.append("-- ANIMATIONS")
        lines.append("-- " + "=" * 76)
        lines.append("")
        lines.append(f"{part_name}.animations = {{")

        for anim_name, anim in data['animations'].items():
            lines.append(f'  ["{anim_name}"] = {{')
            lines.append(f'    name = "{anim["name"]}",')
            lines.append(f'    duration = {fmt(anim["duration"])},')
            lines.append("    channels = {")

            for ch in anim['channels']:
                times = ", ".join(fmt(t) for t in ch['times'])
                values = ", ".join(fmt(v) for v in ch['values'])
                lines.append(f'      {{ jointIndex = {ch["jointIndex"]}, path = "{ch["path"]}", times = {{ {times} }}, values = {{ {values} }} }},')

            lines.append("    },")
            lines.append("  },")

        lines.append("}")

    return "\n".join(lines)


# ============================================================================
# MAIN
# ============================================================================

def main():
    print("\n" + "=" * 60)
    print("  BLENDER TO RIVE - Skeletal Animation Exporter v2.2")
    print("  (Factorized Skinning + Anti-Flickering Support)")
    print("=" * 60)

    armature, mesh_obj = get_armature_and_mesh()

    if not armature:
        print("\nERROR: No armature found!")
        print("Please select an armature or a mesh with an armature modifier.")
        return

    if not mesh_obj:
        print("\nERROR: No mesh found!")
        print("Please ensure a mesh is parented to the armature.")
        return

    print(f"\nArmature: {armature.name}")
    print(f"Mesh: {mesh_obj.name}")
    print(f"Model name: {MODEL_NAME}")
    print(f"Target size: {TARGET_SIZE} units")

    # Calculate normalization
    print("\n[1/5] Calculating normalization...")
    center, scale_factor = calculate_normalization(mesh_obj)
    normalize_mat = build_normalization_matrix(center, scale_factor)

    # Export skeleton
    print("\n[2/5] Exporting skeleton...")
    skeleton_data = export_skeleton(armature, normalize_mat)
    bone_count = skeleton_data['jointCount']
    print(f"  Joints: {bone_count}")
    print(f"  Bones: {', '.join(skeleton_data['boneNames'])}")

    # Export mesh data
    print("\n[3/5] Exporting vertices...")
    vertices = export_vertices(mesh_obj, normalize_mat)
    print(f"  Vertices: {len(vertices)}")

    print("\n[4/5] Exporting faces...")
    faces = export_faces(mesh_obj)
    print(f"  Faces: {len(faces)}")

    # Export factorized skinning
    skinning_patterns, skinning_index = export_skinning_factorized(
        mesh_obj, skeleton_data['boneIndex'], bone_count
    )
    print(f"  Skinned vertices: {len(skinning_index)}")
    print(f"  Skinning patterns: {len(skinning_patterns)} (one per bone)")

    # Export animations
    print("\n[5/5] Exporting animations...")
    animations = export_animations(armature, normalize_mat, skeleton_data['boneIndex'])
    print(f"  Animations: {len(animations)}")
    for name, anim in animations.items():
        print(f"    - {name}: {anim['duration']:.2f}s, {len(anim['channels'])} channels")

    # Fragment if needed
    parts = fragment_data(vertices, faces, skinning_index, MAX_FACES_PER_PART, MAX_VERTS_PER_PART)
    print(f"\n  Data split into {len(parts)} part(s)")

    # Generate output files
    output_dir = bpy.path.abspath(OUTPUT_DIR)

    for i, part in enumerate(parts):
        part_suffix = chr(ord('A') + i) if len(parts) > 1 else ""
        part_name = f"{MODEL_NAME}Part{part_suffix}Data" if part_suffix else f"{MODEL_NAME}Data"
        filename = f"{MODEL_NAME}Part{part_suffix}Data.luau" if part_suffix else f"{MODEL_NAME}Data.luau"

        # First part gets skeleton and animations
        if i == 0:
            part["skeleton"] = skeleton_data
            part["animations"] = animations

        output = generate_luau_output(part, part_name, bone_count)
        output_path = os.path.join(output_dir, filename)

        # Add header for Luau file
        header = f"--!strict\n-- {filename}\n-- Auto-generated by blender_to_rive.py v2.2\n\nlocal {part_name} = {{}}\n\n"
        footer = f"\n\nreturn {part_name}\n"

        with open(output_path, 'w') as f:
            f.write(header + output + footer)

        print(f"\n  Saved: {filename}")
        print(f"    Vertices: {len(part['vertices'])}, Faces: {len(part['faces'])}")

    print("\n" + "=" * 60)
    print("  EXPORT COMPLETE!")
    print("=" * 60)
    print(f"\nOutput directory: {output_dir}")
    print("\nNext steps:")
    print("  1. Copy the generated .luau files to your Rive project")
    print("  2. Update require() statements in your main script")
    print("  3. Use skinningPatterns + skinningIndex (factorized format)")
    print("  4. Set animationName input to one of the available animations")
    print("  5. IMPLEMENT ANTI-FLICKERING in Node Script:")
    print("     - Add 'index' field to ProjectedFace type")
    print("     - Add 'partDepthOffset' parameter to processFaces")
    print("     - Use LARGE offsets: 0, 10, 20 (NOT 0.001, 0.002)")
    print("     - Use table.sort with typed comparator + Z_EPSILON (0.001)")
    print("     - See CLAUDE.md for complete implementation")
    print("\n")


# Run
if __name__ == "__main__":
    main()
