#!/usr/bin/env python3
"""
ASS subtitle overlap detector and fixer.

Detects accidental overlapping dialogue events (those that are not
intentionally simultaneous according to the rules) and optionally
fixes them interactively by truncating lead-out/lead-in times
while preserving at least 200 ms of display duration.

Usage:
    ass_overlap_fixer.py [ -i ] <file.ass> [<file2.ass> ...]
    ass_overlap_fixer.py -    (read from stdin, output to stdout)
    ass_overlap_fixer.py      (print this help)

No dependencies beyond the Python standard library.
"""

import sys
import re
import copy

# ----------------------------------------------------------------------
# Time handling
# ----------------------------------------------------------------------

def parse_ass_time(t):
    """Convert ASS timestamp 'h:mm:ss.cc' to milliseconds."""
    m = re.match(r'(\d+):(\d{2}):(\d{2})\.(\d{2})', t)
    if not m:
        raise ValueError(f"Invalid ASS timestamp: {t}")
    h, mm, ss, cs = map(int, m.groups())
    return (h * 3600 + mm * 60 + ss) * 1000 + cs * 10


def format_ass_time(ms):
    """Convert milliseconds to ASS timestamp 'h:mm:ss.cc'."""
    ms = int(ms)
    h = ms // 3600000
    ms %= 3600000
    mm = ms // 60000
    ms %= 60000
    ss = ms // 1000
    cs = (ms % 1000) // 10
    return f"{h}:{mm:02d}:{ss:02d}.{cs:02d}"


# ----------------------------------------------------------------------
# Overlap detection
# ----------------------------------------------------------------------

def is_intentional_overlap(d1, d2, overlap):
    """
    Return True if the overlap should be considered intentional,
    i.e. it is either longer than 500 ms OR it is at least 300 ms
    and at least 20% of each dialogue's total duration.
    """
    if overlap > 500:
        return True
    if overlap >= 300 and overlap >= 0.2 * d1 and overlap >= 0.2 * d2:
        return True
    return False


def find_overlap_groups(dialogues):
    """
    Find connected components of accidental overlaps.
    Each dialogue is a dict with at least 'start', 'end', 'style'.
    Returns a list of lists (groups) of dialogue dicts.
    """
    n = len(dialogues)
    # Build adjacency list for accidental overlaps
    adj = [[] for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            d1 = dialogues[i]
            d2 = dialogues[j]
            if d1['style'] != d2['style']:
                continue
            start = max(d1['start'], d2['start'])
            end = min(d1['end'], d2['end'])
            if start < end:
                overlap = end - start
                dur1 = d1['end'] - d1['start']
                dur2 = d2['end'] - d2['start']
                if not is_intentional_overlap(dur1, dur2, overlap):
                    adj[i].append(j)
                    adj[j].append(i)

    visited = [False] * n
    groups = []
    for i in range(n):
        if not visited[i]:
            # BFS to find component
            stack = [i]
            visited[i] = True
            component = []
            while stack:
                node = stack.pop()
                component.append(dialogues[node])
                for nb in adj[node]:
                    if not visited[nb]:
                        visited[nb] = True
                        stack.append(nb)
            if len(component) > 1:  # only groups with actual overlap
                # Sort by start time for consistent output
                component.sort(key=lambda d: d['start'])
                groups.append(component)
    return groups


# ----------------------------------------------------------------------
# Fixing logic (two strategies)
# ----------------------------------------------------------------------

def fix_group_default(group):
    """
    Adjust times to remove overlaps, preferring to truncate lead-out
    of the preceding dialogue first, then lead-in of the following.
    Always keep at least 200 ms duration.
    """
    group.sort(key=lambda d: d['start'])
    changed = True
    max_passes = 10  # avoid infinite loop due to min durations
    while changed and max_passes > 0:
        changed = False
        max_passes -= 1
        for i in range(len(group) - 1):
            a = group[i]
            b = group[i + 1]
            if a['end'] > b['start']:
                overlap = a['end'] - b['start']
                # 1) truncate end of a
                a_dur = a['end'] - a['start']
                cut_a = min(overlap, a_dur - 200)
                if cut_a > 0:
                    a['end'] -= cut_a
                    overlap -= cut_a
                    changed = True
                # 2) if still overlapping, truncate start of b
                if overlap > 0:
                    b_dur = b['end'] - b['start']
                    cut_b = min(overlap, b_dur - 200)
                    if cut_b > 0:
                        b['start'] += cut_b
                        changed = True
    return group


def fix_group_alt(group):
    """
    Adjust times to remove overlaps, preferring to truncate lead-in
    of the succeeding dialogue first, then lead-out of the preceding.
    Always keep at least 200 ms duration.
    """
    group.sort(key=lambda d: d['start'])
    changed = True
    max_passes = 10
    while changed and max_passes > 0:
        changed = False
        max_passes -= 1
        for i in range(len(group) - 1):
            a = group[i]
            b = group[i + 1]
            if a['end'] > b['start']:
                overlap = a['end'] - b['start']
                # 1) truncate start of b
                b_dur = b['end'] - b['start']
                cut_b = min(overlap, b_dur - 200)
                if cut_b > 0:
                    b['start'] += cut_b
                    overlap -= cut_b
                    changed = True
                # 2) if still overlapping, truncate end of a
                if overlap > 0:
                    a_dur = a['end'] - a['start']
                    cut_a = min(overlap, a_dur - 200)
                    if cut_a > 0:
                        a['end'] -= cut_a
                        changed = True
    return group


# ----------------------------------------------------------------------
# ASS file parsing and writing
# ----------------------------------------------------------------------

def parse_ass(content):
    """
    Parse ASS file content.
    Returns (lines, dialogues) where:
        lines: list of all lines (strings)
        dialogues: list of dicts with keys:
            'line_index': index in lines
            'fields': list of comma-separated fields of the Dialogue line
            'start': start time in ms
            'end': end time in ms
            'style': style name
            'text': dialogue text
    """
    lines = content.splitlines()
    dialogues = []
    for i, line in enumerate(lines):
        if line.startswith("Dialogue:"):
            # Split with maxsplit=9 to keep Text together
            parts = line[len("Dialogue:"):].strip().split(',', 9)
            if len(parts) < 10:
                # Malformed line, skip or handle?
                continue
            start_str = parts[1].strip()
            end_str = parts[2].strip()
            style = parts[3].strip()
            text = parts[9]
            start = parse_ass_time(start_str)
            end = parse_ass_time(end_str)
            dialogues.append({
                'line_index': i,
                'fields': parts,
                'start': start,
                'end': end,
                'style': style,
                'text': text,
            })
    return lines, dialogues


def write_ass(lines, dialogues):
    """
    Reconstruct ASS file content from original lines and updated dialogue times.
    Returns a single string with newline endings.
    """
    # Build a mapping from line_index to dialogue dict
    dmap = {d['line_index']: d for d in dialogues}
    new_lines = []
    for i, line in enumerate(lines):
        if i in dmap:
            d = dmap[i]
            fields = d['fields'].copy()
            fields[1] = format_ass_time(d['start'])
            fields[2] = format_ass_time(d['end'])
            new_line = "Dialogue: " + ",".join(fields)
            new_lines.append(new_line)
        else:
            new_lines.append(line)
    return "\n".join(new_lines) + "\n"


# ----------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------

def print_group_info(group):
    """Print details of an overlapping group."""
    style = group[0]['style']
    print(f"\nStyle: {style}, {len(group)} dialogues overlapping:")
    # Compute overlaps with next dialogue
    for i, d in enumerate(group):
        if i < len(group) - 1:
            next_d = group[i + 1]
            if d['end'] > next_d['start']:
                ov = d['end'] - next_d['start']
            else:
                ov = 0
            ov_str = f", overlap with next: {ov} ms"
        else:
            ov_str = ""
        dur = d['end'] - d['start']
        print(f"  {i+1}. {format_ass_time(d['start'])} - {format_ass_time(d['end'])} "
              f"(dur {dur} ms{ov_str})  {d['text']}")


def print_fix_preview(group, strategy='default'):
    """Show what changes would be made to a group if fixed."""
    original = copy.deepcopy(group)
    fixed = copy.deepcopy(group)
    if strategy == 'default':
        fix_group_default(fixed)
        strat_name = "default (lead-out first)"
    else:
        fix_group_alt(fixed)
        strat_name = "alternative (lead-in first)"
    print(f"\n  Proposed fix [{strat_name}]:")
    for i in range(len(original)):
        o = original[i]
        f = fixed[i]
        if o['start'] != f['start'] or o['end'] != f['end']:
            print(f"    Dialogue {i+1}: {format_ass_time(o['start'])}-{format_ass_time(o['end'])} "
                  f"-> {format_ass_time(f['start'])}-{format_ass_time(f['end'])}")
        else:
            print(f"    Dialogue {i+1}: unchanged")


def print_help():
    print(__doc__)


def print_interactive_help():
    print("""
y - fix this group (lead-out truncation first)
s - fix this group (lead-in truncation first)
n - do nothing on this group
a - fix this and all remaining groups (lead-out truncation first)
d - do nothing on this and all remaining groups
u - go back to previous group (undo last decision)
q - abort, do not write any changes for this file
? - show this help
""")


# ----------------------------------------------------------------------
# Main processing
# ----------------------------------------------------------------------

def process_file(filename, interactive):
    """Process one ASS file. Returns True if file was modified and written."""
    if interactive:
        if filename == '-':
            print("Processing file: <stdin>")
        else:
            print(f"Processing file: {filename}")

    if filename == "-":
        content = sys.stdin.read()
    else:
        with open(filename, 'r', encoding='utf-8-sig') as f:
            content = f.read()

    lines, dialogues = parse_ass(content)
    if not dialogues:
        print(f"No dialogue lines found in {filename}", file=sys.stderr)
        return False

    groups = find_overlap_groups(dialogues)
    if not groups:
        print(f"No accidental overlaps detected in {filename}.", file=sys.stderr)
        return False

    if not interactive:
        print(f"\n=== {filename}: {len(groups)} overlapping group(s) ===")
        for group in groups:
            print_group_info(group)
        return False

    # Interactive mode: go through groups and ask user
    decisions = [None] * len(groups)  # values: None, 'skip', 'fix_default', 'fix_alt'
    idx = 0
    aborted = False
    while idx < len(groups):
        group = groups[idx]
        print(f"\n--- Group {idx+1}/{len(groups)} ---")
        print_group_info(group)
        print("(y/s/n/a/d/u/q/?) ", end='', flush=True)
        resp = sys.stdin.readline().strip().lower()
        if resp == 'y':
            decisions[idx] = 'fix_default'
            print_fix_preview(group, 'default')
            idx += 1
        elif resp == 's':
            decisions[idx] = 'fix_alt'
            print_fix_preview(group, 'alt')
            idx += 1
        elif resp == 'n':
            decisions[idx] = 'skip'
            idx += 1
        elif resp == 'a':
            for j in range(idx, len(groups)):
                decisions[j] = 'fix_default'
                print_fix_preview(groups[j], 'default')
            idx = len(groups)
        elif resp == 'd':
            for j in range(idx, len(groups)):
                decisions[j] = 'skip'
            idx = len(groups)
        elif resp == 'u':
            if idx > 0:
                idx -= 1
                decisions[idx] = None
            else:
                print("Already at first group.")
        elif resp == 'q':
            print("Aborted. No changes will be written.")
            aborted = True
            break
        elif resp == '?':
            print_interactive_help()
        else:
            print("Invalid choice. Type ? for help.")

    if aborted:
        return False

    # Apply fixes where decided
    modified = False
    for i, group in enumerate(groups):
        if decisions[i] == 'fix_default':
            fix_group_default(group)
            modified = True
        elif decisions[i] == 'fix_alt':
            fix_group_alt(group)
            modified = True

    if not modified:
        print(f"No changes to write for {filename}.", file=sys.stderr)
        return False

    # Write output
    new_content = write_ass(lines, dialogues)
    if filename == "-":
        sys.stdout.write(new_content)
    else:
        with open(filename, 'w', encoding='utf-8-sig') as f:
            f.write(new_content)
        print(f"Written fixed file: {filename}", file=sys.stderr)
    return True


def main():
    args = sys.argv[1:]
    if not args:
        print_help()
        sys.exit(0)

    interactive = False
    files = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '-i':
            interactive = True
            i += 1
        elif arg == '-h' or arg == '--help':
            print_help()
            sys.exit(0)
        else:
            files.append(arg)
            i += 1

    if not files:
        print("Error: no input files specified.", file=sys.stderr)
        print_help()
        sys.exit(1)

    for f in files:
        process_file(f, interactive)


if __name__ == '__main__':
    main()
