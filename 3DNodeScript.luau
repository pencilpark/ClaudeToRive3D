--!strict
-- 3D Node Script for Rive - With Skeletal Animation Support
-- Supports:
--   - RGBA colors with transparency from Property Group
--   - Skeletal animations (optional, if data provides skeleton/skinning)
--   - Multiple mesh parts (auto-fragmentation for >350 polygons)
--   - Interactive rotation controls
--
-- USAGE:
--   1. Create data files with vertices, faces, and optionally skeleton/skinning/animations
--   2. Require your data files and configure the script
--   3. Expose color inputs in Property Group (supports alpha channel)

local M = require('Mesh3DUtil')
local SkelAnim = require('SkeletalAnimUtil')

-- Import types
type Mat4 = M.Mat4
type Vec3 = M.Vec3
type Quat = M.Quat

-- Cloud data parts (split to stay under 350 polygon limit)
local CloudPartAData = require('CloudPartAData')  -- 300 polygons
local CloudPartBData = require('CloudPartBData')  -- 228 polygons

type ProjectedFace = {
  path: Path,
  fillPaint: Paint,
  centroidZ: number,
  minZ: number,
  maxZ: number,
}

type Vec3Simple = { x: number, y: number, z: number }

type RenderParams = {
  ax: number,
  ay: number,
  az: number,
  cosX: number,
  sinX: number,
  cosY: number,
  sinY: number,
  cosZ: number,
  sinZ: number,
  scale: number,
  fov: number,
  dist: number,
  baseBright: number,
  expansion: number,
}

-- Material categories for Cloud Strife:
-- c=1: Purple clothing (SOLDIER uniform)
-- c=2: Dark brown belt/straps
-- c=3: Boots (very dark brown)
-- c=4: Hair (spiky yellow/gold)
-- c=5: Skin tone
-- c=6: Eye whites
-- c=7: Black details (pupils, outlines)
-- c=8: Metal gray (bracers, pauldron)
-- c=9: Brown leather (gloves, bracers)

export type Model3D = {
  -- Rotation controls
  rotationSpeed: Input<number>,
  scale: Input<number>,
  fov: Input<number>,
  baseRotationX: Input<number>,
  baseRotationY: Input<number>,  -- Head to toes axis
  baseRotationZ: Input<number>,
  -- Joystick controls
  joystickPitch: Input<number>,
  joystickYaw: Input<number>,   -- Head to toes axis
  joystickRoll: Input<number>,
  -- Anchor controls (model center)
  baseAnchorX: Input<number>,
  baseAnchorY: Input<number>,
  baseAnchorZ: Input<number>,
  anchorOffsetX: Input<number>,
  anchorOffsetY: Input<number>,
  anchorOffsetZ: Input<number>,
  -- Rendering
  brightness: Input<number>,
  faceExpansion: Input<number>,
  -- Animation controls
  animationEnabled: Input<boolean>,
  animationName: Input<string>,
  animationSpeed: Input<number>,
  -- Material colors (category-based) - NOW WITH RGBA SUPPORT
  clothingColor: Input<Color>,    -- c=1: Purple SOLDIER uniform
  beltColor: Input<Color>,        -- c=2: Dark brown belt/straps
  bootsColor: Input<Color>,       -- c=3: Very dark boots
  hairColor: Input<Color>,        -- c=4: Spiky yellow hair
  skinColor: Input<Color>,        -- c=5: Skin tone
  eyeWhiteColor: Input<Color>,    -- c=6: Eye whites
  blackDetailColor: Input<Color>, -- c=7: Black details (pupils)
  metalColor: Input<Color>,       -- c=8: Metal gray
  leatherColor: Input<Color>,     -- c=9: Brown leather
  -- Internal state
  autoAngleY: number,
  animationTime: number,
  projectedFaces: { ProjectedFace },
  -- Skeletal animation state (optional)
  skeleton: SkelAnim.Skeleton?,
  currentAnimation: SkelAnim.AnimationClip?,
  skinnedVerticesA: { { number } }?,
  skinnedVerticesB: { { number } }?,
  context: Context?,
}

-- Get tint color by category index
local function getTintColor(self: Model3D, category: number): Color
  if category == 1 then return self.clothingColor end
  if category == 2 then return self.beltColor end
  if category == 3 then return self.bootsColor end
  if category == 4 then return self.hairColor end
  if category == 5 then return self.skinColor end
  if category == 6 then return self.eyeWhiteColor end
  if category == 7 then return self.blackDetailColor end
  if category == 8 then return self.metalColor end
  if category == 9 then return self.leatherColor end
  return self.skinColor -- fallback
end

-- Base colors for each category (from Blender material hex values)
-- These serve as intensity reference for tinting
local BASE_COLORS = {
  [1] = { 97, 73, 119 },     -- Purple clothing (61_49_77)
  [2] = { 90, 26, 0 },       -- Dark brown belt (5A_1A_00)
  [3] = { 53, 15, 0 },       -- Very dark boots (35_0F_00)
  [4] = { 252, 168, 52 },    -- Yellow hair (FC_A8_34)
  [5] = { 248, 167, 135 },   -- Skin tone (F8_A7_87)
  [6] = { 255, 255, 255 },   -- Eye white
  [7] = { 51, 51, 51 },      -- Black details (33_33_33)
  [8] = { 137, 137, 137 },   -- Metal gray (89_89_89)
  [9] = { 80, 59, 16 },      -- Brown leather (50_3B_10)
}

-- Transform face vertices (reversed winding for correct normals)
local function transformFaceVerts(
  vertices: { { number } },
  faceVerts: { number },
  p: RenderParams
): { Vec3Simple }
  local result: { Vec3Simple } = {}

  for i = #faceVerts, 1, -1 do
    local v = vertices[faceVerts[i]]
    local vx, vy, vz = v[1], v[2], v[3]

    local x, y, z = M.transformVertex(
      vx, vy, vz,
      p.ax, p.ay, p.az,
      p.cosX, p.sinX,
      p.cosY, p.sinY,
      p.cosZ, p.sinZ
    )
    table.insert(result, { x = x, y = y, z = z })
  end
  return result
end

-- Expand face outward from centroid and return centroid Z
local function expandFace(
  verts: { Vec3Simple },
  expansion: number
): ({ Vec3Simple }, number)
  local cx, cy, cz = 0, 0, 0
  for _, v in ipairs(verts) do
    cx, cy, cz = cx + v.x, cy + v.y, cz + v.z
  end
  local n = #verts
  cx, cy, cz = cx / n, cy / n, cz / n

  local expanded: { Vec3Simple } = {}
  local factor = 1 + expansion
  for _, v in ipairs(verts) do
    table.insert(expanded, {
      x = cx + (v.x - cx) * factor,
      y = cy + (v.y - cy) * factor,
      z = cz + (v.z - cz) * factor,
    })
  end
  return expanded, cz
end

-- Project 3D vertices to 2D screen and get Z range
local function projectVerts(
  verts: { Vec3Simple },
  p: RenderParams
): ({ { px: number, py: number } }, number, number)
  local projected: { { px: number, py: number } } = {}
  local minZ, maxZ = math.huge, -math.huge
  for _, v in ipairs(verts) do
    local px, py = M.project(v.x, v.y, v.z, p.fov, p.dist)
    table.insert(projected, { px = px * p.scale, py = -py * p.scale })
    if v.z < minZ then minZ = v.z end
    if v.z > maxZ then maxZ = v.z end
  end
  return projected, minZ, maxZ
end

-- Build path from projected vertices
local function buildPath(projVerts: { { px: number, py: number } }): Path
  local p = Path.new()
  p:moveTo(Vector.xy(projVerts[1].px, projVerts[1].py))
  for i = 2, #projVerts do
    p:lineTo(Vector.xy(projVerts[i].px, projVerts[i].py))
  end
  p:close()
  return p
end

-- Process single face with lighting (RGBA support)
local function processFace(
  self: Model3D,
  vertices: { { number } },
  face: { verts: { number }, c: number },
  p: RenderParams
)
  local transformed = transformFaceVerts(vertices, face.verts, p)
  local expanded, centZ = expandFace(transformed, p.expansion)
  local projected, minZ, maxZ = projectVerts(expanded, p)

  -- Calculate normal for lighting
  local nx, ny, nz = 0, 0, 1
  if #expanded >= 3 then
    nx, ny, nz = M.calculateNormal(
      expanded[1].x, expanded[1].y, expanded[1].z,
      expanded[2].x, expanded[2].y, expanded[2].z,
      expanded[3].x, expanded[3].y, expanded[3].z
    )
  end

  -- Get base color and tint from category
  local baseColor = BASE_COLORS[face.c] or BASE_COLORS[5]
  local tint = getTintColor(self, face.c)

  -- mapColorWithTint now preserves alpha from tint color (RGBA support)
  local r, g, b, a = M.mapColorWithTint(baseColor[1], baseColor[2], baseColor[3], 255, tint)
  local bright = M.calculateLighting(nx, ny, nz, p.baseBright)

  table.insert(self.projectedFaces, {
    path = buildPath(projected),
    fillPaint = Paint.with({
      style = 'fill',
      color = Color.rgba(
        math.floor(r * bright),
        math.floor(g * bright),
        math.floor(b * bright),
        math.floor(a)  -- Alpha preserved from Property Group color
      ),
    }),
    centroidZ = centZ,
    minZ = minZ,
    maxZ = maxZ,
  })
end

-- Process all faces in a mesh part
local function processMesh(
  self: Model3D,
  vertices: { { number } },
  faces: { { verts: { number }, c: number } },
  p: RenderParams
)
  for _, face in ipairs(faces) do
    processFace(self, vertices, face, p)
  end
end

-- Initialize skeleton if data provides it
local function initSkeleton(self: Model3D)
  -- Check if CloudPartAData has skeleton data
  local skeletonData = (CloudPartAData :: any).skeleton
  if skeletonData then
    self.skeleton = SkelAnim.buildSkeleton(skeletonData)
    print("[3DNodeScript] Skeleton initialized with", self.skeleton.jointCount, "joints")

    -- Load animations if available
    local animations = (CloudPartAData :: any).animations
    if animations then
      local animName = self.animationName
      if animName and animName ~= "" and animations[animName] then
        self.currentAnimation = animations[animName]
        print("[3DNodeScript] Animation loaded:", animName, "duration:", self.currentAnimation.duration)
      else
        -- Try to get first available animation
        for name, anim in pairs(animations) do
          self.currentAnimation = anim
          print("[3DNodeScript] Animation loaded (default):", name)
          break
        end
      end
    end
  end
end

local function init(self: Model3D, context: Context): boolean
  self.context = context
  self.autoAngleY = 0
  self.animationTime = 0
  self.projectedFaces = {}

  -- Initialize skeleton if data provides it
  initSkeleton(self)

  return true
end

local function advance(self: Model3D, seconds: number): boolean
  -- Auto-rotation around Y axis (head-to-toes)
  self.autoAngleY = self.autoAngleY + seconds * self.rotationSpeed

  -- Update skeletal animation if enabled and available
  if self.animationEnabled and self.skeleton and self.currentAnimation then
    self.animationTime = self.animationTime + seconds * self.animationSpeed
    SkelAnim.sampleAnimation(self.skeleton, self.currentAnimation, self.animationTime)
    SkelAnim.updateSkeleton(self.skeleton)

    -- Skin vertices if skinning data is available
    local skinningA = (CloudPartAData :: any).skinning
    local skinningB = (CloudPartBData :: any).skinning
    if skinningA then
      self.skinnedVerticesA = SkelAnim.skinVertices(self.skeleton, CloudPartAData.vertices, skinningA)
    end
    if skinningB then
      self.skinnedVerticesB = SkelAnim.skinVertices(self.skeleton, CloudPartBData.vertices, skinningB)
    end
  else
    -- Use original vertices
    self.skinnedVerticesA = nil
    self.skinnedVerticesB = nil
  end

  -- Combine base rotation with joystick input
  -- Y rotation = head to toes axis
  local rotX = M.toRadians(self.baseRotationX + self.joystickPitch)
  local rotY = M.toRadians(self.baseRotationY + self.joystickYaw) + self.autoAngleY
  local rotZ = M.toRadians(self.baseRotationZ + self.joystickRoll)

  local p: RenderParams = {
    ax = (self.baseAnchorX + self.anchorOffsetX) / 100,
    ay = (self.baseAnchorY + self.anchorOffsetY) / 100,
    az = (self.baseAnchorZ + self.anchorOffsetZ) / 100,
    cosX = math.cos(rotX),
    sinX = math.sin(rotX),
    cosY = math.cos(rotY),
    sinY = math.sin(rotY),
    cosZ = math.cos(rotZ),
    sinZ = math.sin(rotZ),
    scale = self.scale,
    fov = self.fov,
    dist = 25,  -- Distance for model
    baseBright = self.brightness,
    expansion = self.faceExpansion,
  }

  -- Clear previous frame
  self.projectedFaces = {}

  -- Use skinned vertices if available, otherwise original
  local verticesA = self.skinnedVerticesA or CloudPartAData.vertices
  local verticesB = self.skinnedVerticesB or CloudPartBData.vertices

  -- Process both mesh parts
  processMesh(self, verticesA, CloudPartAData.faces, p)
  processMesh(self, verticesB, CloudPartBData.faces, p)

  -- Sort faces by depth (back to front - painter's algorithm)
  table.sort(
    self.projectedFaces,
    function(a: ProjectedFace, b: ProjectedFace): boolean
      if math.abs(a.centroidZ - b.centroidZ) > 0.0001 then
        return a.centroidZ > b.centroidZ
      end
      if math.abs(a.maxZ - b.maxZ) > 0.0001 then
        return a.maxZ > b.maxZ
      end
      return a.minZ > b.minZ
    end
  )

  return true
end

local function draw(self: Model3D, renderer: Renderer)
  for _, face in ipairs(self.projectedFaces) do
    renderer:drawPath(face.path, face.fillPaint)
  end
end

return function(): Node<Model3D>
  return {
    -- Rotation (Y = head to toes axis)
    rotationSpeed = 0.3,
    scale = 20,
    fov = 300,
    baseRotationX = 0,
    baseRotationY = 0,   -- Y rotation = around vertical axis
    baseRotationZ = 0,
    -- Joystick controls
    joystickPitch = 0,
    joystickYaw = 0,     -- Yaw = Y rotation
    joystickRoll = 0,
    -- Anchor (model center offset in Blender units * 100)
    baseAnchorX = 0,
    baseAnchorY = 0,
    baseAnchorZ = 0,
    anchorOffsetX = 0,
    anchorOffsetY = 0,
    anchorOffsetZ = 0,
    -- Rendering
    brightness = 0.4,
    faceExpansion = 0.005,
    -- Animation controls
    animationEnabled = false,  -- Set to true when you have skeleton data
    animationName = "idle",    -- Name of animation to play
    animationSpeed = 1.0,      -- Animation playback speed multiplier
    -- Material colors (FF7 PS1 authentic palette) - RGBA SUPPORTED
    -- Adjust alpha (4th value) for transparency: 0 = invisible, 255 = opaque
    clothingColor = Color.rgba(97, 73, 119, 255),     -- Purple SOLDIER uniform
    beltColor = Color.rgba(90, 26, 0, 255),           -- Dark brown belt
    bootsColor = Color.rgba(53, 15, 0, 255),          -- Very dark boots
    hairColor = Color.rgba(252, 168, 52, 255),        -- Spiky yellow hair
    skinColor = Color.rgba(248, 167, 135, 255),       -- Skin tone
    eyeWhiteColor = Color.rgba(255, 255, 255, 255),   -- Eye whites
    blackDetailColor = Color.rgba(51, 51, 51, 255),   -- Black details
    metalColor = Color.rgba(137, 137, 137, 255),      -- Metal gray
    leatherColor = Color.rgba(80, 59, 16, 255),       -- Brown leather
    -- Internal state
    autoAngleY = 0,
    animationTime = 0,
    projectedFaces = {},
    skeleton = nil,
    currentAnimation = nil,
    skinnedVerticesA = nil,
    skinnedVerticesB = nil,
    context = nil,
    -- Lifecycle
    init = init,
    advance = advance,
    draw = draw,
  }
end
