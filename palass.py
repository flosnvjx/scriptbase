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
    -p, --prevent-overlap   Prevent subtitle overlap (force 10 ms gap).
    -h, --help              Show this help.

Algorithm per event:
    1. delta = duration(original) - duration(adjusted)
    2. desired lead_in = R * delta, desired lead_out = (1-R)*delta
    3. Clamp lead_in to [i_min, I_max], lead_out to [o_min, O_max]
    4. If lead_out was clamped, recompute lead_in = delta - clamped_lead_out
       and clamp again.
    5. new_start = adjusted_start - lead_in, new_end = adjusted_end + lead_out
    6. Ensure duration >= 10 ms.
    7. If --prevent-overlap, ensure new_start >= previous_end + 10 ms,
       pushing start forward and recomputing end to preserve duration as much as
       possible (respecting lead_out bounds).
"""

import argparse
import sys
import os
import math
from typing import List, Optional, Tuple

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
        "-p", "--prevent-overlap",
        action="store_true",
        help="Prevent overlapping subtitles (enforce 10 ms gap)."
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
    prevent_overlap: bool,
) -> None:
    """Main processing pipeline."""
    try:
        orig_subs = pysubs2.load(orig_path)
        adj_subs = pysubs2.load(adj_path)
    except Exception as e:
        sys.exit(f"Error loading subtitle files: {e}")

    n = min(len(orig_subs), len(adj_subs))
    if len(orig_subs) != len(adj_subs):
        print(
            f"Warning: event counts differ. Original: {len(orig_subs)}, "
            f"Adjusted: {len(adj_subs)}. Processing first {n} events.",
            file=sys.stderr,
        )

    if n == 0:
        print("No events to process.", file=sys.stderr)
        # Still write output (preserving comments if ASS)
        write_output(adj_path, out_path, [], prevent_overlap)
        return

    modified_events = []
    previous_end_ms = -10  # for overlap prevention, initial sentinel
    warnings = []

    for i in range(n):
        orig = orig_subs[i]
        adj = adj_subs[i]

        dur_orig = orig.end - orig.start          # milliseconds
        dur_adj = adj.end - adj.start
        delta = dur_orig - dur_adj                # milliseconds

        # Skip negligible differences (< 1 ms)
        if abs(delta) < 1.0:
            # Still need to handle overlap for this event
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

        # ---------- Minimum duration protection ----------
        if new_end - new_start < 10:
            # Lengthen to 10 ms by moving start earlier (if possible) or end later.
            # We prefer moving start earlier, but we don't know the bounds here
            # because we already applied them. For simplicity, we center the 10 ms.
            mid = (new_start + new_end) // 2
            new_start = mid - 5
            new_end = mid + 5
            if new_start < 0:
                new_start = 0
                new_end = 10

        # ---------- Overlap prevention (optional) ----------
        if prevent_overlap:
            gap = 10  # milliseconds
            if new_start < previous_end_ms + gap:
                # Push start forward to ensure gap
                new_start = previous_end_ms + gap
                # Recompute end to keep original duration as much as possible
                # Desired end = new_start + dur_orig, but respect lead_out bounds.
                # We already have a target lead_out from earlier, but we need to
                # respect the allowed range. So we compute the required lead_out
                # as (new_end - adj.end) and then clamp it.
                # However, we might have already lost the original delta if we
                # skipped due to small delta. In that case, we try to preserve
                # the original duration of the adjusted event.
                # Better: we use the original desired duration (dur_orig) if we
                # have a delta, else use the adjusted duration.
                if abs(delta) >= 1.0:
                    target_end = new_start + dur_orig
                else:
                    target_end = new_start + dur_adj   # keep adjusted duration
                # Convert lead_out to seconds and clamp
                lead_out_required = (target_end - adj.end) / 1000.0
                if lead_out_max is None:
                    lo_max = float("inf")
                else:
                    lo_max = lead_out_max
                lead_out_clamped = clamp(lead_out_required, lead_out_min, lo_max)
                new_end = int(round(adj.end + lead_out_clamped * 1000.0))
                # Re-apply minimum duration (should already be ≥10ms)
                if new_end - new_start < 10:
                    new_end = new_start + 10

        # Create new event
        new_event = adj.copy()
        new_event.start = new_start
        new_event.end = new_end
        modified_events.append(new_event)

        # Update previous_end for next iteration
        previous_end_ms = new_end

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

    write_output(adj_path, out_path, modified_events, prevent_overlap)


# ---------- Output writer (preserves ASS comments) ----------
def write_output(adj_path: str, out_path: str,
                 modified_events: List[pysubs2.SSAEvent],
                 prevent_overlap: bool) -> None:
    """
    Write modified subtitles.
    For ASS, read original adjusted file line by line, preserve all lines
    except Dialogue lines (replace with modified event's to_ass()).
    For SRT, simply save using pysubs2.
    """
    ext = os.path.splitext(out_path)[1].lower()
    if ext == ".ass":
        try:
            with open(adj_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except Exception as e:
            sys.exit(f"Error reading adjusted ASS file: {e}")

        event_idx = 0
        with open(out_path, "w", encoding="utf-8") as f:
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("Dialogue:"):
                    if event_idx < len(modified_events):
                        new_line = modified_events[event_idx].to_ass()
                        if not new_line.endswith('\n'):
                            new_line += '\n'
                        f.write(new_line)
                        event_idx += 1
                    else:
                        f.write(line)
                else:
                    f.write(line)
    else:
        # SRT or other: just save with pysubs2
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
        args.prevent_overlap,
    )


if __name__ == "__main__":
    main()