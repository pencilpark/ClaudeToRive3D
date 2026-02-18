#!/usr/bin/env python3
"""
Convert Luau Part data files from table-of-tables format to flat arrays.

Vertices: {x=N, y=N, z=N} → N, N, N,
Faces: {verts = {a, b, c}, c = N} → a, b, c, N,

Preserves everything else (skeleton, skinning, animations) unchanged.
"""

import re
import os
import sys

# Files to convert
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FILES = [
    "PioRobotPartAData.luau",
    "PioRobotPartBData.luau",
    "PioRobotPartCData.luau",
    "RobotPartAData.luau",
    "RobotPartBData.luau",
    "RobotPartCData.luau",
]


def convert_vertices(content):
    """Convert vertices from {x=N, y=N, z=N} to flat N, N, N format."""
    # Pattern to match the entire .vertices = { ... } block
    # Handle both multi-line and single-line formats

    def replace_vertices_block(match):
        full_match = match.group(0)
        prefix = match.group(1)  # e.g., "VarName.vertices = {"
        body = match.group(2)    # everything between { and }

        # Extract all {x=N, y=N, z=N} entries
        vertex_pattern = r'\{x\s*=\s*([^,}]+),\s*y\s*=\s*([^,}]+),\s*z\s*=\s*([^,}]+)\}'
        vertices = re.findall(vertex_pattern, body)

        if not vertices:
            return full_match  # No change if no vertices found

        # Build flat array
        flat_values = []
        for x, y, z in vertices:
            flat_values.extend([x.strip(), y.strip(), z.strip()])

        # Format: wrap at reasonable line length (~120 chars per line)
        lines = []
        current_line = []
        current_len = 0
        for i, val in enumerate(flat_values):
            entry = val + ","
            if current_len + len(entry) + 1 > 120 and current_line:
                lines.append(" ".join(current_line))
                current_line = [entry]
                current_len = len(entry)
            else:
                current_line.append(entry)
                current_len += len(entry) + 1
        if current_line:
            lines.append(" ".join(current_line))

        result = prefix + "\n"
        for line in lines:
            result += "  " + line + "\n"
        result += "}"

        print(f"  Converted {len(vertices)} vertices to flat array ({len(flat_values)} numbers)")
        return result

    # Match: VarName.vertices = { ... }
    # Use a non-greedy approach - find the matching closing brace
    pattern = r'(\w+\.vertices\s*=\s*\{)((?:[^{}]|\{[^{}]*\})*)\}'
    result = re.sub(pattern, replace_vertices_block, content)
    return result


def convert_faces(content):
    """Convert faces from {verts = {a, b, c}, c = N} to flat a, b, c, N format."""

    def replace_faces_block(match):
        full_match = match.group(0)
        prefix = match.group(1)  # e.g., "VarName.faces = {"
        body = match.group(2)    # everything between { and }

        # Extract all {verts = {a, b, c}, c = N} entries
        face_pattern = r'\{verts\s*=\s*\{([^}]+)\},\s*c\s*=\s*(\d+)\}'
        faces = re.findall(face_pattern, body)

        if not faces:
            return full_match  # No change if no faces found

        # Build flat array: v1, v2, v3, c per face
        flat_values = []
        for verts_str, category in faces:
            verts = [v.strip() for v in verts_str.split(",")]
            flat_values.extend(verts)
            flat_values.append(category)

        # Format: wrap at reasonable line length
        lines = []
        current_line = []
        current_len = 0
        for i, val in enumerate(flat_values):
            entry = val + ","
            if current_len + len(entry) + 1 > 120 and current_line:
                lines.append(" ".join(current_line))
                current_line = [entry]
                current_len = len(entry)
            else:
                current_line.append(entry)
                current_len += len(entry) + 1
        if current_line:
            lines.append(" ".join(current_line))

        result = prefix + "\n"
        for line in lines:
            result += "  " + line + "\n"
        result += "}"

        print(f"  Converted {len(faces)} faces to flat array ({len(flat_values)} numbers)")
        return result

    # Match: VarName.faces = { ... } — needs 2 levels of nesting for {verts={...}, c=N}
    pattern = r'(\w+\.faces\s*=\s*\{)((?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*)\}'
    result = re.sub(pattern, replace_faces_block, content)
    return result


def process_file(filepath):
    """Process a single .luau file."""
    print(f"\nProcessing: {os.path.basename(filepath)}")

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    original_size = len(content)

    # Convert vertices
    content = convert_vertices(content)

    # Convert faces
    content = convert_faces(content)

    new_size = len(content)
    savings = original_size - new_size
    pct = (savings / original_size * 100) if original_size > 0 else 0

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"  {original_size:,}B → {new_size:,}B (saved {savings:,}B, {pct:.1f}%)")


def main():
    for fname in FILES:
        filepath = os.path.join(BASE_DIR, fname)
        if os.path.exists(filepath):
            process_file(filepath)
        else:
            print(f"WARNING: {fname} not found, skipping")

    print("\nDone!")


if __name__ == "__main__":
    main()
