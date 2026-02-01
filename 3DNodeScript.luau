--!strict
-- example.luau
-- Main Node Script for animated example 3D model
-- 696 faces total (348 Part A + 348 Part B), 13 bones, swim animation

local SkelAnim = require("SkeletalAnimUtil")
local M = require("Mesh3DUtil")
local PartAData = require("examplePartAData")
local PartBData = require("examplePartBData")

-- Type for skinning entry format
type SkinEntry = { j: { number }, w: { number } }

-- Types
export type ProjectedFace = {
    path: Path,
    depth: number,
    color: Color,
}

export type example = {
    -- Rotation controls
    rotationSpeed: Input<number>,
    baseRotationX: Input<number>,
    baseRotationY: Input<number>,
    baseRotationZ: Input<number>,
    joystickPitch: Input<number>,
    joystickYaw: Input<number>,
    joystickRoll: Input<number>,
    -- Scale and projection
    scale: Input<number>,
    fov: Input<number>,
    cameraDistance: Input<number>,
    usePerspective: Input<boolean>,
    -- Anchor position
    anchorX: Input<number>,
    anchorY: Input<number>,
    anchorZ: Input<number>,
    -- Rendering
    brightness: Input<number>,
    faceExpansion: Input<number>,
    backfaceCulling: Input<boolean>,
    wireframe: Input<boolean>,
    -- Animation controls
    animationEnabled: Input<boolean>,
    animationName: Input<string>,
    animationSpeed: Input<number>,
    -- Material colors
    bottomColor: Input<Color>,
    topColor: Input<Color>,
    -- Internal state
    autoAngleY: number,
    autoScale: number,
    animationTime: number,
    projectedFaces: { ProjectedFace },
    fillPaint: Paint,
    strokePaint: Paint,
    -- Skeletal animation
    skeleton: SkelAnim.Skeleton?,
    currentAnimation: SkelAnim.AnimationClip?,
    animations: { [string]: SkelAnim.AnimationClip }?,
    lastAnimationName: string,
    skinnedVertsA: { { x: number, y: number, z: number } },
    skinnedVertsB: { { x: number, y: number, z: number } },
}

-- Helper functions
local function toRadians(degrees: number): number
    return degrees * math.pi / 180
end

local function getTintColor(self: example, category: number): Color
    if category == 1 then
        return self.bottomColor
    else
        return self.topColor
    end
end

local function project(x: number, y: number, z: number, fov: number, distance: number, usePerspective: boolean): (number, number)
    if usePerspective and distance + z > 0.001 then
        local factor = fov / (distance + z)
        return x * factor, y * factor
    else
        return x, y
    end
end

local function transformVertex(
    vx: number, vy: number, vz: number,
    ax: number, ay: number, az: number,
    cosX: number, sinX: number,
    cosY: number, sinY: number,
    cosZ: number, sinZ: number
): (number, number, number)
    local x, y, z = vx - ax, vy - ay, vz - az
    -- Yaw (Y rotation)
    local rx = x * cosY + z * sinY
    local rz = -x * sinY + z * cosY
    x, z = rx, rz
    -- Pitch (X rotation)
    local ry = y * cosX - z * sinX
    local rz2 = y * sinX + z * cosX
    y, z = ry, rz2
    -- Roll (Z rotation)
    local rx2 = x * cosZ - y * sinZ
    local ry2 = x * sinZ + y * cosZ
    return rx2, ry2, z
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

local function calculateLighting(nx: number, ny: number, nz: number, brightness: number): number
    local lightX, lightY, lightZ = 0.3, -0.5, 0.8
    local len = math.sqrt(lightX * lightX + lightY * lightY + lightZ * lightZ)
    lightX, lightY, lightZ = lightX / len, lightY / len, lightZ / len
    local dot = nx * lightX + ny * lightY + nz * lightZ
    return math.max(brightness, math.min(1.0, brightness + (1 - brightness) * math.max(0, dot)))
end

local function initSkeleton(self: example)
    local skeletonData = (PartAData :: any).skeleton
    if skeletonData then
        local skeleton = SkelAnim.buildSkeleton(skeletonData)
        self.skeleton = skeleton

        local animations = (PartAData :: any).animations :: { [string]: SkelAnim.AnimationClip }?
        if animations then
            self.animations = animations

            -- Print available animations
            print("Available animations:")
            for name, clip in pairs(animations) do
                print("  - " .. name .. " (" .. tostring(clip.duration) .. "s)")
            end

            -- Try to load animation by name from Input, or fallback to first available
            local clip = animations[self.animationName]
            if not clip then
                -- Fallback: try first animation
                for name, c in pairs(animations) do
                    clip = c
                    print("Using default animation: " .. name)
                    break
                end
            end

            if clip then
                self.currentAnimation = clip
                self.lastAnimationName = clip.name
                print("Animation loaded: " .. clip.name)
            end
        end
    end
end

local function updateAnimation(self: example)
    -- Check if animation name changed via Input
    if self.animationName ~= self.lastAnimationName and self.animations then
        local animations = self.animations
        local clip = animations[self.animationName]
        if clip then
            self.currentAnimation = clip
            self.lastAnimationName = self.animationName
            self.animationTime = 0  -- Reset time when changing animation
            print("Animation changed to: " .. clip.name)
        end
    end
end

local function skinVertices(
    skeleton: SkelAnim.Skeleton,
    vertices: { { x: number, y: number, z: number } },
    skinning: { SkinEntry }
): { { x: number, y: number, z: number } }
    local result: { { x: number, y: number, z: number } } = {}

    for i, v in ipairs(vertices) do
        local skin = skinning[i]
        local sx, sy, sz = 0.0, 0.0, 0.0

        for k = 1, 4 do
            local jointIdx = skin.j[k] + 1  -- Convert 0-based to 1-based
            local weight = skin.w[k]

            if weight > 0 and jointIdx >= 1 and jointIdx <= skeleton.jointCount then
                local skinMat = skeleton.skinMatrices[jointIdx]
                if skinMat then
                    local tx, ty, tz = M.mat4TransformPoint(skinMat, v.x, v.y, v.z)
                    sx = sx + tx * weight
                    sy = sy + ty * weight
                    sz = sz + tz * weight
                end
            end
        end

        local vert: { x: number, y: number, z: number } = { x = sx, y = sy, z = sz }
        table.insert(result, vert)
    end

    return result
end

local function processFaces(
    self: example,
    vertices: { { x: number, y: number, z: number } },
    faces: { { verts: { number }, c: number } },
    ax: number, ay: number, az: number,
    cosX: number, sinX: number,
    cosY: number, sinY: number,
    cosZ: number, sinZ: number,
    scaleFactor: number,
    fov: number, cameraDistance: number, usePerspective: boolean,
    brightness: number, faceExpansion: number, backfaceCulling: boolean
)
    for _, face in ipairs(faces) do
        local vertIndices = face.verts
        local category = face.c

        -- Get base color
        local baseColor = getTintColor(self, category)

        -- Transform vertices
        local transformed: { { number } } = {}
        local avgZ = 0

        for _, vi in ipairs(vertIndices) do
            local v = vertices[vi]
            local tx, ty, tz = transformVertex(
                v.x * scaleFactor, v.y * scaleFactor, v.z * scaleFactor,
                ax, ay, az,
                cosX, sinX, cosY, sinY, cosZ, sinZ
            )
            table.insert(transformed, { tx, ty, tz })
            avgZ = avgZ + tz
        end
        avgZ = avgZ / #transformed

        -- Calculate normal for backface culling and lighting
        if #transformed >= 3 then
            local nx, ny, nz = calculateNormal(
                transformed[1][1], transformed[1][2], transformed[1][3],
                transformed[2][1], transformed[2][2], transformed[2][3],
                transformed[3][1], transformed[3][2], transformed[3][3]
            )

            -- Backface culling
            if backfaceCulling and nz < 0 then
                continue
            end

            -- Calculate lighting
            local lightFactor = calculateLighting(nx, ny, nz, brightness)

            -- Apply face expansion
            if faceExpansion > 0 then
                local cx, cy, cz = 0, 0, 0
                for _, t in ipairs(transformed) do
                    cx = cx + t[1]
                    cy = cy + t[2]
                    cz = cz + t[3]
                end
                cx = cx / #transformed
                cy = cy / #transformed
                cz = cz / #transformed

                for _, t in ipairs(transformed) do
                    local dx, dy, dz = t[1] - cx, t[2] - cy, t[3] - cz
                    t[1] = t[1] + dx * faceExpansion
                    t[2] = t[2] + dy * faceExpansion
                    t[3] = t[3] + dz * faceExpansion
                end
            end

            -- Project to 2D
            local projected2D: { { number } } = {}
            for _, t in ipairs(transformed) do
                local px, py = project(t[1], t[2], t[3], fov, cameraDistance, usePerspective)
                table.insert(projected2D, { px, py })
            end

            -- Create lit color
            local r = math.floor(Color.red(baseColor) * lightFactor)
            local g = math.floor(Color.green(baseColor) * lightFactor)
            local b = math.floor(Color.blue(baseColor) * lightFactor)
            local a = Color.alpha(baseColor)
            local litColor = Color.rgba(r, g, b, a)

            -- Build path for this face (created here, not in draw)
            local facePath = Path.new()
            facePath:moveTo(Vector.xy(projected2D[1][1], projected2D[1][2]))
            for idx = 2, #projected2D do
                facePath:lineTo(Vector.xy(projected2D[idx][1], projected2D[idx][2]))
            end
            facePath:close()

            table.insert(self.projectedFaces, {
                path = facePath,
                depth = avgZ,
                color = litColor,
            })
        end
    end
end

-- Lifecycle functions
local function init(self: example, context: Context): boolean
    self.fillPaint = Paint.with({ style = "fill", color = Color.rgb(128, 128, 128) })
    self.strokePaint = Paint.with({ style = "stroke", color = Color.rgb(0, 0, 0), thickness = 1 })

    self.autoAngleY = 0
    self.animationTime = 0
    self.projectedFaces = {}
    self.skinnedVertsA = {}
    self.skinnedVertsB = {}

    -- Calculate auto scale from bounding box (cast data for type safety)
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge

    local vertsA = (PartAData :: any).vertices :: { { x: number, y: number, z: number } }
    local vertsB = (PartBData :: any).vertices :: { { x: number, y: number, z: number } }

    for _, v in ipairs(vertsA) do
        minX = math.min(minX, v.x)
        maxX = math.max(maxX, v.x)
        minY = math.min(minY, v.y)
        maxY = math.max(maxY, v.y)
        minZ = math.min(minZ, v.z)
        maxZ = math.max(maxZ, v.z)
    end
    for _, v in ipairs(vertsB) do
        minX = math.min(minX, v.x)
        maxX = math.max(maxX, v.x)
        minY = math.min(minY, v.y)
        maxY = math.max(maxY, v.y)
        minZ = math.min(minZ, v.z)
        maxZ = math.max(maxZ, v.z)
    end

    local dx, dy, dz = maxX - minX, maxY - minY, maxZ - minZ
    local maxDim = math.max(dx, dy, dz)
    self.autoScale = 200 / maxDim

    -- Initialize skeleton
    initSkeleton(self)

    return true
end

local function advance(self: example, seconds: number): boolean
    -- Auto rotation
    if self.rotationSpeed ~= 0 then
        self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
    end

    -- Check for animation name change
    updateAnimation(self)

    -- Animation
    if self.animationEnabled and self.skeleton and self.currentAnimation then
        local skeleton = self.skeleton
        local clip = self.currentAnimation

        self.animationTime = self.animationTime + seconds * self.animationSpeed
        while self.animationTime > clip.duration do
            self.animationTime = self.animationTime - clip.duration
        end

        SkelAnim.sampleAnimation(skeleton, clip, self.animationTime)
        SkelAnim.updateSkeleton(skeleton)

        -- Skin vertices (cast data through any for type safety)
        local vertsA = (PartAData :: any).vertices :: { { x: number, y: number, z: number } }
        local skinA = (PartAData :: any).skinning :: { SkinEntry }
        local vertsB = (PartBData :: any).vertices :: { { x: number, y: number, z: number } }
        local skinB = (PartBData :: any).skinning :: { SkinEntry }

        self.skinnedVertsA = skinVertices(skeleton, vertsA, skinA)
        self.skinnedVertsB = skinVertices(skeleton, vertsB, skinB)
    else
        -- Use original vertices (cast for type safety)
        self.skinnedVertsA = (PartAData :: any).vertices :: { { x: number, y: number, z: number } }
        self.skinnedVertsB = (PartBData :: any).vertices :: { { x: number, y: number, z: number } }
    end

    -- Clear projected faces
    self.projectedFaces = {}

    -- Calculate rotation angles
    local rotX = toRadians(self.baseRotationX + self.joystickPitch)
    local rotY = toRadians(self.baseRotationY + self.joystickYaw + self.autoAngleY)
    local rotZ = toRadians(self.baseRotationZ + self.joystickRoll)

    local cosX, sinX = math.cos(rotX), math.sin(rotX)
    local cosY, sinY = math.cos(rotY), math.sin(rotY)
    local cosZ, sinZ = math.cos(rotZ), math.sin(rotZ)

    -- Scale factor
    local scaleFactor = self.autoScale * self.scale

    -- Anchor
    local ax = self.anchorX / 100
    local ay = self.anchorY / 100
    local az = self.anchorZ / 100

    -- Rendering params
    local fov = self.fov
    local cameraDistance = self.cameraDistance
    local usePerspective = self.usePerspective
    local brightness = self.brightness / 100
    local faceExpansion = self.faceExpansion
    local backfaceCulling = self.backfaceCulling

    -- Process Part A faces (cast for type safety)
    local facesA = (PartAData :: any).faces :: { { verts: { number }, c: number } }
    processFaces(
        self, self.skinnedVertsA, facesA,
        ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ,
        scaleFactor, fov, cameraDistance, usePerspective,
        brightness, faceExpansion, backfaceCulling
    )

    -- Process Part B faces (cast for type safety)
    local facesB = (PartBData :: any).faces :: { { verts: { number }, c: number } }
    processFaces(
        self, self.skinnedVertsB, facesB,
        ax, ay, az, cosX, sinX, cosY, sinY, cosZ, sinZ,
        scaleFactor, fov, cameraDistance, usePerspective,
        brightness, faceExpansion, backfaceCulling
    )

    -- Sort by depth (manual bubble sort - table.sort with comparator not supported)
    local n = #self.projectedFaces
    for i = 1, n - 1 do
        for j = 1, n - i do
            if self.projectedFaces[j].depth > self.projectedFaces[j + 1].depth then
                self.projectedFaces[j], self.projectedFaces[j + 1] = self.projectedFaces[j + 1], self.projectedFaces[j]
            end
        end
    end

    return true
end

local function draw(self: example, renderer: Renderer)
    for _, face in ipairs(self.projectedFaces) do
        if self.wireframe then
            local strokePaint = Paint.with({ style = "stroke", color = face.color, thickness = 1 })
            renderer:drawPath(face.path, strokePaint)
        else
            local fillPaint = Paint.with({ style = "fill", color = face.color })
            renderer:drawPath(face.path, fillPaint)
        end
    end
end

return function(): Node<example>
    return {
        -- Rotation controls
        rotationSpeed = 0,
        baseRotationX = 0,
        baseRotationY = 0,
        baseRotationZ = 0,
        joystickPitch = 0,
        joystickYaw = 0,
        joystickRoll = 0,
        -- Scale and projection
        scale = 1,
        fov = 800,
        cameraDistance = 400,
        usePerspective = false,
        -- Anchor
        anchorX = 0,
        anchorY = 0,
        anchorZ = 0,
        -- Rendering
        brightness = 30,
        faceExpansion = 0.005,
        backfaceCulling = true,
        wireframe = false,
        -- Animation
        animationEnabled = true,
        animationName = "",
        animationSpeed = 1,
        -- Material colors (Bottom = light gray, Top = dark blue)
        bottomColor = Color.rgba(204, 204, 204, 255),
        topColor = Color.rgba(16, 31, 68, 255),
        -- Internal state
        autoAngleY = 0,
        autoScale = 1,
        animationTime = 0,
        projectedFaces = {},
        fillPaint = late(),
        strokePaint = late(),
        skeleton = nil,
        currentAnimation = nil,
        animations = nil,
        lastAnimationName = "",
        skinnedVertsA = {},
        skinnedVertsB = {},
        -- Lifecycle
        init = init,
        advance = advance,
        draw = draw,
    }
end
