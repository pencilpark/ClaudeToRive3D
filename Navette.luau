--!strict
-- Navette 3D Renderer - Node Script for Rive
-- Spaceship/shuttle model with real-time 3D rendering
-- Uses Mesh3DUtil for math functions

local M = require('Mesh3DUtil')

-- Navette data (4 parts - 1348 polygons total)
local NavettePartAData = require('NavettePartAData')
local NavettePartBData = require('NavettePartBData')
local NavettePartCData = require('NavettePartCData')
local NavettePartDData = require('NavettePartDData')

type ProjectedFace = {
  path: Path,
  fillPaint: Paint,
  centroidZ: number,
  minZ: number,
  maxZ: number,
}

type Vec3 = { x: number, y: number, z: number }

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

export type Navette = {
  -- Rotation controls
  rotationSpeed: Input<number>,
  scale: Input<number>,
  fov: Input<number>,
  baseRotationX: Input<number>,
  baseRotationY: Input<number>,
  baseRotationZ: Input<number>,
  -- Joystick controls
  joystickPitch: Input<number>,
  joystickYaw: Input<number>,
  joystickRoll: Input<number>,
  -- Anchor controls
  baseAnchorX: Input<number>,
  baseAnchorY: Input<number>,
  baseAnchorZ: Input<number>,
  anchorOffsetX: Input<number>,
  anchorOffsetY: Input<number>,
  anchorOffsetZ: Input<number>,
  -- Rendering
  brightness: Input<number>,
  faceExpansion: Input<number>,
  -- Material colors (category-based)
  primaryColor: Input<Color>,   -- c=1: Pink/magenta hull
  secondaryColor: Input<Color>, -- c=2: Dark purple panels
  accentColor: Input<Color>,    -- c=3: Dark gray structure
  highlightColor: Input<Color>, -- c=4: Light gray/metallic
  edgeColor: Input<Color>,      -- c=5: Black details
  -- Internal state
  autoAngleY: number,
  projectedFaces: { ProjectedFace },
}

-- Get tint color by category index
local function getTintColor(self: Navette, category: number): Color
  if category == 1 then
    return self.primaryColor
  end
  if category == 2 then
    return self.secondaryColor
  end
  if category == 3 then
    return self.accentColor
  end
  if category == 4 then
    return self.highlightColor
  end
  if category == 5 then
    return self.edgeColor
  end
  return self.accentColor -- fallback
end

-- Base colors for each category (from texture analysis)
local BASE_COLORS = {
  [1] = { 180, 96, 155 },  -- Pink/magenta
  [2] = { 120, 60, 100 },  -- Dark purple
  [3] = { 63, 63, 63 },    -- Dark gray
  [4] = { 100, 100, 100 }, -- Light gray
  [5] = { 20, 20, 20 },    -- Black
}

-- Transform face vertices
local function transformFaceVerts(
  vertices: { { number } },
  faceVerts: { number },
  p: RenderParams
): { Vec3 }
  local result: { Vec3 } = {}

  for i = #faceVerts, 1, -1 do
    local v = vertices[faceVerts[i]]
    local vx, vy, vz = v[1], v[2], v[3]

    local x, y, z = M.transformVertex(
      vx,
      vy,
      vz,
      p.ax,
      p.ay,
      p.az,
      p.cosX,
      p.sinX,
      p.cosY,
      p.sinY,
      p.cosZ,
      p.sinZ
    )
    table.insert(result, { x = x, y = y, z = z })
  end
  return result
end

-- Expand face and get centroid Z
local function expandFace(
  verts: { Vec3 },
  expansion: number
): ({ Vec3 }, number)
  local cx, cy, cz = 0, 0, 0
  for _, v in ipairs(verts) do
    cx, cy, cz = cx + v.x, cy + v.y, cz + v.z
  end
  local n = #verts
  cx, cy, cz = cx / n, cy / n, cz / n

  local expanded: { Vec3 } = {}
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

-- Project vertices and get Z range
local function projectVerts(
  verts: { Vec3 },
  p: RenderParams
): ({ { px: number, py: number } }, number, number)
  local projected: { { px: number, py: number } } = {}
  local minZ, maxZ = math.huge, -math.huge
  for _, v in ipairs(verts) do
    local px, py = M.project(v.x, v.y, v.z, p.fov, p.dist)
    table.insert(projected, { px = px * p.scale, py = -py * p.scale })
    if v.z < minZ then
      minZ = v.z
    end
    if v.z > maxZ then
      maxZ = v.z
    end
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

-- Process single face
local function processFace(
  self: Navette,
  vertices: { { number } },
  face: { verts: { number }, c: number },
  p: RenderParams
)
  local transformed = transformFaceVerts(vertices, face.verts, p)
  local expanded, centZ = expandFace(transformed, p.expansion)
  local projected, minZ, maxZ = projectVerts(expanded, p)

  local nx, ny, nz = 0, 0, 1
  if #expanded >= 3 then
    nx, ny, nz = M.calculateNormal(
      expanded[1].x,
      expanded[1].y,
      expanded[1].z,
      expanded[2].x,
      expanded[2].y,
      expanded[2].z,
      expanded[3].x,
      expanded[3].y,
      expanded[3].z
    )
  end

  -- Get base color from category
  local baseColor = BASE_COLORS[face.c] or BASE_COLORS[3]
  local tint = getTintColor(self, face.c)
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
        math.floor(a)
      ),
    }),
    centroidZ = centZ,
    minZ = minZ,
    maxZ = maxZ,
  })
end

-- Process mesh part
local function processMesh(
  self: Navette,
  vertices: { { number } },
  faces: { { verts: { number }, c: number } },
  p: RenderParams
)
  for _, face in ipairs(faces) do
    processFace(self, vertices, face, p)
  end
end

local function init(self: Navette, context: Context): boolean
  self.autoAngleY = 0
  self.projectedFaces = {}
  return true
end

local function advance(self: Navette, seconds: number): boolean
  self.autoAngleY = self.autoAngleY + seconds * self.rotationSpeed

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
    dist = 8,
    baseBright = self.brightness,
    expansion = self.faceExpansion,
  }

  self.projectedFaces = {}

  -- Process all 4 parts (shared vertex data)
  processMesh(self, NavettePartAData.vertices, NavettePartAData.faces, p)
  processMesh(self, NavettePartBData.vertices, NavettePartBData.faces, p)
  processMesh(self, NavettePartCData.vertices, NavettePartCData.faces, p)
  processMesh(self, NavettePartDData.vertices, NavettePartDData.faces, p)

  -- Sort faces by depth (back to front)
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

local function draw(self: Navette, renderer: Renderer)
  for _, face in ipairs(self.projectedFaces) do
    renderer:drawPath(face.path, face.fillPaint)
  end
end

return function(): Node<Navette>
  return {
    -- Rotation
    rotationSpeed = 0.3,
    scale = 60,
    fov = 120,
    baseRotationX = 15,
    baseRotationY = -30,
    baseRotationZ = 0,
    -- Joystick
    joystickPitch = 0,
    joystickYaw = 0,
    joystickRoll = 0,
    -- Anchor (model center offset)
    baseAnchorX = 0,
    baseAnchorY = 0,
    baseAnchorZ = 0,
    anchorOffsetX = 0,
    anchorOffsetY = 0,
    anchorOffsetZ = 0,
    -- Rendering
    brightness = 0.5,
    faceExpansion = 0.008,
    -- Material colors (from texture palette)
    primaryColor = Color.rgba(200, 110, 170, 255),   -- Pink hull
    secondaryColor = Color.rgba(140, 70, 120, 255),  -- Purple panels
    accentColor = Color.rgba(70, 70, 70, 255),       -- Dark gray
    highlightColor = Color.rgba(120, 120, 120, 255), -- Light gray
    edgeColor = Color.rgba(25, 25, 25, 255),         -- Black
    -- Internal
    autoAngleY = 0,
    projectedFaces = {},
    -- Lifecycle
    init = init,
    advance = advance,
    draw = draw,
  }
end
