# Blender to Rive 3D Landscape Export

> **Quick Start:** Run Blender MCP export script → Copy generated `.luau` files to Rive

## ⚠️ IMPORTANT: Read Before Exporting

1. **Static models DON'T need Mesh3DUtil** - All math can be inline
2. **Use category index `c=1`** instead of RGB colors - 60% smaller files
3. **Sort faces by avgZ** at export time for painter's algorithm
4. **Extract only used vertices per part** - Prevents typecheck errors
5. **Blender Z-up**: Yaw rotates in XY plane, NOT around Y axis

## Project Files

```
3D LANDSCAPE/
├── Landscape.luau           # Main Node Script (rendering + Property Group)
├── LandscapePartAData.luau  # Part A: ~1900 faces, ~2500 vertices
├── LandscapePartBData.luau  # Part B: ~1900 faces
├── LandscapePartCData.luau  # Part C: ~1900 faces
├── LandscapePartDData.luau  # Part D: ~1900 faces
├── LandscapePartEData.luau  # Part E: ~1850 faces
├── Mesh3DUtil.luau          # 3D math utilities (ONLY for animated models)
├── SkeletalAnimUtil.luau    # For animated models only
└── CLAUDE.md                # This documentation
```

---

## Critical Lessons Learned (Landscape Export)

### 1. File Size Limits - INCREASED!
- **OLD limit:** 350 polygons, 500 vertices per file (too conservative)
- **NEW limit:** ~1900 polygons, ~2500 vertices per file
- **Why it works:** Using category index `c` instead of RGB colors reduces data size significantly
- **Result:** 9449 faces in just 5 files instead of 27+ files

### 2. Face Data Format (Compact)
```luau
-- ❌ WRONG: Verbose RGB colors
{ verts = { 1, 2, 3 }, color = { 255, 199, 51 } }

-- ✅ CORRECT: Category index (much smaller)
{ verts = { 1, 2, 3 }, c = 1 }
```

### 3. Depth Sorting (Z-Sorting) - CRITICAL
**The painter's algorithm requires faces sorted back-to-front.**

**What works:**
- Sort faces by avgZ (centroid depth) at EXPORT time in Blender
- Runtime bubble sort after transformation for dynamic rotation
- Simple depth comparison: `if faces[j].depth > faces[j + 1].depth then swap`

**What DOESN'T work for complex scenes:**
- BSP trees (static order doesn't work with rotation)
- maxZ sorting (causes terrain to overlap objects)
- Newell's algorithm (too complex, similar results)
- Layer-based sorting (terrain vs objects) - doesn't handle all cases

**Key insight:** For scenes with flat terrain + tall objects, simple avgZ sorting works best when faces are small enough. The terrain being subdivided into many small faces prevents large overlaps.

### 4. Coordinate System (Blender Z-up to Rive)
**Blender uses Z-up, Rive screen is X-right, Y-down, Z-into-screen.**

Rotation mapping:
- `rotationY` (yaw) → Rotate around Blender Z axis (horizontal turntable)
- `rotationX` (pitch) → Tilt forward/backward
- `rotationZ` (roll) → Tilt left/right

```luau
-- Transform for Z-up Blender model
local function transformVertex(vx, vy, vz, ...)
  -- Yaw: rotate in XY plane (Blender Z-up)
  local rx = x * cosY - y * sinY
  local ry = x * sinY + y * cosY
  x, y = rx, ry
  -- Pitch: rotate in YZ plane
  local ry2 = y * cosX - z * sinX
  local rz = y * sinX + z * cosX
  -- ...
end
```

### 5. Material Category Detection (UV-based)
For texture atlas models, use UV coordinates to identify materials:

```python
# In Blender export script
def get_material_category(mat_name, face, uv_layer):
    if "terrain" in mat_name.lower():
        return 1  # Terrain
    elif "road" in mat_name.lower():
        return 2  # Road/River
    elif "prop" in mat_name.lower():
        # Use UV position to differentiate objects
        avg_u, avg_v = get_face_uv(face, uv_layer)
        if avg_u < 0.25 and avg_v > 0.5:
            return 4  # Rocks (high in atlas)
        elif avg_u < 0.25:
            return 6  # Props (low in atlas)
        else:
            return 5  # Cacti/trees
    return 1  # Default
```

### 6. Mesh3DUtil - Optional!
**For static (non-animated) models, Mesh3DUtil is NOT required.**
All necessary functions (transform, project, lighting) can be inline in the Node Script.

Only require Mesh3DUtil if using:
- Matrix operations (mat4)
- Quaternion math
- Skeletal animation

---

## Export Workflow (Blender MCP)

### Step 1: Analyze Model
```python
obj = bpy.data.objects.get("ModelName")
# Check: vertex count, polygon count, materials
```

### Step 2: Normalize Coordinates
```python
# Center and scale to ~200 units
center = (min_coord + max_coord) / 2
scale_factor = 200 / max_dimension
normalized = (world_coord - center) * scale_factor
```

### Step 3: Categorize Materials
```python
# Map materials to category indices 1-6
# Use UV coordinates for texture atlas differentiation
```

### Step 4: Sort Faces by Depth
```python
# Sort by avgZ BEFORE splitting into files
all_faces.sort(key=lambda f: avg_z(f))
```

### Step 5: Fragment with Vertex Optimization
```python
# Each part gets ONLY its used vertices (remapped indices)
def extract_part_data(faces_slice, all_vertices):
    used_indices = set(vi for f in faces_slice for vi in f['verts'])
    index_map = {old: new+1 for new, old in enumerate(sorted(used_indices))}
    # Extract and remap...
```

---

## Property Group (6 Material Colors)

```luau
-- Landscape colors (matching EnvDemo)
terrainColor = Color.rgba(194, 154, 108, 255),   -- Sandy orange ground
roadColor = Color.rgba(45, 85, 160, 255),        -- Blue river
markingsColor = Color.rgba(40, 45, 50, 255),     -- Dark markings
rocksColor = Color.rgba(75, 130, 65, 255),       -- Green rock formations
cactiColor = Color.rgba(55, 115, 50, 255),       -- Green cacti/trees
propsColor = Color.rgba(180, 50, 40, 255),       -- Red props (car)
```

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| Objects behind terrain | Wrong depth sort direction | Use `depth > depth` for back-to-front |
| Model rotates wrong axis | Y-up vs Z-up confusion | Yaw rotates in XY plane for Z-up models |
| Faces disappear | Wrong backface culling | Check normal direction `nz < 0` |
| Colors all same | Not using category index | Use `c = index` format |
| Too many files | Conservative limits | Use ~1900 faces/file with indexed colors |
| Rotation doesn't work | rotationSpeed on wrong axis | Apply to Yaw (XY rotation) not Roll |

---

## Performance Notes

- **9449 faces** renders smoothly with bubble sort
- Bubble sort O(n²) is acceptable for <10k faces
- Each frame: transform → cull → light → project → sort → draw
- Paths created in `advance()`, only drawn in `draw()`

---

## Future Improvements

- [ ] Use insertion sort (faster for nearly-sorted data after rotation)
- [ ] Consider quicksort for >20k faces
- [ ] Add LOD support for distant views
- [ ] Texture sampling from image instead of flat colors

---

## Quick Checklist (Before Starting Export)

- [ ] Model analyzed (vertex/polygon count, materials)
- [ ] Coordinate system identified (Z-up = Blender default)
- [ ] Materials mapped to categories 1-6
- [ ] Using `c=index` format (NOT RGB)
- [ ] Faces will be sorted by avgZ
- [ ] Each part will have only its used vertices
- [ ] `context:markNeedsUpdate()` for auto-rotation

---

## Auto-Rotation Pattern (CRITICAL)

**Problem:** `rotationSpeed` does nothing without waking the render loop.

**Solution:** Store context and call `markNeedsUpdate()`:

```luau
export type Model3D = {
  context: Context?,  -- REQUIRED for auto-rotation
  -- ...
}

local function init(self: Model3D, context: Context): boolean
  self.context = context  -- Store reference
  -- ...
  return true
end

local function advance(self: Model3D, seconds: number): boolean
  if self.rotationSpeed ~= 0 then
    self.autoAngleY = self.autoAngleY + self.rotationSpeed * seconds
    -- Wake render loop for next frame
    if self.context then
      self.context:markNeedsUpdate()
    end
  end
  -- ...
  return true
end
```
