# Claude Prompt: Animation Sequence

Use this prompt for importing animated meshes or mesh sequences.

---

I have a sequence of mesh frames from Blender representing an animation. I need to import this into Rive.

Frame data structure:
```json
{
  "frames": [
    {
      "frame_number": 0,
      "time": 0.0,
      "vertices": [...],
      "faces": [...]
    },
    {
      "frame_number": 1,
      "time": 0.033,
      "vertices": [...],
      "faces": [...]
    },
    ...
  ],
  "fps": 30,
  "total_frames": 120
}
```

Please help me:
1. Create an efficient vertex animation system for Rive
2. Interpolate between keyframes if needed
3. Optimize data by storing only vertex deltas between frames
4. Generate the Rive runtime code for playback

Animation requirements:
- Animation type: [loop/once/ping-pong]
- Duration: [specify in seconds]
- Performance target: [60fps/30fps/etc]
