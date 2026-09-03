#!/usr/bin/env python3
"""
Subtitle Duration Restorer

Restore original display durations after alass adjustment by redistributing
the time offset between lead‑in (start) and lead‑out (end) while obeying
user‑defined bounds and a preferred ratio. Preserves ASS comments and all
formatting except Dialogue timestamps.

Usage:
    subtitle_duration_restorer.py original.srt adjusted.srt output.srt [options]
    subtitle_duration_restorer.py original.ass adjusted.ass output.ass [options]

Options:
    -I SEC   Maximum lead‑in offset (positive = start earlier). Default: inf.
    -i SEC   Minimum lead‑in offset. Default: 0.0 (never shift start later).
    -O SEC   Maximum lead‑out offset (positive = end later). Default: inf.
    -o SEC   Minimum lead‑out offset. Default: -0.5 (allow end up to 0.5s earlier).
    -R RATIO Preferred proportion of total compensation assigned to lead‑in.
             Default: 0.5 (half to lead‑in, half to lead‑out).
    -p [SEC] Prevent overlapping subtitles. The value is a threshold:
             only overlaps <= SEC seconds are corrected (default SEC=inf,
             meaning all overlaps are corrected). If -p is omitted,
             overlap prevention is disabled.
    --cross-style  When -p is used, apply overlap prevention globally across
                   all Styles (instead of per‑Style). Ignored for SRT.
    -m SEC   Enforce a minimum display duration (seconds). Default: 0.01.
             Must be >= 0.01. Overrides all other constraints if necessary.
             Skips events with empty text content.
    -h, --help  Show this help.

Algorithm per event:
    1. delta = duration(original) - duration(adjusted)
    2. desired lead_in = R * delta, desired lead_out = (1-R)*delta
    3. Clamp lead_in to [i_min, I_max], lead_out to [o_min, O_max]
    4. If lead_out was clamped, recompute lead_in = delta - clamped_lead_out
       and clamp again.
    5. new_start = adjusted_start - lead_in, new_end = adjusted_end + lead_out
    6. If -p is active:
         - For ASS, group by Style (unless --cross-style)
         - Compute overlap = previous_end_of_same_group - new_start
         - If overlap > 0 and overlap <= tolerance_ms, then correct:
             * move start forward to previous_end + 10ms
             * adjust end to preserve duration as much as possible (within lead_out bounds)
    7. Finally, enforce min_duration (unless event text is empty): if duration < min_duration, extend end.
"""

import argparse
import sys
import os
import math
from typing import List, Optional, Tuple, Dict

import pysubs2


# ---------- Argument parsing helpers ----------
def parse_time_opt(value: str) -> Optional[float]:
    """Parse a time option; 'inf' or 'INF' -> None (unlimited), otherwise float."""
    if value.lower() == "inf":
        return None
    try:
        return float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"Invalid time value: {value}")


def parse_ratio(value: str) -> float:
    r = float(value)
    if not (0.0 <= r <= 1.0):
        raise argparse.ArgumentTypeError("Ratio must be between 0 and 1")
    return r


def parse_finite_float(value: str) -> float:
    """Parse a float that must not be inf or nan."""
    f = float(value)
    if not math.isfinite(f):
        raise argparse.ArgumentTypeError(f"Value must be finite, got {value}")
    return f


def parse_overlap_tolerance(value: str) -> Optional[float]:
    """
    Parse the -p value. 'inf' or 'INF' -> float('inf').
    Otherwise, must be a non‑negative float (0 allowed).
    Returns None only if the argument is not given (which is handled by default=None).
    """
    if value is None:
        return None
    if value.lower() == "inf":
        return float("inf")
    try:
        f = float(value)
        if f < 0:
            raise argparse.ArgumentTypeError("Tolerance must be >= 0")
        return f
    except ValueError:
        raise argparse.ArgumentTypeError(f"Invalid tolerance value: {value}")


def parse_min_duration(value: str) -> float:
    f = float(value)
    if f < 0.01:
        raise argparse.ArgumentTypeError("Minimum duration must be at least 0.01 seconds")
    return f


def get_args():
    parser = argparse.ArgumentParser(
        description="Restore original subtitle durations after alass adjustment.",
        add_help=False,
    )
    parser.add_argument("original", help="Original subtitle file (reference durations)")
    parser.add_argument("adjusted", help="Adjusted subtitle file (alass output)")
    parser.add_argument("output", help="Output subtitle file")
    parser.add_argument(
        "-I",
        dest="lead_in_max",
        type=parse_time_opt,
        default=None,
        help="Maximum lead‑in offset (sec). Default: unlimited.",
    )
    parser.add_argument(
        "-i",
        dest="lead_in_min",
        type=parse_finite_float,
        default=0.0,
        help="Minimum lead‑in offset (sec). Default: 0.0.",
    )
    parser.add_argument(
        "-O",
        dest="lead_out_max",
        type=parse_time_opt,
        default=None,
        help="Maximum lead‑out offset (sec). Default: unlimited.",
    )
    parser.add_argument(
        "-o",
        dest="lead_out_min",
        type=parse_finite_float,
        default=-0.5,
        help="Minimum lead‑out offset (sec). Default: -0.5.",
    )
    parser.add_argument(
        "-R",
        dest="ratio",
        type=parse_ratio,
        default=0.5,
        help="Preferred ratio for lead‑in vs lead‑out. Default: 0.5.",
    )
    parser.add_argument(
        "-p",
        dest="overlap_tolerance",
        nargs="?",
        const="inf",          # when -p is given without value, treat as inf
        default=None,         # when -p is not given, disable prevention
        type=parse_overlap_tolerance,
        help="Prevent overlaps with tolerance threshold (default: inf).",
    )
    parser.add_argument(
        "--cross-style",
        dest="cross_style",
        action="store_true",
        help="When -p is used, apply overlap prevention globally across all Styles.",
    )
    parser.add_argument(
        "-m",
        dest="min_duration",
        type=parse_min_duration,
        default=0.01,
        help="Minimum display duration (seconds). Default: 0.01. Skips empty events.",
    )
    parser.add_argument(
        "-h", "--help", action="help", help="Show this help message and exit."
    )
    return parser.parse_args()


# ---------- Core distribution logic ----------
def clamp(value: float, lo: float, hi: float) -> float:
    """Clamp value to [lo, hi] where hi may be infinite."""
    if math.isinf(hi):
        return max(value, lo)
    return max(lo, min(value, hi))


def distribute_delta(
    delta: float,
    lead_in_min: float,
    lead_in_max: Optional[float],
    lead_out_min: float,
    lead_out_max: Optional[float],
    ratio: float,
) -> Tuple[float, float]:
    """
    Split required delta (seconds) into lead_in and lead_out offsets.

    Returns (lead_in, lead_out) such that lead_in + lead_out ≈ delta,
    respecting all bounds. If impossible, returns the closest achievable pair.
    """
    if lead_in_max is None:
        lead_in_max = float("inf")
    if lead_out_max is None:
        lead_out_max = float("inf")

    # Validate intervals
    if lead_in_min > lead_in_max or lead_out_min > lead_out_max:
        raise ValueError("Empty interval for lead‑in or lead‑out constraints.")

    # Initial targets
    x_target = ratio * delta
    y_target = delta - x_target

    # Clamp lead‑in
    x = clamp(x_target, lead_in_min, lead_in_max)
    y = clamp(delta - x, lead_out_min, lead_out_max)

    # If lead‑out was clamped, recompute lead‑in
    y_required = delta - x
    if not math.isclose(y, y_required, abs_tol=1e-9):
        x = clamp(delta - y, lead_in_min, lead_in_max)

    # Final adjustment to ensure sum exactly equals delta (within numeric tolerance)
    # If sum differs, try to push the surplus into the side that has room.
    total = x + y
    if not math.isclose(total, delta, abs_tol=1e-6):
        surplus = delta - total
        # Try to add surplus to x first
        x_new = clamp(x + surplus, lead_in_min, lead_in_max)
        if math.isclose(x_new, x + surplus, abs_tol=1e-6):
            x = x_new
        else:
            y = clamp(y + surplus, lead_out_min, lead_out_max)
    return x, y


# ---------- Main processing ----------
def apply_restoration(
    orig_path: str,
    adj_path: str,
    out_path: str,
    lead_in_min: float,
    lead_in_max: Optional[float],
    lead_out_min: float,
    lead_out_max: Optional[float],
    ratio: float,
    overlap_tolerance: Optional[float],   # None = disabled, inf = all overlaps
    cross_style: bool,
    min_duration: float,
) -> None:
    """Main processing pipeline."""
    try:
        orig_subs = pysubs2.load(orig_path)
        adj_subs = pysubs2.load(adj_path)
    except Exception as e:
        sys.exit(f"Error loading subtitle files: {e}")

    # Determine if we are dealing with ASS (has style)
    is_ass = os.path.splitext(adj_path)[1].lower() == ".ass"

    n = min(len(orig_subs), len(adj_subs))
    if len(orig_subs) != len(adj_subs):
        print(
            f"Warning: event counts differ. Original: {len(orig_subs)}, "
            f"Adjusted: {len(adj_subs)}. Processing first {n} events.",
            file=sys.stderr,
        )

    if n == 0:
        print("No events to process.", file=sys.stderr)
        write_output(adj_path, out_path, [], cross_style, is_ass, adj_subs)
        return

    modified_events = []
    # For overlap prevention by style (if not cross_style and is_ass)
    last_end_by_style: Dict[str, int] = {}
    # Global last end (for cross_style or SRT)
    global_previous_end = -10  # milliseconds

    warnings = []

    for i in range(n):
        orig = orig_subs[i]
        adj = adj_subs[i]

        dur_orig = orig.end - orig.start          # milliseconds
        dur_adj = adj.end - adj.start
        delta = dur_orig - dur_adj                # milliseconds

        # Skip negligible differences (< 1 ms)
        if abs(delta) < 1.0:
            new_start = adj.start
            new_end = adj.end
        else:
            delta_sec = delta / 1000.0
            x, y = distribute_delta(
                delta_sec,
                lead_in_min,
                lead_in_max,
                lead_out_min,
                lead_out_max,
                ratio,
            )
            new_start = int(round(adj.start - x * 1000.0))
            new_end = int(round(adj.end + y * 1000.0))

        # ---------- Overlap prevention (if enabled) ----------
        if overlap_tolerance is not None:
            # Determine which previous end to compare against
            if cross_style or not is_ass:
                prev_end = global_previous_end
            else:
                # Use style name; if style is empty, treat as common group?
                style = adj.style if hasattr(adj, 'style') and adj.style else "_default_"
                prev_end = last_end_by_style.get(style, -10)

            overlap_ms = prev_end - new_start
            # New condition: correct only if overlap > 0 AND overlap <= tolerance
            if overlap_ms > 0 and overlap_ms <= overlap_tolerance * 1000.0:
                # Need to push start forward
                new_start = prev_end + 10  # minimum gap
                # Try to keep original duration (or adjusted if no delta)
                if abs(delta) >= 1.0:
                    target_end = new_start + dur_orig
                else:
                    target_end = new_start + dur_adj
                # Clamp lead_out to allowed range
                lead_out_required = (target_end - adj.end) / 1000.0
                if lead_out_max is None:
                    lo_max = float("inf")
                else:
                    lo_max = lead_out_max
                lead_out_clamped = clamp(lead_out_required, lead_out_min, lo_max)
                new_end = int(round(adj.end + lead_out_clamped * 1000.0))

        # ---------- Minimum duration enforcement (highest priority, but skip empty text) ----------
        # Check if the event text is empty or only whitespace
        if adj.text.strip() == "":
            # Skip min_duration for empty events
            pass
        else:
            min_dur_ms = int(round(min_duration * 1000.0))
            if new_end - new_start < min_dur_ms:
                # Extend end to meet minimum
                new_end = new_start + min_dur_ms
                # Warn if this broke lead_out bounds
                lead_out_actual = (new_end - adj.end) / 1000.0
                if lead_out_max is not None and lead_out_actual > lead_out_max:
                    warnings.append(
                        f"Event {i}: min_duration forced end beyond -O limit "
                        f"(actual lead_out={lead_out_actual:.3f}s > {lead_out_max:.3f}s)"
                    )
                elif lead_out_actual < lead_out_min:
                    warnings.append(
                        f"Event {i}: min_duration forced end beyond -o limit "
                        f"(actual lead_out={lead_out_actual:.3f}s < {lead_out_min:.3f}s)"
                    )

        # Create new event
        new_event = adj.copy()
        new_event.start = new_start
        new_event.end = new_end
        modified_events.append(new_event)

        # Update previous end records (only if overlap prevention is active)
        if overlap_tolerance is not None:
            if cross_style or not is_ass:
                global_previous_end = new_end
            else:
                style = adj.style if hasattr(adj, 'style') and adj.style else "_default_"
                last_end_by_style[style] = new_end

        # Check if final duration differs significantly from original
        final_delta = (new_end - new_start) - dur_orig
        if abs(final_delta) > 5:
            warnings.append(
                f"Event {i}: desired Δ={delta/1000:.3f}s, achieved "
                f"={final_delta/1000:.3f}s (limits forced compromise)"
            )

    if warnings:
        print("Warning: some events could not be fully restored:", file=sys.stderr)
        for w in warnings[:10]:
            print(f"  {w}", file=sys.stderr)
        if len(warnings) > 10:
            print(f"  ... and {len(warnings)-10} more.", file=sys.stderr)

    write_output(adj_path, out_path, modified_events, cross_style, is_ass, adj_subs)


# ---------- Output writer (preserves ASS comments) ----------
def write_output(adj_path: str, out_path: str,
                 modified_events: List[pysubs2.SSAEvent],
                 cross_style: bool, is_ass: bool,
                 adj_subs: pysubs2.SSAFile) -> None:
    """
    Write modified subtitles.
    For ASS, use pysubs2's to_string() to generate correct Dialogue lines
    (in memory), then replace only the Dialogue lines in the original file.
    This preserves all comments and styles.
    For SRT, simply save using pysubs2.
    """
    ext = os.path.splitext(out_path)[1].lower()
    if ext == ".ass":
        try:
            with open(adj_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except Exception as e:
            sys.exit(f"Error reading adjusted ASS file: {e}")

        # Create a temporary SSAFile with the modified events
        temp_subs = pysubs2.SSAFile()
        temp_subs.format = adj_subs.format  # Use the same field order
        temp_subs.events = modified_events

        # Generate full ASS content in memory using to_string() with format "ass"
        full_ass = temp_subs.to_string("ass")

        # Extract all Dialogue lines (they will be in the correct order)
        new_dialogue_lines = [
            line.rstrip('\n') for line in full_ass.splitlines()
            if line.strip().startswith("Dialogue:")
        ]

        # Replace Dialogue lines in the original file
        event_idx = 0
        with open(out_path, "w", encoding="utf-8") as f:
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("Dialogue:"):
                    if event_idx < len(new_dialogue_lines):
                        f.write(new_dialogue_lines[event_idx] + '\n')
                        event_idx += 1
                    else:
                        # Fallback (should not happen)
                        f.write(line)
                else:
                    # Preserve all other lines (comments, headers, styles, empty lines)
                    f.write(line)
    else:
        # SRT output: just save with pysubs2
        new_file = pysubs2.SSAFile()
        new_file.events = modified_events
        new_file.save(out_path)


# ---------- Entry point ----------
def main():
    args = get_args()
    apply_restoration(
        args.original,
        args.adjusted,
        args.output,
        args.lead_in_min,
        args.lead_in_max,
        args.lead_out_min,
        args.lead_out_max,
        args.ratio,
        args.overlap_tolerance,
        args.cross_style,
        args.min_duration,
    )


if __name__ == "__main__":
    main()