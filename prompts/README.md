# Claude Prompts for Blender to Rive Import

This directory contains prompt templates to help you use Claude effectively when importing Blender meshes into Rive.

## Available Prompts

### basic_import.md
For simple mesh imports without textures or animation. Use when you just need to convert vertices and faces.

**When to use:**
- Static geometry
- Simple shapes
- No texture coordinates
- No animations

### uv_mapping.md
For meshes that include texture/UV coordinates.

**When to use:**
- Textured meshes
- Models with UV unwrapping
- Materials that need texture mapping

### animation.md
For animated mesh sequences or vertex animations.

**When to use:**
- Animated meshes
- Morph targets
- Vertex animations
- Frame-by-frame sequences

## How to Use These Prompts

1. **Choose the appropriate prompt** based on your mesh complexity
2. **Fill in your mesh data** in the JSON placeholders
3. **Add specific requirements** in the context sections
4. **Send to Claude** and iterate on the response
5. **Use the generated code** in your Rive project

## Tips for Best Results

- Include actual data samples, not just structure
- Be specific about coordinate system requirements
- Mention any performance constraints
- Specify the target platform (web, mobile, desktop)
- Include error messages if you encounter issues

## Customization

Feel free to modify these prompts to match your specific workflow or combine elements from multiple prompts for complex use cases.
