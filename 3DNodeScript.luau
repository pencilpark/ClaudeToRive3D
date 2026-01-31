--!strict
--[[
  3DNodeScript.luau - Reference 3D Node Script for Rive

  This is a REFERENCE implementation for rendering 3D models exported from Blender.
  Parameters and projection logic match 3DHandler.luau for consistency.

  Features:
    - Perspective and orthographic projection (usePerspective toggle)
    - Auto-scale based on model bounding box
    - Z-sorting (painter's algorithm)
    - Diffuse lighting
    - Skeletal animation support (optional)
    - RGBA color support with transparency
    - Backface culling
    - Wireframe mode

  USAGE:
    1. Export your model from Blender using the export scripts
    2. Create data files (ModelPartAData.luau, ModelPartBData.luau, etc.)
    3. Update the require() statements to point to your data files
    4. Customize the material color inputs for your model

  PARAMETERS (matching 3DHandler.luau):
    - scale: Multiplier on autoScale (1 = fit to 200px)
    - fov: Field of view for perspective mode (default: 800)
    - cameraDistance: Camera distance for perspective mode (default: 400)
    - usePerspective: false = orthographic (cleaner), true = perspective
    - brightness: 0-100 (divided by 100 internally, default: 30 = 0.3)
    - faceExpansion: Expand faces from centroid (default: 0.005)
    - backfaceCulling: Hide faces pointing away (default: true)
    - wireframe: Show wireframe instead of filled faces (default: false)
]]

local M = require('Mesh3DUtil')
local SkelAnim = require('SkeletalAnimUtil')

-- Import types
type Mat4 = M.Mat4
type Vec3 = M.Vec3
type Quat = M.Quat

-- TODO: Update these requires to your data files
local CloudPartAData = require('CloudPartAData')
local CloudPartBData = require('CloudPartBData')

type ProjectedFace = {
  path: Path,
  fillPaint: Paint,
  centroidZ: number,
  minZ: number,
  maxZ: number,
}

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
  cameraDistance: number,
  usePerspective: boolean,
  baseBright: number,
  expansion: number,
}

-- TODO: Update material categories for your model
-- Example for Cloud Strife:
-- c=1: Purple clothing (SOLDIER uniform)
-- c=2: Dark brown belt/straps
-- c=3: Boots (very dark brown)
-- ...etc

export type Model3D = {
  -- Rotation controls
  rotationSpeed: Input<number>,
  baseRotationX: Input<number>,
  baseRotationY: Input<number>,
  baseRotationZ: Input<number>,
  -- Joystick controls
  joystickPitch: Input<number>,
  joystickYaw: Input<number>,
  joystickRoll: Input<number>,
  -- Scale and projection (matching 3DHandler)
  scale: Input<number>,
  fov: Input<number>,
  cameraDistance: Input<number>,
  usePerspective: Input<boolean>,
  -- Anchor controls (model center)
  anchorX: Input<number>,
  anchorY: Input<number>,
  anchorZ: Input<number>,
  -- Rendering (matching 3DHandler)
  brightness: Input<number>,
  faceExpansion: Input<number>,
  backfaceCulling: Input<boolean>,
  wireframe: Input<boolean>,
  -- Animation controls
  animationEnabled: Input<boolean>,
  animationName: Input<string>,
  animationSpeed: Input<number>,
  -- Material colors (RGBA supported) - TODO: customize for your model
  clothingColor: Input<Color>,
  beltColor: Input<Color>,
  bootsColor: Input<Color>,
  hairColor: Input<Color>,
  skinColor: Input<Color>,
  eyeWhiteColor: Input<Color>,
  blackDetailColor: Input<Color>,
  metalColor: Input<Color>,
  leatherColor: Input<Color>,
  -- Internal state
  autoAngleY: number,
  animationTime: number,
  projectedFaces: { ProjectedFace },
  autoScale: number,
  -- Bounding box
  boundMinX: number,
  boundMaxX: number,
  boundMinY: number,
  boundMaxY: number,
  boundMinZ: number,
  boundMaxZ: number,
  -- Skeletal animation state (optional)
  skeleton: SkelAnim.Skeleton?,
  currentAnimation: SkelAnim.AnimationClip?,
  skinnedVerticesA: { { number } }?,
  skinnedVerticesB: { { number } }?,
  context: Context?,
  -- Rendering objects
  path: Path,
  strokePaint: Paint,
}

-- Get tint color by category index - TODO: customize for your model
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
-- TODO: update these for your model
local BASE_COLORS = {
  [1] = { 97, 73, 119 },
  [2] = { 90, 26, 0 },
  [3] = { 53, 15, 0 },
  [4] = { 252, 168, 52 },
  [5] = { 248, 167, 135 },
  [6] = { 255, 255, 255 },
  [7] = { 51, 51, 51 },
  [8] = { 137, 137, 137 },
  [9] = { 80, 59, 16 },
}

-- Projection function matching 3DHandler
local function project(
  x: number,
  y: number,
  z: number,
  fov: number,
  distance: number,
  usePerspective: boolean
): (number, number)
  if usePerspective and distance + z > 0.001 then
    local factor = fov / (distance + z)
    return x * factor, y * factor
  else
    -- Orthographic: just return x, y (scale already applied)
    return x, y
  end
end

-- Transform vertex matching 3DHandler (GLB-style Y-up coordinates)
local function transformVertex(
  vx: number,
  vy: number,
  vz: number,
  ax: number,
  ay: number,
  az: number,
  cosX: number,
  sinX: number,
  cosY: number,
  sinY: number,
  cosZ: number,
  sinZ: number
): (number, number, number)
  -- Center on anchor
  local x, y, z = vx - ax, vy - ay, vz - az

  -- Rotation around Y axis (yaw) - horizontal rotation
  local rx = x * cosY + z * sinY
  local rz = -x * sinY + z * cosY
  x, z = rx, rz

  -- Rotation around X axis (pitch) - vertical tilt
  local ry = y * cosX - z * sinX
  local rz2 = y * sinX + z * cosX
  y, z = ry, rz2

  -- Rotation around Z axis (roll)
  local rx2 = x * cosZ - y * sinZ
  local ry2 = x * sinZ + y * cosZ
  x, y = rx2, ry2

  -- Return: X=right, Y=up, Z=depth (for projection)
  return x, y, z
end

local function calculateNormal(
  x1: number, y1: number, z1: number,
  x2: number, y2: number, z2: number,
  x3: number, y3: number, z3: number
): (number, number, number)
  local ux, uy, uz = x2 - x1, y2 - y1, z2 - z1
  local vx, vy, vz = x3 - x1, y3 - y1, z3 - z1
  local nx = uy * vz - uz * vy
  local ny = uz * vx - ux * vz
  local nz = ux * vy - uy * vx
  local len = math.sqrt(nx * nx + ny * ny + nz * nz)
  if len > 0.0001 then
    return nx / len, ny / len, nz / len
  end
  return 0, 0, 1
end

local function calculateLighting(
  nx: number,
  ny: number,
  nz: number,
  baseBrightness: number
): number
  local lx, ly, lz = 0.4, -0.3, 0.9
  local len = math.sqrt(lx * lx + ly * ly + lz * lz)
  lx, ly, lz = lx / len, ly / len, lz / len
  local dot = math.abs(nx * lx + ny * ly + nz * lz)
  return baseBrightness + dot * (1.0 - baseBrightness)
end

-- Process faces from a mesh part (supports triangles and quads)
local function processMeshPart(
  self: Model3D,
  vertices: { { number } },
  faces: { { verts: { number }, c: number } },
  p: RenderParams,
  screenCX: number,
  screenCY: number
)
  for _, face in ipairs(faces) do
    local faceVerts = face.verts
    local vertCount = #faceVerts

    -- Get all vertices
    local verts: { { number } } = {}
    local allValid = true
    for i = 1, vertCount do
      local v = vertices[faceVerts[i]]
      if not v then
        allValid = false
        break
      end
      verts[i] = v
    end
    if not allValid then continue end

    -- Transform all vertices
    local transformed: { { x: number, y: number, z: number } } = {}
    for i = 1, vertCount do
      local v = verts[i]
      local x, y, z = transformVertex(v[1], v[2], v[3], p.ax, p.ay, p.az, p.cosX, p.sinX, p.cosY, p.sinY, p.cosZ, p.sinZ)
      x, y, z = x * p.scale, y * p.scale, z * p.scale
      transformed[i] = { x = x, y = y, z = z }
    end

    -- Calculate normal from first 3 vertices
    local t0, t1, t2 = transformed[1], transformed[2], transformed[3]
    local nx, ny, nz = calculateNormal(t0.x, t0.y, t0.z, t1.x, t1.y, t1.z, t2.x, t2.y, t2.z)

    -- Backface culling (nz > 0 means facing away)
    if self.backfaceCulling and nz > 0 then
      continue
    end

    -- Project all vertices
    local projected: { { sx: number, sy: number } } = {}
    local sumZ = 0
    local minZ, maxZ = math.huge, -math.huge
    for i = 1, vertCount do
      local t = transformed[i]
      local sx, sy = project(t.x, t.y, t.z, p.fov, p.cameraDistance, p.usePerspective)
      sx, sy = sx + screenCX, -sy + screenCY
      projected[i] = { sx = sx, sy = sy }
      sumZ = sumZ + t.z
      minZ = math.min(minZ, t.z)
      maxZ = math.max(maxZ, t.z)
    end

    -- Face expansion
    if p.expansion ~= 0 then
      local cx, cy = 0, 0
      for i = 1, vertCount do
        cx = cx + projected[i].sx
        cy = cy + projected[i].sy
      end
      cx, cy = cx / vertCount, cy / vertCount
      for i = 1, vertCount do
        projected[i].sx = projected[i].sx + (projected[i].sx - cx) * p.expansion
        projected[i].sy = projected[i].sy + (projected[i].sy - cy) * p.expansion
      end
    end

    -- Build path
    local facePath = Path.new()
    facePath:moveTo(Vector.xy(projected[1].sx, projected[1].sy))
    for i = 2, vertCount do
      facePath:lineTo(Vector.xy(projected[i].sx, projected[i].sy))
    end
    facePath:close()

    -- Get color and apply lighting
    local baseColor = BASE_COLORS[face.c] or BASE_COLORS[5]
    local tint = getTintColor(self, face.c)
    local r, g, b, a = M.mapColorWithTint(baseColor[1], baseColor[2], baseColor[3], 255, tint)
    local bright = calculateLighting(nx, ny, nz, p.baseBright)

    local facePaint: Paint
    if self.wireframe then
      facePaint = self.strokePaint
    else
      facePaint = Paint.with({
        style = 'fill',
        color = Color.rgba(
          math.min(255, math.max(0, math.floor(r * bright))),
          math.min(255, math.max(0, math.floor(g * bright))),
          math.min(255, math.max(0, math.floor(b * bright))),
          math.floor(a)
        ),
      })
    end

    table.insert(self.projectedFaces, {
      path = facePath,
      fillPaint = facePaint,
      centroidZ = sumZ / vertCount,
      minZ = minZ,
      maxZ = maxZ,
    })
  end
end

-- Compute bounding box from vertices
local function computeBoundingBox(vertices: { { number } }): (number, number, number, number, number, number)
  local minX = math.huge
  local maxX = -math.huge
  local minY = math.huge
  local maxY = -math.huge
  local minZ = math.huge
  local maxZ = -math.huge

  for _, v in ipairs(vertices) do
    if v[1] < minX then minX = v[1] end
    if v[1] > maxX then maxX = v[1] end
    if v[2] < minY then minY = v[2] end
    if v[2] > maxY then maxY = v[2] end
    if v[3] < minZ then minZ = v[3] end
    if v[3] > maxZ then maxZ = v[3] end
  end

  return minX, maxX, minY, maxY, minZ, maxZ
end

-- Initialize skeleton if data provides it
local function initSkeleton(self: Model3D)
  local skeletonData = (CloudPartAData :: any).skeleton
  if skeletonData then
    local skeleton = SkelAnim.buildSkeleton(skeletonData)
    self.skeleton = skeleton
    print("[3DNodeScript] Skeleton initialized with", skeleton.jointCount, "joints")

    -- Load animations if available
    local animations = (CloudPartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
    if animations then
      local animName = self.animationName
      if animName and animName ~= "" and animations[animName] then
        local clip = animations[animName]
        self.currentAnimation = clip
        print("[3DNodeScript] Animation loaded:", animName, "duration:", clip.duration)
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

  -- Initialize rendering objects
  self.path = Path.new()
  self.strokePaint = Paint.with({
    style = 'stroke',
    thickness = 1,
    color = Color.rgba(150, 150, 150, 200),
    join = 'round',
  })

  -- Compute bounding box from all vertices
  local minX1, maxX1, minY1, maxY1, minZ1, maxZ1 = computeBoundingBox(CloudPartAData.vertices)
  local minX2, maxX2, minY2, maxY2, minZ2, maxZ2 = computeBoundingBox(CloudPartBData.vertices)

  self.boundMinX = math.min(minX1, minX2)
  self.boundMaxX = math.max(maxX1, maxX2)
  self.boundMinY = math.min(minY1, minY2)
  self.boundMaxY = math.max(maxY1, maxY2)
  self.boundMinZ = math.min(minZ1, minZ2)
  self.boundMaxZ = math.max(maxZ1, maxZ2)

  -- Calculate auto-scale (fit to 200px)
  local sizeX = self.boundMaxX - self.boundMinX
  local sizeY = self.boundMaxY - self.boundMinY
  local sizeZ = self.boundMaxZ - self.boundMinZ
  local maxDim = math.max(sizeX, sizeY, sizeZ)

  if maxDim > 0 then
    self.autoScale = 200 / maxDim
  else
    self.autoScale = 1
  end

  print(string.format('[3DNodeScript] Bounds: X[%.4f,%.4f] Y[%.4f,%.4f] Z[%.4f,%.4f]',
    self.boundMinX, self.boundMaxX, self.boundMinY, self.boundMaxY, self.boundMinZ, self.boundMaxZ))
  print(string.format('[3DNodeScript] Model size: %.4f x %.4f x %.4f, autoScale=%.2f',
    sizeX, sizeY, sizeZ, self.autoScale))

  -- Initialize skeleton if data provides it
  initSkeleton(self)

  return true
end

local function advance(self: Model3D, seconds: number): boolean
  -- Auto-rotation around Y axis
  if self.rotationSpeed ~= 0 then
    self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
  end

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

  -- Calculate rotation angles
  local angleX = M.toRadians(self.baseRotationX + self.joystickPitch)
  local angleY = M.toRadians(self.baseRotationY + self.joystickYaw) + self.autoAngleY
  local angleZ = M.toRadians(self.baseRotationZ + self.joystickRoll)

  -- Calculate anchor (use center if not specified)
  local ax, ay, az = self.anchorX / 100, self.anchorY / 100, self.anchorZ / 100
  if ax == 0 and ay == 0 and az == 0 then
    ax = (self.boundMinX + self.boundMaxX) / 2
    ay = (self.boundMinY + self.boundMaxY) / 2
    az = (self.boundMinZ + self.boundMaxZ) / 2
  end

  -- Final scale: combine user scale with auto-calculated scale
  local finalScale = self.autoScale * self.scale

  -- Brightness: divide by 100 (matching 3DHandler)
  local baseBright = self.brightness / 100

  local p: RenderParams = {
    ax = ax,
    ay = ay,
    az = az,
    cosX = math.cos(angleX),
    sinX = math.sin(angleX),
    cosY = math.cos(angleY),
    sinY = math.sin(angleY),
    cosZ = math.cos(angleZ),
    sinZ = math.sin(angleZ),
    scale = finalScale,
    fov = self.fov,
    cameraDistance = self.cameraDistance,
    usePerspective = self.usePerspective,
    baseBright = baseBright,
    expansion = self.faceExpansion,
  }

  -- Clear previous frame
  self.projectedFaces = {}

  -- Get screen center (default 200x200)
  local screenCX = 200
  local screenCY = 200

  -- Use skinned vertices if available, otherwise original
  local verticesA = self.skinnedVerticesA or CloudPartAData.vertices
  local verticesB = self.skinnedVerticesB or CloudPartBData.vertices

  -- Process both mesh parts
  processMeshPart(self, verticesA, CloudPartAData.faces, p, screenCX, screenCY)
  processMeshPart(self, verticesB, CloudPartBData.faces, p, screenCX, screenCY)

  -- Sort faces by depth (back to front - painter's algorithm)
  table.sort(self.projectedFaces, function(a: ProjectedFace, b: ProjectedFace): boolean
    return a.centroidZ > b.centroidZ
  end)

  return true
end

local function draw(self: Model3D, renderer: Renderer)
  for _, face in ipairs(self.projectedFaces) do
    renderer:drawPath(face.path, face.fillPaint)
  end
end

return function(): Node<Model3D>
  return {
    -- Rotation controls (matching 3DHandler)
    rotationSpeed = 0,
    baseRotationX = 0,
    baseRotationY = 0,
    baseRotationZ = 0,
    -- Joystick controls
    joystickPitch = 0,
    joystickYaw = 0,
    joystickRoll = 0,
    -- Scale and projection (matching 3DHandler)
    scale = 1,              -- Multiplier on autoScale (1 = fit to 200px)
    fov = 800,              -- For perspective mode
    cameraDistance = 400,   -- For perspective mode
    usePerspective = false, -- false = orthographic (cleaner), true = perspective
    -- Anchor (model center offset in Blender units * 100)
    anchorX = 0,
    anchorY = 0,
    anchorZ = 0,
    -- Rendering (matching 3DHandler)
    brightness = 30,        -- Will be divided by 100 (0.3)
    faceExpansion = 0.005,
    backfaceCulling = true,
    wireframe = false,
    -- Animation controls
    animationEnabled = false,
    animationName = "idle",
    animationSpeed = 1.0,
    -- Material colors (RGBA supported) - TODO: customize for your model
    clothingColor = Color.rgba(97, 73, 119, 255),
    beltColor = Color.rgba(90, 26, 0, 255),
    bootsColor = Color.rgba(53, 15, 0, 255),
    hairColor = Color.rgba(252, 168, 52, 255),
    skinColor = Color.rgba(248, 167, 135, 255),
    eyeWhiteColor = Color.rgba(255, 255, 255, 255),
    blackDetailColor = Color.rgba(51, 51, 51, 255),
    metalColor = Color.rgba(137, 137, 137, 255),
    leatherColor = Color.rgba(80, 59, 16, 255),
    -- Internal state
    autoAngleY = 0,
    animationTime = 0,
    projectedFaces = {},
    autoScale = 1,
    boundMinX = 0,
    boundMaxX = 0,
    boundMinY = 0,
    boundMaxY = 0,
    boundMinZ = 0,
    boundMaxZ = 0,
    skeleton = nil,
    currentAnimation = nil,
    skinnedVerticesA = nil,
    skinnedVerticesB = nil,
    context = nil,
    path = late(),
    strokePaint = late(),
    -- Lifecycle
    init = init,
    advance = advance,
    draw = draw,
  }
end
