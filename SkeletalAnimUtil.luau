--!strict
--[[
  SkeletalAnimUtil - Standalone Skeletal Animation Module for Rive

  Works with pre-exported static data from blender_to_rive.py.
  All data (vertices, skeleton, animations) is in the SAME normalized space.

  QUATERNION FORMAT:
  - Data files use WXYZ (Blender native): {w, x, y, z}
  - This module internally uses XYZW: {x, y, z, w}
  - Conversion is handled automatically in buildSkeleton() and sampleQuat()

  ANIMATION FORMAT:
  - Animation channels contain ABSOLUTE local transforms (not deltas)
  - Each keyframe is the final local TRS for that bone at that time
  - jointIndex is 1-based (Luau arrays)

  COORDINATE SPACE:
  - Everything is in normalized space (centered, scaled to ~200 units)
  - IBMs have scale=1 (no armature scale baked in)
  - Rest pose scale = {1, 1, 1}
]]

local M = require("Mesh3DUtil")

-- Re-export types from Mesh3DUtil
export type Mat4 = M.Mat4
export type Vec3 = M.Vec3
export type Quat = M.Quat

-- Joint state for animation
export type JointState = {
  translation: Vec3,
  rotation: Quat,  -- XYZW
  scale: Vec3,
}

-- Skeleton data structure (from pre-exported data)
export type SkeletonData = {
  jointCount: number,
  jointParents: { number? },
  inverseBindMatrices: { Mat4 },
  restPose: { any },
}

-- Runtime skeleton state
export type Skeleton = {
  jointCount: number,
  jointParents: { number? },
  inverseBindMatrices: { Mat4 },
  restTransforms: { JointState },
  localTransforms: { JointState },
  worldMatrices: { Mat4 },
  skinMatrices: { Mat4 },
}

-- Animation channel
export type AnimationChannel = {
  jointIndex: number,
  path: string,
  times: { number },
  values: { number },
}

-- Animation clip
export type AnimationClip = {
  name: string,
  duration: number,
  channels: { AnimationChannel },
}

-- Skinning data (flat arrays)
export type SkinningData = {
  joints: { number },
  weights: { number },
}

local SkeletalAnimUtil = {}

-- ============================================================================
-- Skeleton Building
-- ============================================================================

function SkeletalAnimUtil.buildSkeleton(data: SkeletonData): Skeleton
  local jointCount = data.jointCount

  -- Copy inverse bind matrices (already at scale 1 from blender_to_rive.py)
  local ibms: { Mat4 } = {}
  for i = 1, jointCount do
    local srcMat = data.inverseBindMatrices[i]
    local mat: Mat4 = {}
    for j = 1, 16 do
      mat[j] = srcMat[j] or 0
    end
    ibms[i] = mat
  end

  local skeleton: Skeleton = {
    jointCount = jointCount,
    jointParents = data.jointParents,
    inverseBindMatrices = ibms,
    restTransforms = {},
    localTransforms = {},
    worldMatrices = {},
    skinMatrices = {},
  }

  -- Initialize transforms from rest pose
  -- Data format: ordered arrays {t1,t2,t3}, rotation WXYZ {w,x,y,z}, scale {1,1,1}
  for i = 1, jointCount do
    local rest = data.restPose[i]
    local t = rest.translation
    local r = rest.rotation
    local s = rest.scale

    -- Rotation: WXYZ {w,x,y,z} → XYZW {x,y,z,w}
    local rx = r[2]
    local ry = r[3]
    local rz = r[4]
    local rw = r[1]

    skeleton.restTransforms[i] = {
      translation = { t[1], t[2], t[3] },
      rotation = { rx, ry, rz, rw },
      scale = { s[1], s[2], s[3] },
    }
    skeleton.localTransforms[i] = {
      translation = { t[1], t[2], t[3] },
      rotation = { rx, ry, rz, rw },
      scale = { s[1], s[2], s[3] },
    }
    skeleton.worldMatrices[i] = M.mat4Identity()
    skeleton.skinMatrices[i] = M.mat4Identity()
  end

  return skeleton
end

-- ============================================================================
-- Animation Sampling
-- ============================================================================

-- Find keyframe index for given time (binary search)
local function findKeyframe(times: { number }, time: number): (number, number)
  if #times == 0 then
    return 1, 0
  end

  if time <= (times[1] or 0) then
    return 1, 0
  end

  if time >= (times[#times] or 0) then
    return #times, 0
  end

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

-- Sample a Vec3 channel (translation or scale)
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

-- Sample a quaternion channel
-- Data values are WXYZ {w,x,y,z,...}, output is XYZW {x,y,z,w}
local function sampleQuat(times: { number }, values: { number }, time: number): Quat
  local idx, t = findKeyframe(times, time)
  local i0 = (idx - 1) * 4
  -- WXYZ → XYZW
  local q0: Quat = {
    values[i0 + 2] or 0,  -- x
    values[i0 + 3] or 0,  -- y
    values[i0 + 4] or 0,  -- z
    values[i0 + 1] or 1,  -- w
  }

  if t == 0 or idx >= #times then
    return q0
  end

  local i1 = idx * 4
  local q1: Quat = {
    values[i1 + 2] or 0,  -- x
    values[i1 + 3] or 0,  -- y
    values[i1 + 4] or 0,  -- z
    values[i1 + 1] or 1,  -- w
  }

  return M.quatSlerp(q0, q1, t)
end

-- Sample animation at given time — writes ABSOLUTE local transforms directly
function SkeletalAnimUtil.sampleAnimation(skeleton: Skeleton, clip: AnimationClip, time: number)
  if clip.duration > 0 then
    time = time % clip.duration
  end

  -- Reset all joints to rest pose first
  for i = 1, skeleton.jointCount do
    local rest = skeleton.restTransforms[i]
    local tr = skeleton.localTransforms[i]
    tr.translation = { rest.translation[1], rest.translation[2], rest.translation[3] }
    tr.rotation = { rest.rotation[1], rest.rotation[2], rest.rotation[3], rest.rotation[4] }
    tr.scale = { rest.scale[1], rest.scale[2], rest.scale[3] }
  end

  -- Apply animation channels (absolute local transforms, NOT deltas)
  for _, channel in ipairs(clip.channels) do
    local jointIdx = channel.jointIndex  -- Already 1-based
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

    -- skinMatrix = worldMatrix * inverseBindMatrix
    local ibm = skeleton.inverseBindMatrices[jointIdx]
    skeleton.skinMatrices[jointIdx] = M.mat4Multiply(worldMat, ibm)
  end
end

-- ============================================================================
-- Vertex Skinning
-- ============================================================================

function SkeletalAnimUtil.skinVertex(
  skeleton: Skeleton,
  x: number, y: number, z: number,
  j0: number, j1: number, j2: number, j3: number,
  w0: number, w1: number, w2: number, w3: number
): (number, number, number)
  local outX, outY, outZ = 0, 0, 0

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

-- ============================================================================
-- Animation Blending
-- ============================================================================

function SkeletalAnimUtil.blendAnimations(
  skeleton: Skeleton,
  clipA: AnimationClip,
  clipB: AnimationClip,
  timeA: number,
  timeB: number,
  blendFactor: number
)
  local tempA: { JointState } = {}
  local tempB: { JointState } = {}

  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempA[i] = {
      translation = { t.translation[1], t.translation[2], t.translation[3] },
      rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] },
      scale = { t.scale[1], t.scale[2], t.scale[3] },
    }
    tempB[i] = {
      translation = { t.translation[1], t.translation[2], t.translation[3] },
      rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] },
      scale = { t.scale[1], t.scale[2], t.scale[3] },
    }
  end

  SkeletalAnimUtil.sampleAnimation(skeleton, clipA, timeA)
  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempA[i].translation = { t.translation[1], t.translation[2], t.translation[3] }
    tempA[i].rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] }
    tempA[i].scale = { t.scale[1], t.scale[2], t.scale[3] }
  end

  SkeletalAnimUtil.sampleAnimation(skeleton, clipB, timeB)
  for i = 1, skeleton.jointCount do
    local t = skeleton.localTransforms[i]
    tempB[i].translation = { t.translation[1], t.translation[2], t.translation[3] }
    tempB[i].rotation = { t.rotation[1], t.rotation[2], t.rotation[3], t.rotation[4] }
    tempB[i].scale = { t.scale[1], t.scale[2], t.scale[3] }
  end

  for i = 1, skeleton.jointCount do
    local a = tempA[i]
    local b = tempB[i]
    local t = skeleton.localTransforms[i]
    t.translation = M.vec3Lerp(a.translation, b.translation, blendFactor)
    t.rotation = M.quatSlerp(a.rotation, b.rotation, blendFactor)
    t.scale = M.vec3Lerp(a.scale, b.scale, blendFactor)
  end
end

-- ============================================================================
-- Reset skeleton to rest pose
-- ============================================================================

function SkeletalAnimUtil.resetToRestPose(skeleton: Skeleton, restPose: { JointState }?)
  for i = 1, skeleton.jointCount do
    local rest = skeleton.restTransforms[i]
    local tr = skeleton.localTransforms[i]
    tr.translation = { rest.translation[1], rest.translation[2], rest.translation[3] }
    tr.rotation = { rest.rotation[1], rest.rotation[2], rest.rotation[3], rest.rotation[4] }
    tr.scale = { rest.scale[1], rest.scale[2], rest.scale[3] }
  end
end

return SkeletalAnimUtil
