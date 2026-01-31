--[[
    Gizmo de Rotation 3D pour Rive
    Permet de manipuler les axes X, Y, Z d'un node cible
    Compatible avec databinding et keyframes

    CONFIGURATION:
    1. Databinder rotationX/Y/Z du gizmo vers le ViewModel
    2. Databinder les mêmes propriétés du ViewModel vers target (joystickPitch/Yaw/Roll)
    3. Les keyframes peuvent être ajoutés directement sur rotationX/Y/Z

    UPDATED: Compatible with 3DNodeScript.luau animation system
    - Can control animationEnabled via ViewModel
    - Can control animationSpeed via ViewModel
]]

local AXIS_LENGTH: number = 80
local AXIS_THICKNESS: number = 3
local HANDLE_RADIUS: number = 12
local RING_RADIUS: number = 60
local RING_SEGMENTS: number = 32

-- Couleurs des axes (ARGB)
local COLOR_X: Color = Color.rgba(255, 80, 80, 255)   -- Rouge pour X
local COLOR_Y: Color = Color.rgba(80, 255, 80, 255)   -- Vert pour Y
local COLOR_Z: Color = Color.rgba(80, 80, 255, 255)   -- Bleu pour Z
local COLOR_HIGHLIGHT: Color = Color.rgba(255, 255, 100, 255)
local COLOR_CENTER: Color = Color.rgba(200, 200, 200, 255)

type RotationGizmo3D = {
    -- === PROPRIÉTÉS EXPOSÉES POUR DATABINDING ET KEYFRAMES ===
    -- Ces valeurs sont lues depuis le ViewModel (pour affichage/keyframes)
    rotationX: Input<number>,
    rotationY: Input<number>,
    rotationZ: Input<number>,
    
    -- Sensibilité de rotation (degrés par pixel de drag)
    sensitivity: Input<number>,
    
    -- Visibilité du gizmo
    visible: Input<boolean>,
    
    -- Taille du gizmo (renommé pour éviter conflit avec Node.scale)
    gizmoScale: Input<number>,
    
    -- === ÉTAT INTERNE (non exposé) ===
    pathAxisX: Path,
    pathAxisY: Path,
    pathAxisZ: Path,
    pathRingX: Path,
    pathRingY: Path,
    pathRingZ: Path,
    pathCenter: Path,
    pathHandleX: Path,
    pathHandleY: Path,
    pathHandleZ: Path,
    
    paintX: Paint,
    paintY: Paint,
    paintZ: Paint,
    paintCenter: Paint,
    paintHighlight: Paint,
    
    -- État d'interaction
    activeAxis: string?,
    dragStart: Vector?,
    initialRotation: number,
    
    -- ViewModel properties (pour écriture bidirectionnelle)
    vmRotationX: Property<number>?,
    vmRotationY: Property<number>?,
    vmRotationZ: Property<number>?,
    
    context: Context?,
}

-- Fonction utilitaire pour créer un cercle/anneau
local function createRing(path: Path, radius: number, segments: number, axis: string)
    path:reset()
    local angleStep = (2 * math.pi) / segments
    
    for i = 0, segments do
        local angle = i * angleStep
        local x: number
        local y: number
        
        if axis == "X" then
            -- Anneau dans le plan YZ
            x = math.cos(angle) * radius
            y = math.sin(angle) * radius * 0.3 -- Perspective
        elseif axis == "Y" then
            -- Anneau dans le plan XZ
            x = math.cos(angle) * radius
            y = math.sin(angle) * radius * 0.3
        else -- Z
            -- Anneau dans le plan XY
            x = math.cos(angle) * radius
            y = math.sin(angle) * radius
        end
        
        if i == 0 then
            path:moveTo(Vector.xy(x, y))
        else
            path:lineTo(Vector.xy(x, y))
        end
    end
end

-- Fonction pour créer une poignée circulaire
local function createHandle(path: Path, cx: number, cy: number, radius: number)
    path:reset()
    local c: number = 0.5519150244935105707435627
    
    path:moveTo(Vector.xy(cx + radius, cy))
    path:cubicTo(
        Vector.xy(cx + radius, cy + radius * c),
        Vector.xy(cx + radius * c, cy + radius),
        Vector.xy(cx, cy + radius)
    )
    path:cubicTo(
        Vector.xy(cx - radius * c, cy + radius),
        Vector.xy(cx - radius, cy + radius * c),
        Vector.xy(cx - radius, cy)
    )
    path:cubicTo(
        Vector.xy(cx - radius, cy - radius * c),
        Vector.xy(cx - radius * c, cy - radius),
        Vector.xy(cx, cy - radius)
    )
    path:cubicTo(
        Vector.xy(cx + radius * c, cy - radius),
        Vector.xy(cx + radius, cy - radius * c),
        Vector.xy(cx + radius, cy)
    )
    path:close()
end

-- Fonction pour créer un axe avec flèche
local function createAxis(path: Path, length: number, direction: string)
    path:reset()
    local arrowSize: number = 8
    
    if direction == "X" then
        path:moveTo(Vector.xy(0, 0))
        path:lineTo(Vector.xy(length, 0))
        -- Flèche
        path:moveTo(Vector.xy(length - arrowSize, -arrowSize / 2))
        path:lineTo(Vector.xy(length, 0))
        path:lineTo(Vector.xy(length - arrowSize, arrowSize / 2))
    elseif direction == "Y" then
        path:moveTo(Vector.xy(0, 0))
        path:lineTo(Vector.xy(0, -length))
        -- Flèche
        path:moveTo(Vector.xy(-arrowSize / 2, -length + arrowSize))
        path:lineTo(Vector.xy(0, -length))
        path:lineTo(Vector.xy(arrowSize / 2, -length + arrowSize))
    else -- Z (représenté en diagonale pour la perspective)
        path:moveTo(Vector.xy(0, 0))
        path:lineTo(Vector.xy(length * 0.7, length * 0.7))
        -- Flèche
        local endX = length * 0.7
        local endY = length * 0.7
        path:moveTo(Vector.xy(endX - arrowSize, endY))
        path:lineTo(Vector.xy(endX, endY))
        path:lineTo(Vector.xy(endX, endY - arrowSize))
    end
end

-- Rebuilding des chemins visuels
local function rebuildPaths(self: RotationGizmo3D)
    local s = self.gizmoScale
    
    -- Axes
    createAxis(self.pathAxisX, AXIS_LENGTH * s, "X")
    createAxis(self.pathAxisY, AXIS_LENGTH * s, "Y")
    createAxis(self.pathAxisZ, AXIS_LENGTH * s, "Z")
    
    -- Anneaux de rotation
    createRing(self.pathRingX, RING_RADIUS * s, RING_SEGMENTS, "X")
    createRing(self.pathRingY, RING_RADIUS * s, RING_SEGMENTS, "Y")
    createRing(self.pathRingZ, RING_RADIUS * s, RING_SEGMENTS, "Z")
    
    -- Poignées sur les anneaux
    createHandle(self.pathHandleX, RING_RADIUS * s, 0, HANDLE_RADIUS * s * 0.5)
    createHandle(self.pathHandleY, 0, -RING_RADIUS * s * 0.3, HANDLE_RADIUS * s * 0.5)
    createHandle(self.pathHandleZ, RING_RADIUS * s * 0.7, RING_RADIUS * s * 0.7, HANDLE_RADIUS * s * 0.5)
    
    -- Centre
    createHandle(self.pathCenter, 0, 0, HANDLE_RADIUS * s * 0.4)
end

-- Détection de l'axe sous le pointeur
local function hitTestAxis(self: RotationGizmo3D, pos: Vector): string?
    local s = self.gizmoScale
    local threshold = HANDLE_RADIUS * s
    
    -- Test poignée X
    local handleXPos = Vector.xy(RING_RADIUS * s, 0)
    if pos:distance(handleXPos) < threshold then
        return "X"
    end
    
    -- Test poignée Y
    local handleYPos = Vector.xy(0, -RING_RADIUS * s * 0.3)
    if pos:distance(handleYPos) < threshold then
        return "Y"
    end
    
    -- Test poignée Z
    local handleZPos = Vector.xy(RING_RADIUS * s * 0.7, RING_RADIUS * s * 0.7)
    if pos:distance(handleZPos) < threshold then
        return "Z"
    end
    
    return nil
end

function init(self: RotationGizmo3D, context: Context): boolean
    self.context = context
    
    -- Récupérer les propriétés du ViewModel pour écriture bidirectionnelle
    local vm = context:viewModel()
    if vm then
        self.vmRotationX = vm:getNumber("rotationX")
        self.vmRotationY = vm:getNumber("rotationY")
        self.vmRotationZ = vm:getNumber("rotationZ")
        
        if self.vmRotationX then
            print("[Gizmo] ViewModel rotationX found, initial value:", self.vmRotationX.value)
        else
            print("[Gizmo] WARNING: ViewModel rotationX NOT found!")
        end
    else
        print("[Gizmo] WARNING: No ViewModel found on context!")
    end
    
    -- Initialiser les paints
    self.paintX = Paint.with({ style = "stroke", thickness = AXIS_THICKNESS, color = COLOR_X, cap = "round" })
    self.paintY = Paint.with({ style = "stroke", thickness = AXIS_THICKNESS, color = COLOR_Y, cap = "round" })
    self.paintZ = Paint.with({ style = "stroke", thickness = AXIS_THICKNESS, color = COLOR_Z, cap = "round" })
    self.paintCenter = Paint.with({ style = "fill", color = COLOR_CENTER })
    self.paintHighlight = Paint.with({ style = "fill", color = COLOR_HIGHLIGHT })
    
    -- Construire les chemins initiaux
    rebuildPaths(self)
    
    return true
end

function update(self: RotationGizmo3D)
    rebuildPaths(self)
    if self.context then
        self.context:markNeedsUpdate()
    end
end

function advance(self: RotationGizmo3D, seconds: number): boolean
    return true
end

function draw(self: RotationGizmo3D, renderer: Renderer)
    if not self.visible then
        return
    end
    
    -- Appliquer les rotations actuelles pour la visualisation
    renderer:save()
    
    -- Dessiner les anneaux de rotation
    local ringPaintX = self.paintX:copy({ style = "stroke", thickness = 2 })
    local ringPaintY = self.paintY:copy({ style = "stroke", thickness = 2 })
    local ringPaintZ = self.paintZ:copy({ style = "stroke", thickness = 2 })
    
    -- Highlight l'axe actif
    if self.activeAxis == "X" then
        ringPaintX = ringPaintX:copy({ color = COLOR_HIGHLIGHT, thickness = 4 })
    elseif self.activeAxis == "Y" then
        ringPaintY = ringPaintY:copy({ color = COLOR_HIGHLIGHT, thickness = 4 })
    elseif self.activeAxis == "Z" then
        ringPaintZ = ringPaintZ:copy({ color = COLOR_HIGHLIGHT, thickness = 4 })
    end
    
    -- Dessiner les anneaux
    renderer:drawPath(self.pathRingZ, ringPaintZ)
    renderer:drawPath(self.pathRingY, ringPaintY)
    renderer:drawPath(self.pathRingX, ringPaintX)
    
    -- Dessiner les axes
    renderer:drawPath(self.pathAxisX, self.paintX)
    renderer:drawPath(self.pathAxisY, self.paintY)
    renderer:drawPath(self.pathAxisZ, self.paintZ)
    
    -- Dessiner les poignées
    local fillX = Paint.with({ style = "fill", color = COLOR_X })
    local fillY = Paint.with({ style = "fill", color = COLOR_Y })
    local fillZ = Paint.with({ style = "fill", color = COLOR_Z })
    
    if self.activeAxis == "X" then
        fillX = fillX:copy({ color = COLOR_HIGHLIGHT })
    elseif self.activeAxis == "Y" then
        fillY = fillY:copy({ color = COLOR_HIGHLIGHT })
    elseif self.activeAxis == "Z" then
        fillZ = fillZ:copy({ color = COLOR_HIGHLIGHT })
    end
    
    renderer:drawPath(self.pathHandleX, fillX)
    renderer:drawPath(self.pathHandleY, fillY)
    renderer:drawPath(self.pathHandleZ, fillZ)
    
    -- Dessiner le centre
    renderer:drawPath(self.pathCenter, self.paintCenter)
    
    renderer:restore()
end

function pointerDown(self: RotationGizmo3D, event: PointerEvent)
    print("[Gizmo] === POINTER DOWN ===")
    print("[Gizmo] position:", event.position.x, event.position.y)
    print("[Gizmo] gizmoScale:", self.gizmoScale, "visible:", self.visible)
    
    -- Debug: afficher les positions des poignées attendues
    local s = self.gizmoScale
    print("[Gizmo] Handle X expected at:", RING_RADIUS * s, 0)
    print("[Gizmo] Handle Y expected at:", 0, -RING_RADIUS * s * 0.3)
    print("[Gizmo] Handle Z expected at:", RING_RADIUS * s * 0.7, RING_RADIUS * s * 0.7)
    print("[Gizmo] Hit threshold:", HANDLE_RADIUS * s)
    
    if not self.visible then
        print("[Gizmo] Not visible, ignoring")
        return
    end
    
    local axis = hitTestAxis(self, event.position)
    print("[Gizmo] hitTest result:", axis or "nil")
    
    if axis then
        self.activeAxis = axis
        self.dragStart = event.position
        
        -- Lire la valeur initiale depuis le ViewModel (source de vérité)
        if axis == "X" then
            self.initialRotation = if self.vmRotationX then self.vmRotationX.value else self.rotationX
        elseif axis == "Y" then
            self.initialRotation = if self.vmRotationY then self.vmRotationY.value else self.rotationY
        else
            self.initialRotation = if self.vmRotationZ then self.vmRotationZ.value else self.rotationZ
        end
        
        print("[Gizmo] Captured axis:", axis, "initialRotation:", self.initialRotation)
        event:hit()
    else
        -- Même si on ne touche pas une poignée, on capture pour debug
        print("[Gizmo] No axis hit, but capturing for debug")
        event:hit(true)
    end
end

function pointerMove(self: RotationGizmo3D, event: PointerEvent)
    print("[Gizmo] pointerMove at:", event.position.x, event.position.y, "activeAxis:", self.activeAxis or "nil")
    
    if not self.visible then
        return
    end
    
    -- IMPORTANT: Toujours appeler hit() si on a un axe actif pour capturer le pointer
    if self.activeAxis then
        event:hit()
        
        if self.dragStart then
            local delta = event.position - self.dragStart
            local rotationDelta: number
            local newValue: number
            
            print("[Gizmo] delta:", delta.x, delta.y)
            
            if self.activeAxis == "X" then
                rotationDelta = delta.y * self.sensitivity
                newValue = self.initialRotation + rotationDelta
                -- Écrire dans le ViewModel (propagation vers target)
                if self.vmRotationX then
                    self.vmRotationX.value = newValue
                    print("[Gizmo] vmRotationX.value =", newValue)
                end
                self.rotationX = newValue
            elseif self.activeAxis == "Y" then
                rotationDelta = delta.x * self.sensitivity
                newValue = self.initialRotation + rotationDelta
                -- Écrire dans le ViewModel
                if self.vmRotationY then
                    self.vmRotationY.value = newValue
                    print("[Gizmo] vmRotationY.value =", newValue)
                end
                self.rotationY = newValue
            else -- Z
                rotationDelta = (delta.x + delta.y) * 0.5 * self.sensitivity
                newValue = self.initialRotation + rotationDelta
                -- Écrire dans le ViewModel
                if self.vmRotationZ then
                    self.vmRotationZ.value = newValue
                    print("[Gizmo] vmRotationZ.value =", newValue)
                end
                self.rotationZ = newValue
            end
            
            if self.context then
                self.context:markNeedsUpdate()
            end
        end
    end
end

function pointerUp(self: RotationGizmo3D, event: PointerEvent)
    print("[Gizmo] pointerUp, activeAxis:", self.activeAxis or "nil")
    if self.activeAxis then
        self.activeAxis = nil
        self.dragStart = nil
        event:hit()
    end
end

function pointerExit(self: RotationGizmo3D, event: PointerEvent)
    print("[Gizmo] pointerExit")
    self.activeAxis = nil
    self.dragStart = nil
end

return function(): Node<RotationGizmo3D>
    return {
        -- === PROPRIÉTÉS EXPOSÉES (databinding + keyframes) ===
        -- Ces propriétés apparaissent dans le Property Panel de Rive
        -- et peuvent être databindées au ViewModel "RotationGizmoVM"
        rotationX = 0,      -- Databind vers: RotationGizmoVM.rotationX
        rotationY = 0,      -- Databind vers: RotationGizmoVM.rotationY
        rotationZ = 0,      -- Databind vers: RotationGizmoVM.rotationZ
        sensitivity = 1.0,  -- Databind vers: RotationGizmoVM.sensitivity
        visible = true,     -- Databind vers: RotationGizmoVM.gizmoVisible
        gizmoScale = 1.0,   -- Databind vers: RotationGizmoVM.gizmoScale
        
        -- Chemins pour le rendu (état interne)
        pathAxisX = Path.new(),
        pathAxisY = Path.new(),
        pathAxisZ = Path.new(),
        pathRingX = Path.new(),
        pathRingY = Path.new(),
        pathRingZ = Path.new(),
        pathCenter = Path.new(),
        pathHandleX = Path.new(),
        pathHandleY = Path.new(),
        pathHandleZ = Path.new(),
        
        -- Paints (initialisés dans init)
        paintX = Paint.new(),
        paintY = Paint.new(),
        paintZ = Paint.new(),
        paintCenter = Paint.new(),
        paintHighlight = Paint.new(),
        
        -- État d'interaction
        activeAxis = nil,
        dragStart = nil,
        initialRotation = 0,
        
        -- ViewModel properties (initialisées dans init)
        vmRotationX = nil,
        vmRotationY = nil,
        vmRotationZ = nil,
        
        context = nil,
        
        -- Callbacks du cycle de vie Node
        init = init,
        update = update,
        advance = advance,
        draw = draw,
        pointerDown = pointerDown,
        pointerMove = pointerMove,
        pointerUp = pointerUp,
        pointerExit = pointerExit,
    }
end