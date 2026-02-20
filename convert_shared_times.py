#!/usr/bin/env python3
"""
convert_shared_times.py - Factorize duplicate times arrays in Luau animation data files.

Within each animation clip, most channels share the same `times = {...}` array,
but it's duplicated inline for every channel. This script:
  1. Extracts unique time arrays per clip
  2. Creates a `sharedTimes` field with those unique arrays
  3. Replaces each `times = {...}` with `timeRef = N` (1-based index)

Savings: ~10% per animation file.

NOTE: Only needed for Option A (blender_to_rive.py standalone export prior to v6.0).
blender_to_rive.py v6.0+ generates sharedTimes directly.
Option B (Blender MCP single-call) also generates sharedTimes directly.

Idempotent: skips clips that already contain `timeRef`.

Usage:
    python3 convert_shared_times.py                        # Auto-detect *Anim*Data.luau + *Part*Data.luau with animations
    python3 convert_shared_times.py file1.luau file2.luau  # Process specific files
"""

import os
import re
import sys
import glob

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def find_anim_data_files(directory: str) -> list[str]:
    """Auto-detect animation data files.
    Matches *Anim*Data.luau and any *Data.luau that contains '.animations ='."""
    # First: files with 'Anim' in name (always animation data)
    anim_pattern = os.path.join(directory, "*Anim*Data.luau")
    anim_files = set(os.path.basename(f) for f in glob.glob(anim_pattern))

    # Second: check *Part*Data.luau and other *Data.luau files for embedded animations
    data_pattern = os.path.join(directory, "*Data.luau")
    for filepath in glob.glob(data_pattern):
        fname = os.path.basename(filepath)
        if fname in anim_files:
            continue
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                for line in f:
                    if '.animations' in line:
                        anim_files.add(fname)
                        break
        except Exception:
            pass

    return sorted(anim_files)


def find_animations_section(content: str) -> tuple[int, int] | None:
    """Find the start of '.animations = {' and its matching closing brace.
    Returns (start_index, end_index) of the entire animations block, or None."""
    # Match patterns like: VarName.animations = {
    m = re.search(r'\w+\.animations\s*=\s*\{', content)
    if not m:
        return None

    start = m.start()
    brace_start = m.end() - 1  # Position of the opening {

    # Find matching closing brace by counting braces
    depth = 0
    i = brace_start
    while i < len(content):
        ch = content[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return (start, i + 1)
        i += 1

    return None


def find_clips(anim_content: str, anim_offset: int) -> list[dict]:
    """Find all animation clips within the animations block.
    Returns list of dicts with keys: name, start, end (absolute offsets in full content),
    clip_text (the text of the clip)."""
    clips = []

    # Match clip headers like: ["ClipName"] = {  or  ["Name|SubName"] = {
    clip_pattern = re.compile(r'\["([^"]+)"\]\s*=\s*\{')

    for m in clip_pattern.finditer(anim_content):
        clip_name = m.group(1)
        clip_local_start = m.start()
        brace_pos = m.end() - 1  # opening { of this clip

        # Find the matching closing }, counting nested braces
        depth = 0
        i = brace_pos
        while i < len(anim_content):
            ch = anim_content[i]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    # The clip ends at this }
                    # Look for trailing comma
                    clip_local_end = i + 1
                    if clip_local_end < len(anim_content) and anim_content[clip_local_end] == ',':
                        clip_local_end += 1
                    clips.append({
                        'name': clip_name,
                        'local_start': clip_local_start,
                        'local_end': clip_local_end,
                        'abs_start': anim_offset + clip_local_start,
                        'abs_end': anim_offset + clip_local_end,
                        'text': anim_content[clip_local_start:clip_local_end],
                    })
                    break
            i += 1

    return clips


def extract_times_from_clip(clip_text: str) -> list[tuple[int, int, str]]:
    """Find all `times = {<numbers>}` occurrences in a clip.
    Returns list of (start_offset, end_offset, times_content_str) relative to clip_text.
    times_content_str is the content INSIDE the braces (just the numbers)."""
    results = []
    # Match: times = {<numbers, possibly with spaces, dots, minus signs, e notation>}
    # The times array is always on one line within a channel definition
    pattern = re.compile(r'times\s*=\s*\{([^}]+)\}')
    for m in pattern.finditer(clip_text):
        results.append((m.start(), m.end(), m.group(1).strip()))
    return results


def has_timeref(clip_text: str) -> bool:
    """Check if a clip already has timeRef (already converted)."""
    return 'timeRef' in clip_text


def process_clip(clip_text: str) -> tuple[str, int]:
    """Process a single clip: factorize times arrays.
    Returns (new_clip_text, num_unique_times).
    If already converted (has timeRef), returns unchanged."""

    if has_timeref(clip_text):
        return clip_text, 0

    times_occurrences = extract_times_from_clip(clip_text)
    if not times_occurrences:
        return clip_text, 0

    # Deduplicate times by their exact string content
    unique_times_strs = []  # Ordered list of unique time strings
    times_to_ref = {}       # times_content_str -> 1-based ref index

    for _, _, times_str in times_occurrences:
        if times_str not in times_to_ref:
            unique_times_strs.append(times_str)
            times_to_ref[times_str] = len(unique_times_strs)  # 1-based

    # Build the sharedTimes block
    shared_lines = []
    for i, ts in enumerate(unique_times_strs):
        comma = "," if i < len(unique_times_strs) - 1 else ","
        shared_lines.append(f"      {{{ts}}}{comma}")

    shared_block = "    sharedTimes = {\n" + "\n".join(shared_lines) + "\n    },\n"

    # Replace times = {...} with timeRef = N, working from end to start
    # so offsets stay valid
    new_clip = clip_text
    for start, end, times_str in reversed(times_occurrences):
        ref_idx = times_to_ref[times_str]
        new_clip = new_clip[:start] + f"timeRef = {ref_idx}" + new_clip[end:]

    # Insert sharedTimes after the duration line
    # Look for: duration = <number>,
    duration_match = re.search(r'(duration\s*=\s*[\d.]+,?\s*\n)', new_clip)
    if duration_match:
        insert_pos = duration_match.end()
        new_clip = new_clip[:insert_pos] + shared_block + new_clip[insert_pos:]
    else:
        # Fallback: insert after name line
        name_match = re.search(r'(name\s*=\s*"[^"]+",?\s*\n)', new_clip)
        if name_match:
            insert_pos = name_match.end()
            new_clip = new_clip[:insert_pos] + shared_block + new_clip[insert_pos:]

    return new_clip, len(unique_times_strs)


def process_file(filepath: str) -> tuple[int, int]:
    """Process a single file. Returns (original_size, new_size)."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_size = len(content.encode('utf-8'))

    # Find animations section
    anim_bounds = find_animations_section(content)
    if anim_bounds is None:
        print(f"  No animations section found, skipping.")
        return original_size, original_size

    anim_start, anim_end = anim_bounds
    anim_text = content[anim_start:anim_end]

    # The clip offsets are relative to the start of the animations text
    # We need to extract the part after the opening `VarName.animations = {`
    header_match = re.match(r'\w+\.animations\s*=\s*\{', anim_text)
    if not header_match:
        print(f"  Could not parse animations header, skipping.")
        return original_size, original_size

    inner_start = header_match.end()  # position after the opening {
    inner_text = anim_text[inner_start:]

    # Find clips within the inner text
    clips = find_clips(inner_text, 0)

    if not clips:
        print(f"  No animation clips found, skipping.")
        return original_size, original_size

    total_unique = 0
    skipped = 0

    # Process clips from last to first to maintain offsets
    for clip in reversed(clips):
        new_text, num_unique = process_clip(clip['text'])
        if num_unique == 0 and has_timeref(clip['text']):
            skipped += 1
            continue
        if num_unique > 0:
            total_unique += num_unique
            # Replace clip text in inner_text
            inner_text = (
                inner_text[:clip['local_start']]
                + new_text
                + inner_text[clip['local_end']:]
            )

    if total_unique == 0 and skipped > 0:
        print(f"  All {skipped} clips already converted (have timeRef), skipping.")
        return original_size, original_size

    if total_unique == 0:
        print(f"  No times arrays found in clips, skipping.")
        return original_size, original_size

    # Reconstruct the full content
    new_anim_text = anim_text[:inner_start] + inner_text
    # The closing part of animations might have shifted, but since we only replaced
    # clip text within inner_text which is before the closing }, it should be fine.
    # Actually, we need to close the animations block properly.
    # inner_text already contains everything up to the final }
    new_content = content[:anim_start] + new_anim_text + content[anim_end:]

    new_size = len(new_content.encode('utf-8'))

    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(new_content)

    clip_count = len(clips) - skipped
    print(f"  Processed {clip_count} clips, {total_unique} unique time patterns total")
    print(f"  {original_size:,} bytes -> {new_size:,} bytes (saved {original_size - new_size:,} bytes)")

    return original_size, new_size


def main():
    print("=" * 60)
    print("convert_shared_times.py - Factorize duplicate times arrays")
    print("=" * 60)
    print()

    # Use CLI args if provided, otherwise auto-detect
    if len(sys.argv) > 1:
        files = sys.argv[1:]
    else:
        files = find_anim_data_files(BASE_DIR)
        if not files:
            print("No animation data files found in current directory.")
            print("Usage: python3 convert_shared_times.py [file1.luau file2.luau ...]")
            sys.exit(1)

    print(f"Files to process: {files}\n")

    total_before = 0
    total_after = 0

    for filename in files:
        filepath = os.path.join(BASE_DIR, filename) if not os.path.isabs(filename) else filename
        if not os.path.exists(filepath):
            print(f"[SKIP] {filename} - file not found")
            continue

        print(f"[FILE] {os.path.basename(filepath)}")
        before, after = process_file(filepath)
        total_before += before
        total_after += after
        print()

    if total_before > 0:
        print("=" * 60)
        print(f"TOTAL: {total_before:,} bytes -> {total_after:,} bytes")
        print(f"SAVED: {total_before - total_after:,} bytes ({(total_before - total_after) / total_before * 100:.1f}%)")
        print("=" * 60)


if __name__ == "__main__":
    main()
