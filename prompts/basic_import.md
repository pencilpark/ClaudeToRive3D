# Claude Prompt: Basic Mesh Import

Use this prompt when asking Claude to help import a simple Blender mesh into Rive.

---

I have exported mesh data from Blender and need to import it into Rive. Here's my mesh data:

```json
{
  "vertices": [
    {"index": 0, "x": 1.0, "y": 1.0, "z": -1.0},
    {"index": 1, "x": 1.0, "y": -1.0, "z": -1.0},
    ...
  ],
  "faces": [
    {"indices": [0, 1, 2], "normal": [0, 0, -1]},
    ...
  ]
}
```

Please help me:
1. Convert this to Rive's coordinate system (if different from Blender's Z-up right-handed system)
2. Generate the code to create vertices and faces in Rive runtime
3. Optimize the mesh by removing any duplicate vertices

Additional context:
- Target runtime: [specify: web/iOS/Android/desktop]
- Performance requirements: [specify any constraints]
- Any special transformations needed: [specify]
