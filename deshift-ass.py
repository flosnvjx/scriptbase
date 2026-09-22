#!/usr/bin/env python3
"""
Retime one or more ASS subtitle files to match reference files.

Assumes a constant full-track drift (not time-stretching, not partial-scene
drift). For each (reference, target) pair, the user interactively picks
corresponding events with fzf; the script computes the average start-time
offset and shifts the target's timed events by that amount.

In the fzf picker, events sharing the same start time and duration are
merged into one entry, regardless of Dialogue/Comment kind. This is a
display convenience only: the target file's line order and event kinds are
preserved untouched.

Style names are hidden by default in the picker. A style is shown when it
is a minority one, defined as: not the dominant style, and having fewer
than 90% of the dominant style's event count. Within a merged entry, the
style label is not repeated for neighbouring events sharing the same style.

Positional args are pairs: ref1 tgt1 [ref2 tgt2 ...]. Output for each pair
is written next to the target as <stem>.synced<suffix>.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


TIME_RE = re.compile(r"^(\d+):(\d{2}):(\d{2})\.(\d{2})$")

# Matches Dialogue and Comment events alike.
# Groups: 1=kind, 2="layer," prefix, 3=start, 4=end, 5=rest
EVENT_RE = re.compile(
    r"^(Dialogue|Comment):(\s*[^,]*,\s*)"
    r"(\d+:\d{2}:\d{2}\.\d{2}),"
    r"(\d+:\d{2}:\d{2}\.\d{2}),"
    r"(.*)$"
)

# Style visibility threshold: hide a style if its event count is at least
# this fraction of the dominant style's count.
STYLE_VISIBLE_RATIO = 0.9


class AssError(Exception):
    """Malformed input, missing tools, or I/O failure."""


class UserAbort(Exception):
    """User cancelled an fzf prompt or made no selection."""


# --- I/O ---

def read_lines(path):
    p = Path(path)
    if not p.is_file():
        raise AssError(f"File not found: {path}")
    try:
        raw = p.read_bytes()
    except OSError as e:
        raise AssError(f"Cannot read {path}: {e}") from e

    bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as e:
        raise AssError(f"Cannot decode {path} as UTF-8: {e}") from e
    return text.splitlines(keepends=True), bom


def write_lines(path, lines, bom):
    try:
        data = "".join(lines).encode("utf-8")
        if bom:
            data = b"\xef\xbb\xbf" + data
        Path(path).write_bytes(data)
    except OSError as e:
        raise AssError(f"Cannot write {path}: {e}") from e


# --- time ---

def parse_ass_time(s):
    m = TIME_RE.match(s.strip())
    if not m:
        raise AssError(f"Invalid ASS timestamp: {s!r}")
    h, mnt, sec, cs = map(int, m.groups())
    return h * 3600 + mnt * 60 + sec + cs / 100.0


def fmt_ass_time(t):
    if t < 0:
        t = 0.0
    total_cs = int(round(t * 100))
    h = total_cs // 360000
    mnt = (total_cs // 6000) % 60
    sec = (total_cs // 100) % 60
    cs = total_cs % 100
    return f"{h}:{mnt:02d}:{sec:02d}.{cs:02d}"


def fmt_short_time(t):
    """Compact display for narrow terminals: omit leading hours if zero."""
    if t < 0:
        t = 0.0
    total_cs = int(round(t * 100))
    h = total_cs // 360000
    mnt = (total_cs // 6000) % 60
    sec = (total_cs // 100) % 60
    cs = total_cs % 100
    if h:
        return f"{h}:{mnt:02d}:{sec:02d}.{cs:02d}"
    return f"{mnt:02d}:{sec:02d}.{cs:02d}"


# --- parsing / grouping ---

def clean_text(s):
    s = re.sub(r"\{[^}]*\}", "", s)
    s = s.replace("\\N", " ").replace("\\n", " ")
    return s.strip()


def parse_events(lines):
    events = []
    for i, line in enumerate(lines):
        m = EVENT_RE.match(line)
        if not m:
            continue
        # rest = Style,Name,MarginL,MarginR,MarginV,Effect,Text
        parts = m.group(5).split(",", 6)
        style = parts[0].strip() if parts else ""
        text = parts[6] if len(parts) > 6 else ""
        events.append({
            "line_idx": i,
            "kind": m.group(1),
            "start": m.group(3),
            "end": m.group(4),
            "style": style,
            "text": text,
        })
    return events


def group_events(events):
    """Merge events sharing (start, end) for the picker UI only."""
    by_key = {}
    ordered = []
    for e in events:
        key = (e["start"], e["end"])
        g = by_key.get(key)
        if g is None:
            g = {"start": e["start"], "end": e["end"], "events": []}
            by_key[key] = g
            ordered.append(g)
        g["events"].append(e)
    return ordered


def minority_styles(events):
    """
    Styles whose names should be surfaced in the picker.

    A style is kept hidden if it is the dominant one, or if its count is
    >= STYLE_VISIBLE_RATIO of the dominant count. Everything else is
    considered minority and gets its name shown.
    """
    counts = {}
    for e in events:
        s = e["style"]
        counts[s] = counts.get(s, 0) + 1
    if not counts:
        return set()
    threshold = max(counts.values()) * STYLE_VISIBLE_RATIO
    return {s for s, c in counts.items() if c < threshold}


# --- fzf ---

def _render_group_text(group, visible_styles):
    """
    Render one merged entry's contents, prefixing minority-style events
    with their style name. Consecutive events sharing a style do not
    repeat the label.
    """
    pieces = []
    last_style = None
    for e in group["events"]:
        txt = clean_text(e["text"])
        label = ""
        if e["style"] in visible_styles and e["style"] != last_style:
            label = f"[{e['style']}]"
        pieces.append(f"{label}{txt}")
        last_style = e["style"]
    return " | ".join(p for p in pieces if p)


def fzf_select_groups(groups, prompt, header, visible_styles):
    """
    Show grouped events in fzf and return selected groups.

    Raises UserAbort on ESC / Ctrl-C / empty selection / no match.
    """
    if not groups:
        raise UserAbort()

    input_lines = []
    for gi, g in enumerate(groups):
        t = parse_ass_time(g["start"])
        badge = f"[{len(g['events'])}] " if len(g["events"]) > 1 else ""
        body = _render_group_text(g, visible_styles)
        input_lines.append(
            f"{gi}\t{badge}{fmt_short_time(t)} | {body}"
        )
    input_text = "\n".join(input_lines) + "\n"

    # Compact layout suited to Termux / narrow phones.
    cmd = [
        "fzf",
        "--multi",
        "--no-sort",
        "--reverse",
        "--no-info",
        "--delimiter", "\t",
        "--with-nth", "2..",
        "--pointer", ">",
        "--marker", "*",
        "--prompt", prompt,
        "--header", header,
    ]

    try:
        proc = subprocess.run(
            cmd, input=input_text, text=True, capture_output=True,
        )
    except FileNotFoundError as e:
        raise AssError("fzf not found in PATH") from e
    except OSError as e:
        raise AssError(f"Failed to run fzf: {e}") from e

    if proc.returncode in (130, -2):  # ESC / SIGINT
        raise UserAbort()
    if proc.returncode == 1:  # no match for query
        raise UserAbort()
    if proc.returncode != 0:
        raise AssError(
            f"fzf exited with code {proc.returncode}: "
            f"{proc.stderr.strip() or '(no stderr)'}"
        )
    if not proc.stdout.strip():
        raise UserAbort()  # accepted with nothing selected

    selected = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        try:
            gi = int(line.split("\t", 1)[0])
        except ValueError:
            continue
        if 0 <= gi < len(groups):
            selected.append(groups[gi])
    if not selected:
        raise UserAbort()
    return selected


def select_paired_groups(ref_groups, tgt_groups, ref_name, tgt_name,
                         ref_visible, tgt_visible):
    ref_sel = fzf_select_groups(
        ref_groups, "ref> ", f"reference: {ref_name}", ref_visible,
    )
    n = len(ref_sel)
    tgt_sel = fzf_select_groups(
        tgt_groups, "tgt> ", f"target: {tgt_name}  (need {n})",
        tgt_visible,
    )
    if len(tgt_sel) != n:
        raise AssError(
            f"Selected {len(tgt_sel)} target event(s), expected {n}. "
            f"Please re-run and pick a matching count."
        )
    ref_sel.sort(key=lambda g: g["events"][0]["line_idx"])
    tgt_sel.sort(key=lambda g: g["events"][0]["line_idx"])
    return ref_sel, tgt_sel


# --- core ---

def compute_offset(ref_sel, tgt_sel):
    diffs = [
        parse_ass_time(r["start"]) - parse_ass_time(t["start"])
        for r, t in zip(ref_sel, tgt_sel)
    ]
    return sum(diffs) / len(diffs)


def retime(lines, offset, include_comments):
    """
    Return (new_lines, changed, clamped).

    new_lines is a copy of lines with Dialogue/Comment timestamps shifted by
    offset; Comment lines are skipped when include_comments is False.
    """
    new_lines = list(lines)
    changed = 0
    clamped = 0
    for i, line in enumerate(lines):
        m = EVENT_RE.match(line)
        if not m:
            continue
        if not include_comments and m.group(1) == "Comment":
            continue
        start = parse_ass_time(m.group(3))
        end = parse_ass_time(m.group(4))
        ns = start + offset
        ne = end + offset
        if ns < 0 or ne < 0:
            clamped += 1
        new_line = (
            f"{m.group(1)}:{m.group(2)}"
            f"{fmt_ass_time(ns)},{fmt_ass_time(ne)},{m.group(5)}"
        )
        if new_line != line:
            new_lines[i] = new_line
            changed += 1
    return new_lines, changed, clamped


def out_path_for(target):
    p = Path(target)
    return p.with_name(p.stem + ".synced" + p.suffix)


def backup_path_for(target):
    # Append .bak so we never clash with a real extension.
    return Path(str(target) + ".bak")


def process_pair(ref_path, tgt_path, backup, include_comments, dry_run):
    ref_lines, _ = read_lines(ref_path)
    tgt_lines, tgt_bom = read_lines(tgt_path)

    ref_events = parse_events(ref_lines)
    tgt_events = parse_events(tgt_lines)
    if not ref_events:
        raise AssError(f"No Dialogue/Comment events in {ref_path}")
    if not tgt_events:
        raise AssError(f"No Dialogue/Comment events in {tgt_path}")

    ref_sel, tgt_sel = select_paired_groups(
        group_events(ref_events),
        group_events(tgt_events),
        Path(ref_path).name,
        Path(tgt_path).name,
        minority_styles(ref_events),
        minority_styles(tgt_events),
    )

    offset = compute_offset(ref_sel, tgt_sel)
    print(f"  offset {offset:+.3f}s  ({len(ref_sel)} pair)")

    new_lines, changed, clamped = retime(
        tgt_lines, offset, include_comments,
    )

    if changed == 0:
        print("  already in sync, no write")
        return

    out_path = out_path_for(tgt_path)

    if dry_run:
        print(f"  [dry-run] would write {out_path} ({changed} events)")
    else:
        if backup:
            bak = backup_path_for(tgt_path)
            try:
                shutil.copyfile(tgt_path, bak)
            except OSError as e:
                raise AssError(f"Cannot create backup {bak}: {e}") from e
            print(f"  backup -> {bak}")
        write_lines(out_path, new_lines, tgt_bom)
        print(f"  wrote {out_path} ({changed} events)")

    if clamped:
        print(
            f"  warning: clamped {clamped} negative timestamp(s)",
            file=sys.stderr,
        )


# --- entry ---

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "pairs", nargs="+", metavar="REF TGT",
        help="pairs of ASS files: ref1 tgt1 [ref2 tgt2 ...]",
    )
    ap.add_argument(
        "-b", "--backup", action="store_true",
        help="keep a <target>.bak copy before writing",
    )
    ap.add_argument(
        "--no-comments", action="store_true",
        help="do not retime Comment events (Dialogue only)",
    )
    ap.add_argument(
        "-n", "--dry-run", action="store_true",
        help="compute offsets and report, but do not write or back up",
    )
    args = ap.parse_args()

    if len(args.pairs) % 2 != 0:
        ap.error(
            "expected an even number of positional arguments "
            "(ref/tgt pairs)"
        )
    pairs = [
        (args.pairs[i], args.pairs[i + 1])
        for i in range(0, len(args.pairs), 2)
    ]

    if shutil.which("fzf") is None:
        sys.exit("error: fzf not found in PATH")

    include_comments = not args.no_comments
    failures = 0

    try:
        for ref_path, tgt_path in pairs:
            print(f"{ref_path}  +  {tgt_path}")
            try:
                process_pair(
                    ref_path, tgt_path,
                    backup=args.backup,
                    include_comments=include_comments,
                    dry_run=args.dry_run,
                )
            except AssError as e:
                print(f"  error: {e}", file=sys.stderr)
                failures += 1
    except UserAbort:
        sys.exit(130)
    except KeyboardInterrupt:
        sys.exit(130)

    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
