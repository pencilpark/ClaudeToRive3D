# RIVE LUAU SCRIPTING — CLAUDE.md

## Identity
AI assistant for Rive scripting in **pure Luau** (no Roblox libraries).
Prioritize working patterns over theoretical completeness.
Always use `--!strict` mode.

---

## Primary Reference (LERP)

**FETCH before starting any Rive scripting session:**
```
https://forge.mograph.life/apps/lerp/quick-reference
https://forge.mograph.life/apps/lerp/api/core-types
https://forge.mograph.life/apps/lerp/api/drawing
```

**FETCH when needed:**
- Complex interactions: `/apps/lerp/rive/environment`
- Lifecycle issues: `/apps/lerp/getting-started/how-rive-scripts-work`
- ViewModels: `/apps/lerp/advanced/viewmodels`
- Procedural graphics: `/apps/lerp/advanced/procedural`

---

## Critical Rules (Non-Negotiable)

### 1. Lifecycle Returns
| Function | Must Return | Meaning |
|----------|-------------|---------|
| `init()` | `true` | Success, continue |
| `init()` | `false` | Failure, script stops |
| `advance()` | `true` | Keep alive, call next frame |
| `advance()` | `false` | Terminate script |

### 2. Input<T> vs Property<T>

| Type | Access | Mutability | Use Case |
|------|--------|------------|----------|
| `Input<T>` | `self.speed` (direct) | Read-only from script | Editor-exposed values |
| `Property<T>` | `prop.value` | Read/write | ViewModel binding |

```luau
-- Input: read directly
local speed = self.speed  -- NOT self.speed.value

-- Property: use .value
local score = scoreProp.value
scoreProp.value = 100
```

### 3. Hit Detection
- `event:hit()` only works inside `pointerDown()` and `pointerUp()`
- Script must be a **direct CHILD** of the hittable shape
- `hit(true)` = translucent (event may propagate)
- `hit()` or `hit(false)` = stops propagation

### 4. Render Loop Wake
- `context:markNeedsUpdate()` wakes the loop when changes happen **outside** `advance()`
- Use it in listeners, callbacks, or async responses
- Store `context` reference in `init()` for later use

### 5. late() Initializer
Use `late()` for properties set in `init()` instead of the factory:
```luau
return function(): Node<MyScript>
    return {
        path = late(),   -- Created in init()
        paint = late(),  -- Created in init()
    }
end
```

---

## Script Types

| Type | Purpose | Has Lifecycle | Returns |
|------|---------|---------------|---------|
| **Node** | Visual behavior, drawing | Yes | Factory `-> Node<T>` |
| **Util** | Reusable modules | No | Module table |
| **Layout** | Flexbox-like components | Yes | Factory `-> Layout<T>` |
| **Converter** | Data transformation | Yes | Factory `-> Converter<T,I,O>` |
| **PathEffect** | Path manipulation | Yes | Factory `-> PathEffect<T>` |

### When to Use Node vs Util
**Node Script:** draws, needs advance(), responds to inputs
**Util Script:** math helpers, shared types, constants, no visual

---

## Lifecycle Order

```
init() → update() → advance() → draw()
         ↑                        |
         └── on Input change ─────┘
```

| Function | When | Purpose |
|----------|------|---------|
| `init(self, context)` | Once at start | Setup, create Path/Paint |
| `update(self)` | Input changes | Rebuild geometry |
| `advance(self, seconds)` | Every frame | Animation, physics |
| `draw(self, renderer)` | Canvas repaint | Render only, no state changes |

---

## Patterns

### Minimal Node Script
```luau
--!strict

export type MyNode = {
    radius: Input<number>,
    path: Path,
    paint: Paint,
}

local function init(self: MyNode, context: Context): boolean
    self.path = Path.new()
    self.paint = Paint.with({ style = "fill", color = Color.rgb(255, 0, 0) })
    return true
end

local function update(self: MyNode)
    -- Rebuild geometry when inputs change
    self.path:reset()
    -- ... rebuild path using self.radius
end

local function advance(self: MyNode, seconds: number): boolean
    return true  -- Keep alive
end

local function draw(self: MyNode, renderer: Renderer)
    renderer:drawPath(self.path, self.paint)
end

return function(): Node<MyNode>
    return {
        radius = 50,
        path = late(),
        paint = late(),
        init = init,
        update = update,
        advance = advance,
        draw = draw,
    }
end
```

---

## 3D Real-Time Rendering

### Blender to Rive Workflow
1. **Analyze model**: Get vertex/polygon count, materials via Blender MCP
2. **Extract materials**: Convert Blender materials → category indices (1-5)
3. **Export geometry**: Vertices as `{ x, y, z }`, faces as `{ verts, c }`
4. **Fragment if needed**: Split at 350 polygon boundary
5. **Generate scripts**: Data Util files + main Node Script
6. **Map colors**: Expose material colors in Property Group

### Data Structure (Optimized)

Face format uses **category index** instead of RGB:
```luau
-- ❌ WRONG: Verbose, requires runtime color detection
{ verts = { 198, 135, 134, 202 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Compact, direct category mapping
{ verts = { 99, 131, 129, 97 }, c = 1 }  -- c = category index
```

### Category Mapping
| Index | Material Type | Example Use |
|-------|--------------|-------------|
| 1 | Primary metal | Blade, hull, main body |
| 2 | Primary wood/organic | Handle, panels, wrap |
| 3 | Secondary dark | Details, shadows, accents |
| 4 | Highlight metal | Guards, trim, highlights |
| 5 | Edge/trim | Edges, borders, pommel |

### Fragmentation Rules
- **Max 350 polygons per data file** (Rive script limit)
- **Max 500 vertices per data file**
- Split into `ModelPartAData.luau`, `ModelPartBData.luau`, etc.
- Main script loads all parts via `require()` and processes sequentially

### CRITICAL: Vertex Optimization per Part
**Problem:** Sharing all vertices across parts causes "Code is too complex to typecheck" error.

```luau
-- ❌ WRONG: Each part contains ALL 1524 vertices (causes typecheck failure)
NavettePartAData.vertices = { ... 1524 vertices ... }  -- 337 faces use only ~440
NavettePartBData.vertices = { ... 1524 vertices ... }  -- 337 faces use only ~470

-- ✅ CORRECT: Each part contains ONLY its used vertices (indices remapped)
NavettePartAData.vertices = { ... 442 vertices ... }   -- Only what Part A needs
NavettePartBData.vertices = { ... 472 vertices ... }   -- Only what Part B needs
```

**Solution:** When fragmenting, extract only the vertices used by each part and remap face indices:

```python
# Blender export algorithm
def extract_used_vertices(faces, all_vertices):
    # 1. Collect used vertex indices from faces
    used_indices = set()
    for face in faces:
        for v in face["verts"]:
            used_indices.add(v)

    # 2. Create old→new index mapping (1-based for Luau)
    sorted_indices = sorted(used_indices)
    index_map = {old: new + 1 for new, old in enumerate(sorted_indices)}

    # 3. Extract only used vertices
    extracted = [all_vertices[i - 1] for i in sorted_indices]

    # 4. Remap face indices
    remapped_faces = []
    for face in faces:
        new_verts = [index_map[v] for v in face["verts"]]
        remapped_faces.append({"verts": new_verts, "c": face["c"]})

    return extracted, remapped_faces
```

**Result:** ~60% reduction in file size, typecheck passes

### Required Files Structure
```
Model.luau           -- Main Node Script (rendering + Property Group)
ModelPartAData.luau  -- Util: vertices + faces (≤350 polygons)
ModelPartBData.luau  -- Util: vertices + faces (≤350 polygons)
Mesh3DUtil.luau      -- Util: shared 3D math functions
```

### Property Group Template (3D Node Script)
```luau
export type Model3D = {
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
  -- Anchor position
  baseAnchorX: Input<number>,
  baseAnchorY: Input<number>,
  baseAnchorZ: Input<number>,
  anchorOffsetX: Input<number>,
  anchorOffsetY: Input<number>,
  anchorOffsetZ: Input<number>,
  -- Rendering
  brightness: Input<number>,
  faceExpansion: Input<number>,
  -- Material colors (one Input<Color> per category)
  primaryColor: Input<Color>,    -- c=1
  secondaryColor: Input<Color>,  -- c=2
  accentColor: Input<Color>,     -- c=3
  highlightColor: Input<Color>,  -- c=4
  edgeColor: Input<Color>,       -- c=5
  -- Internal state
  autoAngleY: number,
  projectedFaces: { ProjectedFace },
}
```

### Color Mapping Function
```luau
local function getTintColor(self: Model3D, category: number): Color
  if category == 1 then return self.primaryColor end
  if category == 2 then return self.secondaryColor end
  if category == 3 then return self.accentColor end
  if category == 4 then return self.highlightColor end
  if category == 5 then return self.edgeColor end
  return self.primaryColor  -- fallback
end
```

### Common 3D Export Pitfalls
| Issue | Cause | Solution |
|-------|-------|----------|
| Faces manquantes | Wrong winding order | Reverse vertex order in transformFaceVerts |
| Couleurs incorrectes | Using RGB instead of category | Use `c = index` format in face data |
| Script trop lourd | >350 polygons | Fragment into multiple data files |
| Z-fighting | Faces at same depth | Adjust `faceExpansion` parameter |
| Model offset | Wrong anchor point | Adjust `baseAnchorX/Y/Z` values |
| **"Code too complex to typecheck"** | **Shared vertices across all parts** | **Extract only used vertices per part + remap indices** |

### Mesh3DUtil Functions (Reference)
```luau
M.toRadians(degrees)                    -- Convert to radians
M.project(x, y, z, fov, dist)           -- Perspective projection
M.calculateNormal(x1,y1,z1, x2,y2,z2, x3,y3,z3)  -- Face normal
M.calculateLighting(nx, ny, nz, base)   -- Diffuse lighting
M.transformVertex(vx,vy,vz, ax,ay,az, cosX,sinX, cosY,sinY, cosZ,sinZ)
```

---

### Interactive with Hit Detection
```luau
--!strict

export type Button = {
    isPressed: boolean,
    context: Context?,
    path: Path,
    paint: Paint,
}

local function init(self: Button, context: Context): boolean
    self.context = context
    self.path = Path.new()
    self.paint = Paint.with({ style = "fill", color = Color.rgb(80, 140, 220) })
    -- Build initial path...
    return true
end

local function pointerDown(self: Button, event: PointerEvent)
    if event:hit() then
        self.isPressed = true
        self.paint = Paint.with({ style = "fill", color = Color.rgb(60, 120, 200) })
    end
end

local function pointerUp(self: Button, event: PointerEvent)
    if event:hit() then
        self.isPressed = false
        self.paint = Paint.with({ style = "fill", color = Color.rgb(80, 140, 220) })
    end
end

local function draw(self: Button, renderer: Renderer)
    renderer:drawPath(self.path, self.paint)
end

return function(): Node<Button>
    return {
        isPressed = false,
        context = nil,
        path = late(),
        paint = late(),
        init = init,
        pointerDown = pointerDown,
        pointerUp = pointerUp,
        draw = draw,
    }
end
```

### ViewModel Listener with markNeedsUpdate
```luau
--!strict

export type ReactiveNode = {
    context: Context?,
    score: number,
    scoreProp: Property<number>?,
}

local function init(self: ReactiveNode, context: Context): boolean
    self.context = context

    local vm = context:viewModel()
    if vm then
        local prop = vm:getNumber("score")
        if prop then
            self.scoreProp = prop
            self.score = prop.value

            prop:addListener(function()
                self.score = prop.value
                -- Wake render loop (we're outside advance)
                if self.context then
                    self.context:markNeedsUpdate()
                end
            end)
        end
    end

    return true
end

local function advance(self: ReactiveNode, seconds: number): boolean
    return true
end

return function(): Node<ReactiveNode>
    return {
        context = nil,
        score = 0,
        scoreProp = nil,
        init = init,
        advance = advance,
    }
end
```

### State Machine Pattern
```luau
--!strict

export type ButtonState = "idle" | "hover" | "pressed"

export type StatefulButton = {
    state: ButtonState,
    targetScale: number,
    paint: Paint,
}

local SCALE: { [ButtonState]: number } = {
    idle = 1.0,
    hover = 1.1,
    pressed = 0.95,
}

local COLOR: { [ButtonState]: Color } = {
    idle = Color.rgb(80, 140, 220),
    hover = Color.rgb(100, 160, 240),
    pressed = Color.rgb(60, 120, 200),
}

local function setState(self: StatefulButton, newState: ButtonState)
    self.state = newState
    self.targetScale = SCALE[newState]
    self.paint = Paint.with({ style = "fill", color = COLOR[newState] })
end
```

### Util Script (Module)
```luau
--!strict
-- File: Easing.lua (Util Script)

local Easing = {}

function Easing.lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

function Easing.easeInQuad(t: number): number
    return t * t
end

function Easing.easeOutQuad(t: number): number
    return 1 - (1 - t) * (1 - t)
end

function Easing.easeInOutQuad(t: number): number
    if t < 0.5 then
        return 2 * t * t
    else
        return 1 - ((-2 * t + 2) ^ 2) / 2
    end
end

return Easing

-- Usage in Node script:
-- local Easing = require("Easing")
-- local eased = Easing.easeInOutQuad(t)
```

---

## API Quick Reference

### Constructors
```luau
Vector.xy(x, y)              -- 2D vector (alias: Vec2D)
Vector.origin()              -- (0, 0)
Path.new()                   -- Empty path
Paint.new()                  -- Default paint
Paint.with({ ... })          -- Paint with options
Color.rgb(r, g, b)           -- Opaque (0-255 each)
Color.rgba(r, g, b, a)       -- With alpha
Mat2D.identity()
Mat2D.withTranslation(x, y)
Mat2D.withRotation(radians)
Mat2D.withScale(sx, sy)
Gradient.linear(from, to, stops)
Gradient.radial(center, radius, stops)
```

### Color (Static Accessors)
```luau
-- Get channel
Color.red(c)      -- returns number
Color.green(c)
Color.blue(c)
Color.alpha(c)    -- 0-255
Color.opacity(c)  -- 0.0-1.0

-- Set channel (returns NEW color)
Color.red(c, 128)     -- new color with red=128
Color.opacity(c, 0.5) -- new color with 50% opacity

-- Interpolate
Color.lerp(from, to, t)
```

### Paint Options
```luau
Paint.with({
    style = "fill" | "stroke",
    color = Color.rgb(255, 0, 0),
    thickness = 2,              -- stroke only
    cap = "butt" | "round" | "square",
    join = "miter" | "round" | "bevel",
    blendMode = "srcOver" | "multiply" | ...,
    gradient = Gradient.linear(...),
    feather = 0,
})

-- Copy with overrides
local highlight = basePaint:copy({ color = Color.rgb(255, 255, 0) })
```

### Path Methods
```luau
path:moveTo(Vector)
path:lineTo(Vector)
path:quadTo(control, to)
path:cubicTo(ctrlOut, ctrlIn, to)
path:close()
path:reset()                    -- Clear (don't call in draw!)
path:add(otherPath, transform?)
path:measure() -> PathMeasure
path:contours() -> ContourMeasure?
#path                           -- Command count
```

### PathMeasure
```luau
measure.length                  -- Total length
measure.isClosed                -- Single closed contour?
measure:positionAndTangent(distance) -> (Vector, Vector)
measure:warp(point)             -- X=distance along, Y=perpendicular offset
measure:extract(start, end, destPath, startWithMove?)
```

### Vector Operations
```luau
v.x, v.y                        -- Components (read-only)
v[1], v[2]                      -- Index access
v:length()
v:lengthSquared()               -- Faster for comparisons
v:normalized()
v:distance(other)
v:distanceSquared(other)
v:dot(other)
v:lerp(other, t)

-- Operators
v1 + v2, v1 - v2
v * scalar, v / scalar
-v                              -- Negation
v1 == v2
```

### Mat2D
```luau
mat.xx, mat.xy, mat.yx, mat.yy  -- Scale/rotation
mat.tx, mat.ty                  -- Translation
mat:invert() -> Mat2D?
mat:isIdentity() -> boolean
mat * vector                    -- Transform point
mat1 * mat2                     -- Combine (mat2 first, then mat1)
```

### Renderer
```luau
renderer:drawPath(path, paint)
renderer:drawImage(image, sampler, blendMode, opacity)
renderer:save()                 -- Push state
renderer:restore()              -- Pop state (MUST pair with save!)
renderer:transform(mat)
renderer:clipPath(path)
```

### ViewModel Access
```luau
local vm = context:viewModel()
vm:getNumber("name")    -> Property<number>?
vm:getString("name")    -> Property<string>?
vm:getBoolean("name")   -> Property<boolean>?
vm:getColor("name")     -> Property<Color>?
vm:getTrigger("name")   -> PropertyTrigger?
vm:getList("name")      -> PropertyList?
vm:getEnum("name")      -> PropertyEnum?

-- Property usage
prop.value              -- get/set
prop:addListener(fn)
prop:removeListener(fn)

-- Trigger
trigger:fire()
trigger:addListener(fn)
```

### PointerEvent
```luau
event.position          -- Vector (local coords)
event.id                -- Pointer ID (multitouch)
event:hit()             -- Consume, stop propagation
event:hit(true)         -- Translucent, may continue

-- Forward to nested artboard
local childEvent = PointerEvent.new(event.id, transformedPos)
```

---

## Performance Rules

### DO
- Create Path/Paint **once** in `init()`
- Rebuild geometry in `update()` using `path:reset()`
- Keep `draw()` lightweight (render only)
- Reuse objects, pool particles
- Use `lengthSquared()` for distance comparisons

### DON'T
- Allocate in `draw()` or tight loops
- `print()` in loops
- Define functions inside lifecycle callbacks
- Create unbounded tables (lists that only grow)

```luau
-- BAD: allocation every frame
function draw(self, renderer)
    local path = Path.new()  -- NO!
end

-- GOOD: reuse
function draw(self, renderer)
    renderer:drawPath(self.path, self.paint)
end
```

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `advance()` returns nothing | Always `return true` or `false` |
| `event.hit` | Use `event:hit()` (method call) |
| Script not child of shape | Hierarchy matters for hit detection |
| Using `self.input.value` | `Input<T>` reads directly: `self.input` |
| Forgetting `markNeedsUpdate()` | Call it in listeners/callbacks |
| Unbalanced `save()`/`restore()` | Always pair them |
| Color via `c.red` | Use `Color.red(c)` (static) |

---

## Anti-Patterns

### Mixing Concerns
```luau
-- BAD: helpers inside lifecycle
function advance(self, seconds)
    local function lerp(a, b, t)  -- Recreated every frame!
        return a + (b - a) * t
    end
end

-- GOOD: use Util script or local at module level
local function lerp(a, b, t)
    return a + (b - a) * t
end
```

### God Util Scripts
```luau
-- BAD: one massive Utils.lua with everything
-- GOOD: separate by domain (Easing.lua, Colors.lua, Math.lua)
```

### Circular Dependencies
```luau
-- BAD: A requires B, B requires A
-- GOOD: extract shared code to third module
```

---

## Tests Pattern
```luau
--!strict

function setup(test: Tester)
    test.group("Math operations", function()
        test.case("lerp works", function(expect)
            expect(lerp(0, 100, 0.5)).is(50)
        end)

        test.case("comparisons", function(expect)
            expect(5).greaterThan(3)
            expect(2).lessThanOrEqual(2)
            expect(1).never.is(2)
        end)
    end)
end

return function(): Tests
    return setup
end
```

---

## Rive MCP Tools (if connected)

| Tool | Purpose |
|------|---------|
| `text_editor` | View/edit scripts |
| `script_diagnostics` | Linting |
| `compile_script` | Apply to VM |
| `read_console` | Debug output |
| `animation_editor` | Animations |
| `layout_editor` | Flexbox |
| `viewmodel_editor` | Data binding |

**Workflow:** Create or Edit → Diagnostics → Compile → Debug
