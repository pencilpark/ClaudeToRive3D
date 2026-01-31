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
-- Now preserves alpha from tintColor for RGBA support
function Mesh3DUtil.mapColorWithTint(
  baseR: number,
  baseG: number,
  baseB: number,
  baseA: number,
  tintColor: Color
): (number, number, number, number)
  local intensity = (baseR + baseG + baseB) / (255 * 3)
  -- Use alpha from tintColor (Property Group) for transparency support
  local alpha = Color.alpha(tintColor)
  return Color.red(tintColor) * intensity,
    Color.green(tintColor) * intensity,
    Color.blue(tintColor) * intensity,
    alpha
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

-- ============================================================================
-- Matrix Math for Skeletal Animation (column-major 4x4)
-- ============================================================================

-- Type aliases for clarity
export type Mat4 = { number } -- 16 floats, column-major
export type Vec3 = { number } -- 3 floats: x, y, z
export type Quat = { number } -- 4 floats: x, y, z, w

-- Create identity matrix
function Mesh3DUtil.mat4Identity(): Mat4
  return {
    1, 0, 0, 0, -- column 0
    0, 1, 0, 0, -- column 1
    0, 0, 1, 0, -- column 2
    0, 0, 0, 1, -- column 3
  }
end

-- Multiply two 4x4 matrices: result = a * b
function Mesh3DUtil.mat4Multiply(a: Mat4, b: Mat4): Mat4
  local result: Mat4 = {}
  for col = 0, 3 do
    for row = 0, 3 do
      local sum = 0
      for k = 0, 3 do
        sum = sum + a[row + k * 4 + 1] * b[k + col * 4 + 1]
      end
      result[row + col * 4 + 1] = sum
    end
  end
  return result
end

-- Create rotation matrix from quaternion (x, y, z, w)
function Mesh3DUtil.mat4FromQuat(q: Quat): Mat4
  local x, y, z, w = q[1], q[2], q[3], q[4]
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z

  return {
    1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0,
    2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0,
    2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0,
    0, 0, 0, 1,
  }
end

-- Compose TRS into matrix: T * R * S
function Mesh3DUtil.mat4FromTRS(t: Vec3, r: Quat, s: Vec3): Mat4
  local rotMat = Mesh3DUtil.mat4FromQuat(r)
  return {
    rotMat[1] * s[1], rotMat[2] * s[1], rotMat[3] * s[1], 0,
    rotMat[5] * s[2], rotMat[6] * s[2], rotMat[7] * s[2], 0,
    rotMat[9] * s[3], rotMat[10] * s[3], rotMat[11] * s[3], 0,
    t[1], t[2], t[3], 1,
  }
end

-- Transform a point by a matrix
function Mesh3DUtil.mat4TransformPoint(m: Mat4, x: number, y: number, z: number): (number, number, number)
  local w = m[4] * x + m[8] * y + m[12] * z + m[16]
  local invW = 1 / w
  return (m[1] * x + m[5] * y + m[9] * z + m[13]) * invW,
    (m[2] * x + m[6] * y + m[10] * z + m[14]) * invW,
    (m[3] * x + m[7] * y + m[11] * z + m[15]) * invW
end

-- ============================================================================
-- Quaternion Math
-- ============================================================================

-- Normalize quaternion
function Mesh3DUtil.quatNormalize(q: Quat): Quat
  local len = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
  if len < 0.00001 then
    return { 0, 0, 0, 1 }
  end
  local invLen = 1 / len
  return { q[1] * invLen, q[2] * invLen, q[3] * invLen, q[4] * invLen }
end

-- Spherical linear interpolation
function Mesh3DUtil.quatSlerp(a: Quat, b: Quat, t: number): Quat
  local dot = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
  local bx, by, bz, bw = b[1], b[2], b[3], b[4]

  if dot < 0 then
    dot = -dot
    bx, by, bz, bw = -bx, -by, -bz, -bw
  end

  if dot > 0.9995 then
    return Mesh3DUtil.quatNormalize({
      a[1] + t * (bx - a[1]),
      a[2] + t * (by - a[2]),
      a[3] + t * (bz - a[3]),
      a[4] + t * (bw - a[4]),
    })
  end

  dot = math.min(1, math.max(-1, dot))
  local theta = math.acos(dot)
  local sinTheta = math.sin(theta)
  local s0 = math.sin((1 - t) * theta) / sinTheta
  local s1 = math.sin(t * theta) / sinTheta

  return { s0 * a[1] + s1 * bx, s0 * a[2] + s1 * by, s0 * a[3] + s1 * bz, s0 * a[4] + s1 * bw }
end

-- ============================================================================
-- Vector Math
-- ============================================================================

function Mesh3DUtil.vec3Lerp(a: Vec3, b: Vec3, t: number): Vec3
  return {
    a[1] + t * (b[1] - a[1]),
    a[2] + t * (b[2] - a[2]),
    a[3] + t * (b[3] - a[3]),
  }
end

return Mesh3DUtil
