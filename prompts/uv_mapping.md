# Claude Prompt: Advanced Mesh with UV Mapping

Use this prompt when importing meshes with texture coordinates.

---

I have a Blender mesh with UV coordinates that I need to import into Rive. Here's my data:

```json
{
  "vertices": [
    {"index": 0, "x": 1.0, "y": 1.0, "z": -1.0},
    ...
  ],
  "faces": [
    {"indices": [0, 1, 2], "normal": [0, 0, -1]},
    ...
  ],
  "uv_coords": [
    {"u": 0.0, "v": 0.0},
    {"u": 1.0, "v": 0.0},
    ...
  ]
}
```

Please help me:
1. Convert the coordinate systems appropriately
2. Map UV coordinates to the vertices
3. Generate Rive runtime code that includes texture mapping
4. Ensure the mesh is optimized for rendering

Additional details:
- Texture file: [specify path or URL]
- UV layout: [describe if non-standard]
- Target platform: [specify]
