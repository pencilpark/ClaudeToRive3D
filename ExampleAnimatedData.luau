--!strict
--[[
  ExampleAnimatedData.luau - Example data file with skeletal animation

  This file demonstrates the required data structure for animated 3D models.
  Use this as a template when exporting animated models from Blender.

  BLENDER EXPORT WORKFLOW:
  1. Export your rigged/animated model as GLB
  2. Use a Python script to extract:
     - vertices, faces (same as before)
     - skeleton hierarchy (joint parents, inverse bind matrices, rest pose)
     - skinning data (joints and weights per vertex)
     - animation clips (keyframes for each joint)
  3. Format the data as shown below
]]

local ExampleAnimatedData = {}

-- ============================================================================
-- VERTICES (same format as before)
-- ============================================================================

ExampleAnimatedData.vertices = {
  -- Simple cube with 8 vertices for demonstration
  { -1, -1, -1 },  -- 1: back-bottom-left
  {  1, -1, -1 },  -- 2: back-bottom-right
  {  1,  1, -1 },  -- 3: back-top-right
  { -1,  1, -1 },  -- 4: back-top-left
  { -1, -1,  1 },  -- 5: front-bottom-left
  {  1, -1,  1 },  -- 6: front-bottom-right
  {  1,  1,  1 },  -- 7: front-top-right
  { -1,  1,  1 },  -- 8: front-top-left
}

-- ============================================================================
-- FACES (same format as before)
-- ============================================================================

ExampleAnimatedData.faces = {
  -- Front face
  { verts = { 5, 6, 7, 8 }, c = 1 },
  -- Back face
  { verts = { 2, 1, 4, 3 }, c = 1 },
  -- Top face
  { verts = { 8, 7, 3, 4 }, c = 2 },
  -- Bottom face
  { verts = { 1, 2, 6, 5 }, c = 2 },
  -- Right face
  { verts = { 6, 2, 3, 7 }, c = 3 },
  -- Left face
  { verts = { 1, 5, 8, 4 }, c = 3 },
}

-- ============================================================================
-- SKELETON DATA
-- Required for skeletal animation
-- ============================================================================

ExampleAnimatedData.skeleton = {
  -- Number of joints in the skeleton
  jointCount = 3,

  -- Parent joint indices (nil for root joints, 1-indexed)
  -- Joint 1 is root (no parent)
  -- Joint 2's parent is joint 1
  -- Joint 3's parent is joint 2
  jointParents = { nil, 1, 2 },

  -- Inverse Bind Matrices (one Mat4 per joint)
  -- These transform from model space to bone-local space at bind pose
  -- Format: 16 floats in column-major order
  inverseBindMatrices = {
    -- Joint 1 (Root) - identity
    {
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    },
    -- Joint 2 (Child of root) - translated up by 1 unit
    {
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, -1, 0, 1,  -- inverse translation
    },
    -- Joint 3 (Child of joint 2) - translated up by 2 units total
    {
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, -2, 0, 1,  -- inverse translation
    },
  },

  -- Rest pose (initial TRS for each joint)
  restPose = {
    -- Joint 1 (Root)
    {
      translation = { 0, 0, 0 },
      rotation = { 0, 0, 0, 1 },  -- quaternion (x, y, z, w)
      scale = { 1, 1, 1 },
    },
    -- Joint 2
    {
      translation = { 0, 1, 0 },  -- 1 unit up from parent
      rotation = { 0, 0, 0, 1 },
      scale = { 1, 1, 1 },
    },
    -- Joint 3
    {
      translation = { 0, 1, 0 },  -- 1 unit up from parent (2 total)
      rotation = { 0, 0, 0, 1 },
      scale = { 1, 1, 1 },
    },
  },
}

-- ============================================================================
-- SKINNING DATA
-- Maps each vertex to up to 4 joints with weights
-- ============================================================================

ExampleAnimatedData.skinning = {
  -- Joint indices per vertex (4 per vertex, 0-indexed)
  -- Vertex 1 is influenced by joints 0, 0, 0, 0 (only joint 0)
  joints = {
    -- Vertex 1-4 (bottom vertices) - influenced by root joint (0)
    0, 0, 0, 0,  -- vertex 1
    0, 0, 0, 0,  -- vertex 2
    0, 1, 0, 0,  -- vertex 3 (blend root and joint 2)
    0, 1, 0, 0,  -- vertex 4 (blend root and joint 2)
    -- Vertex 5-8 (top vertices) - influenced by joint 2
    1, 2, 0, 0,  -- vertex 5
    1, 2, 0, 0,  -- vertex 6
    1, 2, 0, 0,  -- vertex 7
    1, 2, 0, 0,  -- vertex 8
  },

  -- Weights per vertex (4 per vertex, must sum to 1.0)
  weights = {
    -- Vertex 1-4 (bottom)
    1.0, 0.0, 0.0, 0.0,  -- vertex 1: 100% root
    1.0, 0.0, 0.0, 0.0,  -- vertex 2: 100% root
    0.7, 0.3, 0.0, 0.0,  -- vertex 3: 70% root, 30% joint 2
    0.7, 0.3, 0.0, 0.0,  -- vertex 4: 70% root, 30% joint 2
    -- Vertex 5-8 (top)
    0.5, 0.5, 0.0, 0.0,  -- vertex 5: 50% joint 2, 50% joint 3
    0.5, 0.5, 0.0, 0.0,  -- vertex 6
    0.5, 0.5, 0.0, 0.0,  -- vertex 7
    0.5, 0.5, 0.0, 0.0,  -- vertex 8
  },
}

-- ============================================================================
-- ANIMATION CLIPS
-- Each animation has channels that affect specific joints
-- ============================================================================

ExampleAnimatedData.animations = {
  -- "idle" animation - subtle breathing motion
  ["idle"] = {
    name = "idle",
    duration = 2.0,  -- 2 seconds, loops
    channels = {
      -- Root joint slight up/down motion (breathing)
      {
        jointIndex = 1,  -- 1-indexed
        path = "translation",
        times = { 0.0, 1.0, 2.0 },
        values = {
          -- t=0: starting position
          0, 0, 0,
          -- t=1: slightly up
          0, 0.05, 0,
          -- t=2: back to start (for seamless loop)
          0, 0, 0,
        },
      },
    },
  },

  -- "wave" animation - arm waving motion
  ["wave"] = {
    name = "wave",
    duration = 1.5,
    channels = {
      -- Joint 2 rotation (arm swing)
      {
        jointIndex = 2,
        path = "rotation",
        times = { 0.0, 0.375, 0.75, 1.125, 1.5 },
        values = {
          -- t=0: neutral
          0, 0, 0, 1,
          -- t=0.375: rotated +30 degrees around Z
          0, 0, 0.2588, 0.9659,
          -- t=0.75: back to neutral
          0, 0, 0, 1,
          -- t=1.125: rotated -30 degrees
          0, 0, -0.2588, 0.9659,
          -- t=1.5: back to neutral (loop)
          0, 0, 0, 1,
        },
      },
      -- Joint 3 follows with slight delay
      {
        jointIndex = 3,
        path = "rotation",
        times = { 0.0, 0.5, 1.0, 1.5 },
        values = {
          0, 0, 0, 1,
          0, 0, 0.1305, 0.9914,  -- +15 degrees
          0, 0, -0.1305, 0.9914, -- -15 degrees
          0, 0, 0, 1,
        },
      },
    },
  },

  -- "jump" animation - quick bounce
  ["jump"] = {
    name = "jump",
    duration = 0.8,
    channels = {
      -- Root translation (up and down)
      {
        jointIndex = 1,
        path = "translation",
        times = { 0.0, 0.2, 0.4, 0.6, 0.8 },
        values = {
          0, 0, 0,       -- start
          0, -0.1, 0,    -- crouch
          0, 0.5, 0,     -- jump up
          0, 0.3, 0,     -- coming down
          0, 0, 0,       -- land
        },
      },
      -- Root scale (squash and stretch)
      {
        jointIndex = 1,
        path = "scale",
        times = { 0.0, 0.2, 0.4, 0.6, 0.8 },
        values = {
          1, 1, 1,       -- normal
          1.1, 0.9, 1.1, -- squash
          0.9, 1.2, 0.9, -- stretch
          0.95, 1.1, 0.95,
          1, 1, 1,       -- normal
        },
      },
    },
  },
}

--[[
  BLENDER PYTHON EXPORT SCRIPT TEMPLATE:

  ```python
  import bpy
  import json

  def export_skeleton_data(armature):
      bones = armature.data.bones
      data = {
          "jointCount": len(bones),
          "jointParents": [],
          "inverseBindMatrices": [],
          "restPose": []
      }

      bone_to_index = {bone.name: i+1 for i, bone in enumerate(bones)}

      for bone in bones:
          # Parent index
          parent_idx = bone_to_index.get(bone.parent.name) if bone.parent else None
          data["jointParents"].append(parent_idx)

          # Inverse bind matrix (bone.matrix_local.inverted())
          ibm = bone.matrix_local.inverted()
          data["inverseBindMatrices"].append([
              ibm[0][0], ibm[1][0], ibm[2][0], ibm[3][0],
              ibm[0][1], ibm[1][1], ibm[2][1], ibm[3][1],
              ibm[0][2], ibm[1][2], ibm[2][2], ibm[3][2],
              ibm[0][3], ibm[1][3], ibm[2][3], ibm[3][3],
          ])

          # Rest pose TRS
          loc, rot, scale = bone.matrix_local.decompose()
          data["restPose"].append({
              "translation": [loc.x, loc.y, loc.z],
              "rotation": [rot.x, rot.y, rot.z, rot.w],
              "scale": [scale.x, scale.y, scale.z]
          })

      return data

  def export_skinning_data(mesh_obj, armature):
      mesh = mesh_obj.data
      bones = armature.data.bones
      bone_to_index = {bone.name: i for i, bone in enumerate(bones)}

      joints = []
      weights = []

      for vertex in mesh.vertices:
          # Get vertex groups (bone weights)
          groups = sorted(vertex.groups, key=lambda g: g.weight, reverse=True)[:4]

          v_joints = [0, 0, 0, 0]
          v_weights = [0.0, 0.0, 0.0, 0.0]

          for i, group in enumerate(groups):
              group_name = mesh_obj.vertex_groups[group.group].name
              if group_name in bone_to_index:
                  v_joints[i] = bone_to_index[group_name]
                  v_weights[i] = group.weight

          # Normalize weights
          total = sum(v_weights)
          if total > 0:
              v_weights = [w/total for w in v_weights]

          joints.extend(v_joints)
          weights.extend(v_weights)

      return {"joints": joints, "weights": weights}

  def export_animation(action, armature):
      # ... animation export logic
      pass
  ```
]]

return ExampleAnimatedData
