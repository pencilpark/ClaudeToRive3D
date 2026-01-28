--!strict
-- Mesh3DUtil - Utility functions for 3D mesh rendering in Rive

local Mesh3DUtil = {}

-- Convert degrees to radians
function Mesh3DUtil.toRadians(degrees: number): number
  return degrees * math.pi / 180
end

-- Perspective projection
function Mesh3DUtil.project(
  x: number,
  y: number,
  z: number,
  fov: number,
  distance: number
): (number, number)
  local factor = fov / (distance + z)
  return x * factor, y * factor
end

-- Calculate face normal from 3 vertices
function Mesh3DUtil.calculateNormal(
  x1: number,
  y1: number,
  z1: number,
  x2: number,
  y2: number,
  z2: number,
  x3: number,
  y3: number,
  z3: number
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

-- Calculate lighting brightness from normal
function Mesh3DUtil.calculateLighting(
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

-- Transform vertex with rotation (Blender -> Rive coords)
function Mesh3DUtil.transformVertex(
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
  local x, y, z = vx - ax, vy - ay, vz - az
  -- Yaw
  local nx = x * cosY - y * sinY
  local ny = x * sinY + y * cosY
  x, y = nx, ny
  -- Pitch
  local ny2 = y * cosX - z * sinX
  local nz = y * sinX + z * cosX
  y, z = ny2, nz
  -- Roll
  local nx2 = x * cosZ - z * sinZ
  local nz2 = x * sinZ + z * cosZ
  -- Screen coords: X=right, Y=up(Z), Z=depth(Y)
  return nx2, nz2, y
end

-- Map base color to tinted color with intensity
function Mesh3DUtil.mapColorWithTint(
  baseR: number,
  baseG: number,
  baseB: number,
  baseA,
  tintColor: Color
): (number, number, number, number)
  local intensity = (baseR + baseG + baseB) / (255 * 3)
  -- local returnAlpha
  -- if baseA >= 10 then
  --   returnAlpha = 255
  -- else
  --   returnAlpha = 255
  -- end
  return Color.red(tintColor) * intensity,
    Color.green(tintColor) * intensity,
    Color.blue(tintColor) * intensity,
    255
end

-- Detect color category from RGB values
function Mesh3DUtil.detectColorCategory(
  r: number,
  g: number,
  b: number,
  a: number
): string
  if r > 150 and g > 100 and b < 50 then
    return 'panel'
  end
  if r > 130 and g > 90 and b > 50 and b < 100 then
    return 'secondary'
  end
  if r > 190 and g < 100 then
    return 'accent'
  end
  if r > 100 and g < 80 and b < 60 then
    return 'hull'
  end
  if g > r and g > 80 then
    return 'detail'
  end
  if r < 50 and g < 50 and b < 50 then
    return 'dark'
  end
  if r > 100 and g > 100 and b > 100 then
    return 'metal'
  end
  return 'hull'
end

return Mesh3DUtil
