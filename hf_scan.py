#!/usr/bin/env python3
"""
HF Significance Scanner for Lossy Codec Quality Tuning
======================================================

This tool measures the perceptual significance of high-frequency content in an
audio file by scanning a range of crossover frequencies. For each crossover
frequency it computes the fraction of total integrated loudness (ITU‑R BS.1770‑4)
that resides above that frequency, yielding a **HF significance score** between
0 and 1.

The scan result is a CSV table mapping crossover frequencies to scores, which can
be used together with a codec's quality→lowpass mapping (e.g., LAME -V table) to
automatically select the lowest VBR quality that still preserves perceptually
important high frequencies.

Requirements
------------
- Python 3.7+
- FFmpeg (must be on PATH)
- No additional Python packages required (uses only standard library).

Usage
-----
    python3 hf_scan.py [options] <audio_file>

Arguments
---------
    <audio_file>          Path to input audio file (required, positional).
                          Use '-' to read from stdin.
    -v, --verbose         If given, ffmpeg's stderr is printed in real time.
                          Without this flag, ffmpeg runs silently (stderr is
                          only captured for internal parsing).
    -p, --parallel JOBS   Number of ffmpeg processes to run in parallel.
                          0    → use all available CPU cores
                          >0   → use exactly that many jobs
                          <0   → use (available_cores + JOBS) jobs, minimum 1
                                 e.g., -p -1 on a 8-core machine uses 7 jobs
                          (default: 1, serial execution)
    -f, --format FMT      Force input format (passed to ffmpeg -f). Useful for
                          stdin or pipes, e.g. -f flac.
    --start, -s START_KHZ Lowest crossover frequency in kHz (default: 14).
    --end, -e END_KHZ     Highest crossover frequency in kHz (default: 20).
    --step, -t STEP_KHZ   Step size in kHz between successive measurements
                          (default: 1).

Examples
--------
    # Default scan (14-20 kHz, step 1 kHz), serial
    python3 hf_scan.py song.flac

    # Use all CPU cores
    python3 hf_scan.py -p 0 song.flac

    # Leave one core free (on an 8-core machine, uses 7)
    python3 hf_scan.py -p -1 song.flac

    # Read from stdin, parallel (automatically buffered to memory)
    cat song.flac | python3 hf_scan.py -p 4 -

Output Format
-------------
CSV with header:
    crossover_hz,hf_score

Columns:
    crossover_hz : high-pass crossover frequency in Hz.
    hf_score     : fraction of perceptual loudness above that frequency [0,1].

Background
----------
Lossy audio encoders often discard content above a certain lowpass frequency
that depends on the chosen VBR quality. If the high-frequency content is
perceptually irrelevant, you can use a lower quality (thus lower bitrate)
without audible degradation.

By scanning many possible cutoffs and measuring their loudness contribution, this
tool lets you choose the safest quality level for each track, avoiding wasted bits.

Notes on parallel processing with streams
------------------------------------------
When parallel workers are requested (workers > 1) and the input is a
non‑seekable stream (stdin, named pipe, etc.), the entire input is first
buffered into memory (using memfd on Linux, falling back to a pure in‑memory
buffer). This avoids multiple ffmpeg processes competing for the same stream.
Serial mode does not buffer.
"""

import argparse
import subprocess
import json
import re
import sys
import os
import stat
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, Union, Tuple


def get_loudness(file_path: str,
                 crossover_freq: Optional[float] = None,
                 verbose: bool = False,
                 input_data: Optional[bytes] = None,
                 input_format: Optional[str] = None) -> float:
    """
    Measure integrated loudness (LUFS) using ffmpeg's loudnorm filter.

    If `input_data` is provided, it is written to ffmpeg's stdin and the input
    is read from 'pipe:0' instead of a file. This is used when the source is a
    buffered in‑memory stream.

    Parameters
    ----------
    file_path : str
        Path to the input file (used only if input_data is None).
    crossover_freq : float or None
        High‑pass crossover frequency in Hz.
    verbose : bool
        If True, ffmpeg's stderr is printed in real time.
    input_data : bytes or None
        Raw audio bytes to be piped via stdin (skips file_path).
    input_format : str or None
        If given, passed to ffmpeg as -f <fmt> before the input.

    Returns
    -------
    float
        Integrated loudness in LUFS (dB).

    Raises
    ------
    RuntimeError
        On ffmpeg failure or missing JSON.
    """
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-xerror",
        "-err_detect", "+explode",
        "-loglevel", "info",
    ]

    if input_format is not None:
        cmd.extend(["-f", input_format])

    if input_data is not None:
        cmd.extend(["-i", "pipe:0"])
    else:
        cmd.extend(["-i", file_path])

    if crossover_freq is not None:
        cmd.extend(["-af", f"highpass=f={crossover_freq},loudnorm=print_format=json"])
    else:
        cmd.extend(["-af", "loudnorm=print_format=json"])

    cmd.extend(["-f", "null", "-"])

    # Use binary streams, no universal_newlines
    stdin_arg = subprocess.PIPE if input_data is not None else None
    proc = subprocess.Popen(
        cmd,
        stdin=stdin_arg,
        stderr=subprocess.PIPE,
        # No universal_newlines – we'll decode stderr manually
    )

    # Write input_data to stdin if provided (bytes)
    if input_data is not None:
        try:
            proc.stdin.write(input_data)
        except BrokenPipeError:
            pass
        finally:
            proc.stdin.close()

    stderr_lines = []
    # Read stderr as binary, decode line by line
    for line_bytes in proc.stderr:
        line = line_bytes.decode('utf-8', errors='replace')
        if verbose:
            sys.stderr.write(line)
            sys.stderr.flush()
        stderr_lines.append(line)

    proc.wait()
    stderr_text = "".join(stderr_lines)

    if proc.returncode != 0:
        if not verbose:
            sys.stderr.write(stderr_text)
        raise RuntimeError(f"ffmpeg exited with code {proc.returncode}")

    match = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", stderr_text, re.DOTALL)
    if not match:
        raise RuntimeError("Could not find loudnorm JSON in ffmpeg output.")
    data = json.loads(match.group(0))
    return float(data["input_i"])


def resolve_worker_count(parallel_arg: int) -> int:
    available = os.cpu_count() or 1
    if parallel_arg == 0:
        return available
    if parallel_arg > 0:
        return parallel_arg
    workers = available + parallel_arg
    return max(1, workers)


def buffer_stream_if_needed(audio_file: str, workers: int) -> Tuple[Union[str, bytes], bool]:
    """
    Prepare the audio source for parallel processing.

    Returns (source, is_memory) where:
    - If the input is a regular file or workers == 1, source is the file path
      and is_memory is False.
    - If the input is a stream and workers > 1:
        * On Linux, try to create a memfd and return its /proc/self/fd path
          (is_memory=False).
        * Otherwise, read the entire stream into memory and return the raw bytes
          (is_memory=True).
    """
    if workers <= 1:
        return audio_file, False

    if audio_file == '-':
        stream = sys.stdin.buffer
        is_stream = True
    else:
        try:
            st = os.stat(audio_file)
            if stat.S_ISREG(st.st_mode):
                return audio_file, False
            stream = open(audio_file, 'rb')
            is_stream = True
        except (FileNotFoundError, OSError):
            return audio_file, False

    print("Input is a non-seekable stream; buffering to memory for parallel access...",
          file=sys.stderr)

    try:
        data = stream.read()
    finally:
        if is_stream and audio_file != '-':
            stream.close()

    # 1. Try memfd (Linux, Python ≥ 3.8)
    try:
        fd = os.memfd_create('hf_scan_input', os.MFD_CLOEXEC)
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.lseek(fd, 0, os.SEEK_SET)
        return f"/proc/self/fd/{fd}", False
    except (OSError, AttributeError):
        pass

    # 2. Fallback: keep in memory, feed via stdin
    print("memfd not available, using in‑memory buffer (stdin pipes).",
          file=sys.stderr)
    return data, True


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan HF perceptual significance across multiple crossover frequencies.",
        epilog="Examples:\n"
               "  python3 hf_scan.py song.flac\n"
               "  python3 hf_scan.py -v song.flac\n"
               "  python3 hf_scan.py -p 0 --start 15 --end 18 --step 0.5 song.flac\n"
               "  python3 hf_scan.py -p -1 song.flac\n"
               "  cat song.flac | python3 hf_scan.py -p 4 -f flac -",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("audio_file", metavar="<audio_file>",
                        help="Path to input audio file (required, positional). Use '-' for stdin.")
    parser.add_argument("-v", "--verbose", action="store_true", default=False,
                        help="Print ffmpeg's stderr in real time.")
    parser.add_argument("-p", "--parallel", type=int, default=1, metavar="JOBS",
                        help="Number of parallel ffmpeg jobs. 0 for all cores, negative to subtract (min 1). Default: 1 (serial).")
    parser.add_argument("-f", "--format", type=str, default=None, metavar="FMT",
                        help="Force input format (passed to ffmpeg -f).")
    parser.add_argument("--start", "-s", type=float, default=14,
                        help="Lowest crossover frequency in kHz (default: 14).")
    parser.add_argument("--end", "-e", type=float, default=20,
                        help="Highest crossover frequency in kHz (default: 20).")
    parser.add_argument("--step", "-t", type=float, default=1,
                        help="Step size in kHz (default: 1).")
    return parser


def main() -> None:
    parser = build_argument_parser()
    args = parser.parse_args()

    audio_file = args.audio_file
    verbose = args.verbose
    input_format = args.format
    start_hz = int(args.start * 1000)
    end_hz = int(args.end * 1000)
    step_hz = int(args.step * 1000)

    if step_hz <= 0:
        parser.error("Step size must be positive.")
    if start_hz > end_hz:
        parser.error("Start frequency must not be greater than end frequency.")

    workers = resolve_worker_count(args.parallel)

    if workers > 1 and verbose:
        print("Warning: -v is ignored in parallel mode.", file=sys.stderr)
        verbose = False

    source, is_memory = buffer_stream_if_needed(audio_file, workers)

    # If memfd was used, we need to close it later
    memfd_to_close = None
    if not is_memory and isinstance(source, str) and source.startswith("/proc/self/fd/"):
        memfd_to_close = int(source.rsplit('/', 1)[-1])

    try:
        # --- Full-band loudness ---
        print("Measuring full-band loudness ...", file=sys.stderr)
        try:
            if is_memory:
                loudness_full = get_loudness("", verbose=verbose, input_data=source,
                                             input_format=input_format)
            else:
                loudness_full = get_loudness(source, verbose=verbose,
                                             input_format=input_format)
        except Exception as exc:
            sys.exit(f"Error: {exc}")

        energy_full = 10 ** (loudness_full / 10.0)

        frequencies = list(range(start_hz, end_hz + 1, step_hz))
        if not frequencies:
            sys.exit("Error: no frequencies to scan.")

        results = []
        failures = []

        if workers == 1:
            for freq_hz in frequencies:
                print(f"Measuring at {freq_hz} Hz ...", file=sys.stderr)
                try:
                    if is_memory:
                        loudness_hf = get_loudness("", freq_hz, verbose=verbose,
                                                   input_data=source, input_format=input_format)
                    else:
                        loudness_hf = get_loudness(source, freq_hz, verbose=verbose,
                                                   input_format=input_format)
                    energy_hf = 10 ** (loudness_hf / 10.0)
                    score = max(0.0, min(1.0, energy_hf / energy_full))
                    results.append((freq_hz, score))
                except Exception as exc:
                    print(f"Error: {freq_hz} Hz failed: {exc}", file=sys.stderr)
                    failures.append(freq_hz)
        else:
            print(f"Scanning {len(frequencies)} frequencies using {workers} parallel jobs...",
                  file=sys.stderr)

            def job(freq):
                try:
                    if is_memory:
                        loudness = get_loudness("", freq, verbose=False,
                                                input_data=source, input_format=input_format)
                    else:
                        loudness = get_loudness(source, freq, verbose=False,
                                                input_format=input_format)
                    energy_hf = 10 ** (loudness / 10.0)
                    score = max(0.0, min(1.0, energy_hf / energy_full))
                    return (freq, score)
                except Exception as exc:
                    return (freq, str(exc), True)

            with ThreadPoolExecutor(max_workers=workers) as executor:
                future_to_freq = {executor.submit(job, f): f for f in frequencies}
                for future in as_completed(future_to_freq):
                    freq = future_to_freq[future]
                    try:
                        res = future.result()
                        if len(res) == 3 and res[2] is True:
                            failures.append(freq)
                            print(f"Error: {freq} Hz failed: {res[1]}", file=sys.stderr)
                        else:
                            results.append(res)
                    except Exception as exc:
                        failures.append(freq)
                        print(f"Error: unexpected error for {freq} Hz: {exc}", file=sys.stderr)

            results.sort(key=lambda x: x[0])

        if failures:
            print(f"\nScript aborted due to failed frequency measurements: {failures}", file=sys.stderr)
            sys.exit(1)

        print("crossover_hz,hf_score", flush=True)
        for freq_hz, score in results:
            print(f"{freq_hz},{score:.6f}", flush=True)

    finally:
        if memfd_to_close is not None:
            os.close(memfd_to_close)


if __name__ == "__main__":
    main()
