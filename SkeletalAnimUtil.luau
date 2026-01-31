--!strict
--[[
  SkeletalAnimUtil - Standalone Skeletal Animation Module for Rive

  Works with pre-exported static data (no GLBLoader dependency).
  Use this with data files that contain skeleton, skinning, and animation data
  extracted from Blender.

  REQUIRED DATA STRUCTURE IN YOUR DATA FILES:

  ModelData.skeleton = {
    jointCount = 5,
    jointParents = { nil, 1, 2, 2, 1 },  -- nil for root joints
    inverseBindMatrices = { {...}, {...}, ... },  -- 16 floats per joint (Mat4)
    restPose = {  -- Initial TRS per joint
      { translation = {0,0,0}, rotation = {0,0,0,1}, scale = {1,1,1} },
      ...
    },
  }

  ModelData.skinning = {
    joints = { 0,0,0,0, 1,2,0,0, ... },  -- 4 joint indices per vertex
    weights = { 1,0,0,0, 0.5,0.5,0,0, ... },  -- 4 weights per vertex
  }

  ModelData.animations = {
    ["idle"] = {
      duration = 2.0,
      channels = {
        { jointIndex = 1, path = "rotation", times = {0, 1, 2}, values = {...} },
        ...
      },
    },
    ["walk"] = { ... },
  }
]]

local M = require("Mesh3DUtil")

-- Re-export types from Mesh3DUtil
export type Mat4 = M.Mat4
export type Vec3 = M.Vec3
export type Quat = M.Quat

-- Joint state for animation
export type JointState = {
  translation: Vec3,
  rotation: Quat,
  scale: Vec3,
}

-- Skeleton data structure (from pre-exported data)
export type SkeletonData = {
  jointCount: number,
  jointParents: { number? },  -- parent joint index (nil for roots)
  inverseBindMatrices: { Mat4 },  -- one Mat4 per joint
  restPose: { JointState },  -- initial transforms
}

-- Runtime skeleton state
export type Skeleton = {
  jointCount: number,
  jointParents: { number? },
  inverseBindMatrices: { Mat4 },
  localTransforms: { JointState },  -- current animated transforms
  worldMatrices: { Mat4 },  -- computed world transform per joint
  skinMatrices: { Mat4 },  -- final skinning matrices (world * inverseBind)
}

-- Animation channel
export type AnimationChannel = {
  jointIndex: number,
  path: string,  -- "translation", "rotation", or "scale"
  times: { number },
  values: { number },  -- flattened (3 per keyframe for vec3, 4 for quat)
  interpolation: string?,  -- "LINEAR", "STEP", or "CUBICSPLINE"
}

-- Animation clip
export type AnimationClip = {
  name: string,
  duration: number,
  channels: { AnimationChannel },
}

-- Skinning data
export type SkinningData = {
  joints: { number },  -- 4 per vertex
  weights: { number },  -- 4 per vertex
}

local SkeletalAnimUtil = {}

-- ============================================================================
-- Skeleton Building (from static data)
-- ============================================================================

function SkeletalAnimUtil.buildSkeleton(data: SkeletonData): Skeleton
  local skeleton: Skeleton = {
    jointCount = data.jointCount,
    jointParents = data.jointParents,
    inverseBindMatrices = data.inverseBindMatrices,
    localTransforms = {},
    worldMatrices = {},
    skinMatrices = {},
  }

  -- Initialize transforms from rest pose
  for i = 1, data.jointCount do
    local rest = data.restPose[i]
    skeleton.localTransforms[i] = {
      translation = { rest.translation[1], rest.translation[2], rest.translation[3] },
      rotation = { rest.rotation[1], rest.rotation[2], rest.rotation[3], rest.rotation[4] },
      scale = { rest.scale[1], rest.scale[2], rest.scale[3] },
    }
    skeleton.worldMatrices[i] = M.mat4Identity()
    skeleton.skinMatrices[i] = M.mat4Identity()
  end

  return skeleton
end

-- ============================================================================
-- Animation Sampling
-- ============================================================================

-- Find keyframe index for given time
local function findKeyframe(times: { number }, time: number): (number, number)
  if #times == 0 then
    return 1, 0
  end

  if time <= (times[1] or 0) then
    return 1, 0
  end

  if time >= (times[#times] or 0) then
    return #times, 1
  end

  -- Binary search
  local lo, hi = 1, #times
  while lo < hi - 1 do
    local mid = math.floor((lo + hi) / 2)
    if (times[mid] or 0) <= time then
      lo = mid
    else
      hi = mid
    end
  end

  local t0 = times[lo] or 0
  local t1 = times[hi] or t0
  local t = 0
  if t1 > t0 then
    t = (time - t0) / (t1 - t0)
  end

  return lo, t
end

-- Sample a Vec3 channel at given time
local function sampleVec3(times: { number }, values: { number }, time: number): Vec3
  local idx, t = findKeyframe(times, time)
  local i0 = (idx - 1) * 3
  local v0: Vec3 = {
    values[i0 + 1] or 0,
    values[i0 + 2] or 0,
    values[i0 + 3] or 0,
  }

  if t == 0 or idx >= #times then
    return v0
  end

  local i1 = idx * 3
  local v1: Vec3 = {
    values[i1 + 1] or 0,
    values[i1 + 2] or 0,
    values[i1 + 3] or 0,
  }

  return M.vec3Lerp(v0, v1, t)
end

-- Sample a Quat channel at given time
local function sampleQuat(times: { number }, values: { number }, time: number): Quat
  local idx, t = findKeyframe(times, time)
  local i0 = (idx - 1) * 4
  local q0: Quat = {
    values[i0 + 1] or 0,
    values[i0 + 2] or 0,
    values[i0 + 3] or 0,
    values[i0 + 4] or 1,
  }

  if t == 0 or idx >= #times then
    return q0
  end

  local i1 = idx * 4
  local q1: Quat = {
    values[i1 + 1] or 0,
    values[i1 + 2] or 0,
    values[i1 + 3] or 0,
    values[i1 + 4] or 1,
  }

  return M.quatSlerp(q0, q1, t)
end

-- Sample animation at given time and update skeleton's local transforms
function SkeletalAnimUtil.sampleAnimation(skeleton: Skeleton, clip: AnimationClip, time: number)
  -- Wrap time to animation duration
  if clip.duration > 0 then
    time = time % clip.duration
  end

  for _, channel in ipairs(clip.channels) do
    local jointIdx = channel.jointIndex
    local transform = skeleton.localTransforms[jointIdx]

    if transform then
      if channel.path == "translation" then
        transform.translation = sampleVec3(channel.times, channel.values, time)
      elseif channel.path == "rotation" then
        transform.rotation = sampleQuat(channel.times, channel.values, time)
      elseif channel.path == "scale" then
        transform.scale = sampleVec3(channel.times, channel.values, time)
      end
    end
  end
end

-- ============================================================================
-- Skeleton Update
-- ============================================================================

-- Update skeleton's world and skin matrices from local transforms
function SkeletalAnimUtil.updateSkeleton(skeleton: Skeleton)
  for jointIdx = 1, skeleton.jointCount do
    local transform = skeleton.localTransforms[jointIdx]
    local localMat = M.mat4FromTRS(transform.translation, transform.rotation, transform.scale)

    local parentIdx = skeleton.jointParents[jointIdx]
    local worldMat: Mat4

    if parentIdx then
      worldMat = M.mat4Multiply(skeleton.worldMatrices[parentIdx], localMat)
    else
      worldMat = localMat
    end

    skeleton.worldMatrices[jointIdx] = worldMat
    skeleton.skinMatrices[jointIdx] = M.mat4Multiply(worldMat, skeleton.inverseBindMatrices[jointIdx])
  end
end

-- ============================================================================
-- Vertex Skinning
-- ============================================================================

-- Skin a single vertex
function SkeletalAnimUtil.skinVertex(
  skeleton: Skeleton,
  x: number, y: number, z: number,
  j0: number, j1: number, j2: number, j3: number,
  w0: number, w1: number, w2: number, w3: number
): (number, number, number)
  local outX, outY, outZ = 0, 0, 0

  -- Joint indices are 0-based in data, convert to 1-based
  local joints = { j0 + 1, j1 + 1, j2 + 1, j3 + 1 }
  local weights = { w0, w1, w2, w3 }

  for i = 1, 4 do
    local weight = weights[i]
    if weight > 0 then
      local jointIdx = joints[i]
      local mat = skeleton.skinMatrices[jointIdx]
      if mat then
        local tx, ty, tz = M.mat4TransformPoint(mat, x, y, z)
        outX = outX + tx * weight
        outY = outY + ty * weight
        outZ = outZ + tz * weight
      end
    end
  end

  return outX, outY, outZ
end

-- Skin all vertices and return new positions table
-- Input: positions as { {x,y,z}, {x,y,z}, ... }
-- Output: same format with skinned positions
function SkeletalAnimUtil.skinVertices(
  skeleton: Skeleton,
  vertices: { { number } },  -- Original vertices array
  skinning: SkinningData
): { { number } }
  local result: { { number } } = {}
  local vertexCount = #vertices

  for i = 1, vertexCount do
    local v = vertices[i]
    local x, y, z = v[1], v[2], v[3]

    local ji = (i - 1) * 4
    local j0 = skinning.joints[ji + 1] or 0
    local j1 = skinning.joints[ji + 2] or 0
    local j2 = skinning.joints[ji + 3] or 0
    local j3 = skinning.joints[ji + 4] or 0

    local w0 = skinning.weights[ji + 1] or 0
    local w1 = skinning.weights[ji + 2] or 0
    local w2 = skinning.weights[ji + 3] or 0
    local w3 = skinning.weights[ji + 4] or 0

    local sx, sy, sz = SkeletalAnimUtil.skinVertex(skeleton, x, y, z, j0, j1, j2, j3, w0, w1, w2, w3)
    table.insert(result, { sx, sy, sz })
  end

  return result
end

-- ============================================================================
-- Animation Blending (bonus feature)
-- ============================================================================

-- Blend between two animation states
function SkeletalAnimUtil.blendAnimations(
  skeleton: Skeleton,
  clipA: AnimationClip,
  clipB: AnimationClip,
  timeA: number,
  timeB: number,
  blendFactor: number  -- 0 = full A, 1 = full B
)
  -- Sample both animations
  local tempTransformsA: { JointState } = {}
  local tempTransformsB: { JointState } = {}

  -- Store current transforms
  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempTransformsA[i] = {
      translation = { t.translation[1], t.translation[2], t.translation[3] },
      rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] },
      scale = { t.scale[1], t.scale[2], t.scale[3] },
    }
    tempTransformsB[i] = {
      translation = { t.translation[1], t.translation[2], t.translation[3] },
      rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] },
      scale = { t.scale[1], t.scale[2], t.scale[3] },
    }
  end

  -- Sample A
  SkeletalAnimUtil.sampleAnimation(skeleton, clipA, timeA)
  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempTransformsA[i].translation = { t.translation[1], t.translation[2], t.translation[3] }
    tempTransformsA[i].rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] }
    tempTransformsA[i].scale = { t.scale[1], t.scale[2], t.scale[3] }
  end

  -- Sample B
  SkeletalAnimUtil.sampleAnimation(skeleton, clipB, timeB)
  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempTransformsB[i].translation = { t.translation[1], t.translation[2], t.translation[3] }
    tempTransformsB[i].rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] }
    tempTransformsB[i].scale = { t.scale[1], t.scale[2], t.scale[3] }
  end

  -- Blend
  for i = 1, skeleton.jointCount do
    local a = tempTransformsA[i]
    local b = tempTransformsB[i]
    local t = skeleton.localTransforms[i]

    t.translation = M.vec3Lerp(a.translation, b.translation, blendFactor)
    t.rotation = M.quatSlerp(a.rotation, b.rotation, blendFactor)
    t.scale = M.vec3Lerp(a.scale, b.scale, blendFactor)
  end
end

-- ============================================================================
-- Reset skeleton to rest pose
-- ============================================================================

function SkeletalAnimUtil.resetToRestPose(skeleton: Skeleton, restPose: { JointState })
  for i = 1, skeleton.jointCount do
    local rest = restPose[i]
    local t = skeleton.localTransforms[i]
    t.translation = { rest.translation[1], rest.translation[2], rest.translation[3] }
    t.rotation = { rest.rotation[1], rest.rotation[2], rest.rotation[3], rest.rotation[4] }
    t.scale = { rest.scale[1], rest.scale[2], rest.scale[3] }
  end
end

return SkeletalAnimUtil
