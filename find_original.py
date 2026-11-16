#!/usr/bin/env python3
"""NAME
    find_original.py — identify the most likely untranscoded source among
                       several video files

SYNOPSIS
    find_original.py [OPTIONS] FILE [FILE ...]

DESCRIPTION
    Given two or more video files that originate from the same upload but
    may have undergone different levels of platform processing (e.g.
    multiple Bilibili format IDs), this tool runs pairwise quality
    comparisons and combines them with file-size / bitrate heuristics to
    rank the files and pick the one most likely to be the uploader's
    original, untranscoded copy.

    It runs three stages:

      A. Probe
         Collect duration, resolution, bitrate and file size with ffprobe.

      B. Pairwise PSNR
         Compute PSNR for every pair of files. A file whose average PSNR
         against all other files is lowest is the strongest candidate
         for the original — it is the "odd one out" — especially if its
         bitrate and file size are also the highest.

      C. Verification
         Using the best candidate as reference, compute VMAF (and
         optionally SSIM) for every other file. Scores clearly below
         the thresholds confirm that those files are degraded copies.

    The final ranking combines:
      - lowest average pairwise PSNR (the file is least like the rest), and
      - highest bitrate / file size (the file retains the most information).

    If these two signals disagree, the tool reports an ambiguous result
    and prints the top two candidates for manual review.

OPTIONS
    -h, --help
        Show this help message and exit.

    -v, --verbose
        Print ffmpeg / ffprobe stderr to the console. Useful for debugging
        pipeline failures.

    --no-ssim
        Skip the SSIM verification stage (stage C, part 2). SSIM is cheap
        but redundant with VMAF for most content; skip it on low-end
        Termux devices.

    --psnr-threshold DB
        Minimum average-PSNR gap (in dB) for a file to count as "different
        from the rest". If no file is at least this much lower than the
        others, the tool reports that it cannot separate them by PSNR and
        falls back to the bitrate tiebreak alone. Default: 1.5

    --vmaf-threshold SCORE
        VMAF score below which a file is considered visibly degraded
        relative to the reference candidate. Default: 93

    --ssim-threshold SCORE
        Same as --vmaf-threshold but for SSIM. Default: 0.95

    --jobs N
        Number of parallel ffmpeg processes. Default:
        max(1, cpu_count // 2).

        Thread budget: the tool tries to keep the total number of threads
        active across all child ffmpeg processes near cpu_count. Each
        process is given
            threads_per_input = max(1, cpu_count // (2 * jobs))
        on each input, plus a single-threaded quality filter. Choose a
        higher --jobs for more parallel pairs (faster wall-clock, some
        oversubscription); choose a lower --jobs for tighter CPU control.
        Values above 4*cpu_count are clamped.

    --sequential
        Shorthand for --jobs 1 with all available cores given to each
        ffmpeg process. Use on memory-constrained devices or when running
        under a scheduler that already limits CPU usage.

    --json PATH
        Write the full result (per-pair PSNR, per-file aggregate metrics,
        VMAF/SSIM scores and final verdict) to a JSON file at PATH.

FILES
    Two or more video files that originate from the same source video.
    Any container/codec ffprobe supports (mp4, mkv, flv, webm, ...).
    Files with different extensions are fine as long as they decode.

EXAMPLES
    Compare three downloads from three Bilibili format IDs:

        find_original.py bili_127.mp4 bili_120.mp4 bili_116.mp4

    Same, but run more pairs in parallel and save the JSON report:

        find_original.py --jobs 8 --json result.json *.mp4

    Skip SSIM for a faster run on a phone, and go one-at-a-time:

        find_original.py --sequential --no-ssim bili_*.mp4

EXIT STATUS
    0    Success — a single clear candidate was identified.
    1    Success — best candidate is ambiguous (signals conflict);
         results printed for manual review.
    2    Usage error (fewer than two files, ffmpeg/ffprobe missing, ...).

NOTES
    - Requires ffmpeg and ffprobe on PATH. VMAF stage requires an ffmpeg
      build with libvmaf enabled.
    - When a pair has mismatched resolution, both files are scaled to the
      lower of the two resolutions in the filter graph before PSNR is
      computed. This costs time but makes the comparison possible.
    - PSNR is the fast stage; VMAF and SSIM are verification stages and
      are noticeably slower. On a weak Termux device, prefer --no-ssim
      and run VMAF only on the final candidate.
"""

import argparse
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

__version__ = "0.1.0"


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def die(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg):
    print(f"warning: {msg}", file=sys.stderr)


def check_tools():
    missing = [t for t in ("ffmpeg", "ffprobe") if shutil.which(t) is None]
    if missing:
        die(f"required tool(s) not found on PATH: {', '.join(missing)}")


def run_cmd(cmd, verbose=False):
    if verbose:
        print("+ " + " ".join(cmd), file=sys.stderr)
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError as e:
        raise RuntimeError(f"failed to execute {cmd[0]}: {e}")
    except OSError as e:
        raise RuntimeError(f"OS error executing {cmd[0]}: {e}")


def _to_int(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def _to_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def fmt_num(v, nd=2):
    if v is None:
        return "n/a"
    if isinstance(v, float) and v == float("inf"):
        return "inf"
    return f"{v:.{nd}f}"


# --------------------------------------------------------------------------
# stage A — probe
# --------------------------------------------------------------------------

def probe(path):
    if not os.path.isfile(path):
        raise RuntimeError(f"not a regular file: {path}")
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,codec_name,bit_rate,duration",
        "-show_entries", "format=duration,bit_rate,size",
        "-of", "json", str(path),
    ]
    r = run_cmd(cmd)
    if r.returncode != 0:
        raise RuntimeError(f"ffprobe failed for {path}: {r.stderr.strip()[-400:]}")
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"ffprobe returned invalid JSON for {path}: {e}")

    streams = data.get("streams") or []
    if not streams:
        raise RuntimeError(f"no video stream in {path}")
    v = streams[0]
    fmt = data.get("format") or {}

    width = _to_int(v.get("width"))
    height = _to_int(v.get("height"))
    if not width or not height:
        raise RuntimeError(f"could not determine video resolution for {path}")

    try:
        size = os.path.getsize(path)
    except OSError as e:
        raise RuntimeError(f"stat failed for {path}: {e}")

    duration = _to_float(fmt.get("duration")) or _to_float(v.get("duration"))
    bitrate = _to_int(v.get("bit_rate")) or _to_int(fmt.get("bit_rate"))
    if not bitrate and duration and duration > 0:
        bitrate = int(size * 8 / duration)

    return {
        "path": str(path),
        "width": width,
        "height": height,
        "size": size,
        "duration": duration,
        "bitrate": bitrate,
        "codec": v.get("codec_name"),
    }


# --------------------------------------------------------------------------
# filter graph construction
# --------------------------------------------------------------------------

def _target_res(a, b):
    if a["width"] * a["height"] <= b["width"] * b["height"]:
        return a["width"], a["height"]
    return b["width"], b["height"]


def _pair_filter(a, b, metric, extra=""):
    if (a["width"], a["height"]) == (b["width"], b["height"]):
        return f"[0:v][1:v]{metric}{extra}"
    tw, th = _target_res(a, b)
    s = f"scale={tw}:{th}"
    return f"[0:v]{s}[a];[1:v]{s}[b];[a][b]{metric}{extra}"


# --------------------------------------------------------------------------
# metric runners
# --------------------------------------------------------------------------

def psnr_pair(a, b, threads, verbose=False):
    """PSNR(a, b) in dB. Symmetric: order does not matter."""
    filt = _pair_filter(a, b, "psnr")
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info",
        "-threads", str(threads), "-i", a["path"],
        "-threads", str(threads), "-i", b["path"],
        "-lavfi", filt, "-f", "null", "-",
    ]
    r = run_cmd(cmd, verbose=verbose)
    if r.returncode != 0:
        raise RuntimeError(
            f"ffmpeg PSNR failed ({a['path']} vs {b['path']}): "
            f"{r.stderr.strip()[-400:]}"
        )
    m = re.search(r"average:\s*([0-9.]+|inf)", r.stderr)
    if not m:
        raise RuntimeError(
            f"could not parse PSNR output for {a['path']} vs {b['path']}"
        )
    s = m.group(1)
    return float("inf") if s == "inf" else float(s)


def vmaf_pair(distorted, reference, threads, verbose=False):
    """VMAF(distorted | reference). Direction matters."""
    filt = _pair_filter(
        distorted, reference, "libvmaf", f"=n_threads={max(1, threads)}"
    )
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info",
        "-threads", str(threads), "-i", distorted["path"],
        "-threads", str(threads), "-i", reference["path"],
        "-lavfi", filt, "-f", "null", "-",
    ]
    r = run_cmd(cmd, verbose=verbose)
    if r.returncode != 0:
        raise RuntimeError(
            f"ffmpeg VMAF failed ({distorted['path']} vs {reference['path']}): "
            f"{r.stderr.strip()[-400:]}"
        )
    m = re.search(r"VMAF score:\s*([0-9.]+)", r.stderr)
    if not m:
        raise RuntimeError(
            f"could not parse VMAF output for "
            f"{distorted['path']} vs {reference['path']}"
        )
    return float(m.group(1))


def ssim_pair(a, b, threads, verbose=False):
    """SSIM(a, b). Symmetric."""
    filt = _pair_filter(a, b, "ssim")
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info",
        "-threads", str(threads), "-i", a["path"],
        "-threads", str(threads), "-i", b["path"],
        "-lavfi", filt, "-f", "null", "-",
    ]
    r = run_cmd(cmd, verbose=verbose)
    if r.returncode != 0:
        raise RuntimeError(
            f"ffmpeg SSIM failed ({a['path']} vs {b['path']}): "
            f"{r.stderr.strip()[-400:]}"
        )
    m = re.search(r"All:\s*([0-9.]+)", r.stderr)
    if not m:
        raise RuntimeError(
            f"could not parse SSIM output for {a['path']} vs {b['path']}"
        )
    return float(m.group(1))


# --------------------------------------------------------------------------
# stage B — parallel pairwise PSNR
# --------------------------------------------------------------------------

def run_psnr_matrix(files, jobs, threads, verbose):
    n = len(files)
    pairs = list(itertools.combinations(range(n), 2))
    matrix = [[None] * n for _ in range(n)]
    for i in range(n):
        matrix[i][i] = float("inf")

    errors = []

    def worker(pair):
        i, j = pair
        return (i, j, psnr_pair(files[i], files[j], threads, verbose))

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        futures = {ex.submit(worker, p): p for p in pairs}
        for fut in as_completed(futures):
            p = futures[fut]
            try:
                i, j, val = fut.result()
                matrix[i][j] = matrix[j][i] = val
            except Exception as e:  # noqa: BLE001
                errors.append((p, e))

    if errors:
        detail = "\n".join(f"  pair {p}: {e}" for p, e in errors)
        raise RuntimeError(
            f"{len(errors)} of {len(pairs)} PSNR pair(s) failed:\n{detail}"
        )

    return matrix


# --------------------------------------------------------------------------
# ranking
# --------------------------------------------------------------------------

def rank_candidates(files, matrix, threshold):
    n = len(files)
    avg = []
    for i in range(n):
        vals = [
            matrix[i][j] for j in range(n)
            if j != i and matrix[i][j] is not None
        ]
        finite = [v for v in vals if v != float("inf")]
        avg.append(sum(finite) / len(finite) if finite else float("inf"))

    order = sorted(range(n), key=lambda i: avg[i])
    psnr_idx = order[0]
    second = avg[order[1]] if n > 1 else float("inf")
    if second == float("inf"):
        psnr_gap = float("inf")
    else:
        psnr_gap = second - avg[psnr_idx]
    psnr_strong = psnr_gap == float("inf") or psnr_gap >= threshold

    br_idx = max(range(n), key=lambda i: files[i]["bitrate"] or 0)

    return {
        "avg_psnr": avg,
        "psnr_idx": psnr_idx,
        "psnr_gap": psnr_gap,
        "psnr_strong": psnr_strong,
        "bitrate_idx": br_idx,
        "order": order,
    }


# --------------------------------------------------------------------------
# stage C — parallel VMAF (+SSIM) verification
# --------------------------------------------------------------------------

def run_verification(candidate_idx, files, jobs, threads, use_ssim, verbose):
    others = [i for i in range(len(files)) if i != candidate_idx]

    def worker(i):
        result = {"index": i, "vmaf": None, "ssim": None}
        try:
            result["vmaf"] = vmaf_pair(
                files[i], files[candidate_idx], threads, verbose
            )
        except Exception as e:  # noqa: BLE001
            result["vmaf_error"] = str(e)
        if use_ssim:
            try:
                result["ssim"] = ssim_pair(
                    files[i], files[candidate_idx], threads, verbose
                )
            except Exception as e:  # noqa: BLE001
                result["ssim_error"] = str(e)
        return result

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        return list(ex.map(worker, others))


# --------------------------------------------------------------------------
# arg parsing
# --------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(add_help=False, prog="find_original.py")
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--no-ssim", action="store_true")
    p.add_argument("--psnr-threshold", type=float, default=1.5, metavar="DB")
    p.add_argument("--vmaf-threshold", type=float, default=93.0, metavar="SCORE")
    p.add_argument("--ssim-threshold", type=float, default=0.95, metavar="SCORE")
    p.add_argument("--jobs", type=int, default=None, metavar="N")
    p.add_argument("--sequential", action="store_true")
    p.add_argument("--json", metavar="PATH")
    p.add_argument("files", nargs="*", metavar="FILE")

    args = p.parse_args(argv)
    if args.help:
        sys.stdout.write(__doc__)
        sys.exit(0)
    if args.jobs is not None and args.jobs < 1:
        die("--jobs must be a positive integer")
    return args


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main(argv=None):
    args = parse_args(argv)
    check_tools()

    if len(args.files) < 2:
        die("need at least two input files")

    seen = set()
    for f in args.files:
        rp = os.path.realpath(f)
        if rp in seen:
            warn(f"duplicate input file: {f}")
        seen.add(rp)

    cpu = os.cpu_count() or 1
    if args.sequential:
        jobs = 1
        threads_per_input = max(1, cpu // 2)
    else:
        jobs = args.jobs if args.jobs is not None else max(1, cpu // 2)
        jobs = max(1, min(jobs, cpu * 4))
        threads_per_input = max(1, cpu // (2 * jobs))

    if args.verbose:
        print(
            f"# cpu={cpu} jobs={jobs} threads_per_input={threads_per_input} "
            f"-> peak_threads≈{jobs * (2 * threads_per_input + 1)}",
            file=sys.stderr,
        )

    # Stage A — probe
    files = []
    for f in args.files:
        try:
            files.append(probe(f))
        except Exception as e:  # noqa: BLE001
            die(f"probe failed: {e}")

    durations = [f["duration"] for f in files if f["duration"]]
    if durations and max(durations) - min(durations) > 0.1 * max(durations):
        warn(
            f"durations differ significantly across inputs "
            f"({min(durations):.2f}s .. {max(durations):.2f}s); "
            f"quality metrics will only compare the overlapping frames"
        )

    for i, f in enumerate(files):
        print(
            f"f{i}: {f['path']}  {f['width']}x{f['height']}  "
            f"codec={f['codec']}  bitrate={f['bitrate']}  "
            f"size={f['size']}  duration={fmt_num(f['duration'], 3)}s",
            file=sys.stderr,
        )

    # Stage B — PSNR matrix
    print(file=sys.stderr)
    print("running pairwise PSNR...", file=sys.stderr)
    try:
        matrix = run_psnr_matrix(files, jobs, threads_per_input, args.verbose)
    except Exception as e:  # noqa: BLE001
        die(f"PSNR stage failed: {e}", code=1)

    rank = rank_candidates(files, matrix, args.psnr_threshold)

    # Decide
    psnr_idx = rank["psnr_idx"] if rank["psnr_strong"] else None
    br_idx = rank["bitrate_idx"]
    if psnr_idx is not None and psnr_idx == br_idx:
        candidate, verdict = psnr_idx, "confident"
    elif psnr_idx is not None:
        candidate, verdict = psnr_idx, "ambiguous"
    else:
        candidate, verdict = br_idx, "psnr-weak"

    # Stage C — verification
    print("running verification...", file=sys.stderr)
    try:
        verification = run_verification(
            candidate, files, jobs, threads_per_input,
            use_ssim=not args.no_ssim, verbose=args.verbose,
        )
    except Exception as e:  # noqa: BLE001
        warn(f"verification stage failed: {e}")
        verification = []

    # Report
    n = len(files)
    print()
    print("=== pairwise PSNR matrix (dB) ===")
    print("        " + "  ".join(f"f{j:<8d}" for j in range(n)))
    for i in range(n):
        row = f"f{i:<6d}"
        for j in range(n):
            row += f"  {fmt_num(matrix[i][j], 2):>8s}"
        print(row)

    print()
    print("=== per-file aggregate ===")
    for i, f in enumerate(files):
        print(
            f"f{i}: {f['path']}\n"
            f"     avg_psnr={fmt_num(rank['avg_psnr'][i], 2)} dB   "
            f"bitrate={f['bitrate']}   size={f['size']}   "
            f"{f['width']}x{f['height']}"
        )

    print()
    print("=== candidate selection ===")
    print(
        f"psnr-best: f{rank['psnr_idx']}   "
        f"gap={fmt_num(rank['psnr_gap'], 2)} dB   "
        f"strong={rank['psnr_strong']}"
    )
    print(f"bitrate-best: f{br_idx}")

    if verification:
        print()
        print("=== verification (candidate f%d as reference) ===" % candidate)
        for v in verification:
            i = v["index"]
            parts = [f"f{i}:"]
            if v["vmaf"] is not None:
                tag = " [degraded]" if v["vmaf"] < args.vmaf_threshold else ""
                parts.append(f"VMAF={v['vmaf']:.2f}{tag}")
            elif v.get("vmaf_error"):
                parts.append(f"VMAF=ERROR ({v['vmaf_error'][:80]})")
            if v["ssim"] is not None:
                tag = " [degraded]" if v["ssim"] < args.ssim_threshold else ""
                parts.append(f"SSIM={v['ssim']:.4f}{tag}")
            elif v.get("ssim_error"):
                parts.append(f"SSIM=ERROR ({v['ssim_error'][:80]})")
            print("  " + "   ".join(parts))

    print()
    if verdict == "confident":
        print(
            f"=> most likely original: f{candidate} — {files[candidate]['path']}"
        )
    elif verdict == "ambiguous":
        print(
            f"=> ambiguous: PSNR favors f{candidate}, "
            f"bitrate favors f{br_idx}"
        )
        print(f"   manual review recommended:")
        print(f"     f{candidate}  {files[candidate]['path']}")
        print(f"     f{br_idx}     {files[br_idx]['path']}")
    else:
        print(
            "=> PSNR could not separate files; falling back to bitrate"
        )
        print(
            f"=> most likely original: f{candidate} — {files[candidate]['path']}"
        )

    # JSON report
    if args.json:
        def _json_safe(v):
            if v is None:
                return None
            if isinstance(v, float) and v == float("inf"):
                return "inf"
            return v

        payload = {
            "version": __version__,
            "files": [
                {
                    "index": i,
                    **{k: v for k, v in f.items()},
                    "avg_psnr": _json_safe(rank["avg_psnr"][i]),
                }
                for i, f in enumerate(files)
            ],
            "psnr_matrix": [
                [_json_safe(v) for v in row] for row in matrix
            ],
            "rank": {
                "psnr_idx": rank["psnr_idx"],
                "bitrate_idx": rank["bitrate_idx"],
                "psnr_gap": _json_safe(rank["psnr_gap"]),
                "psnr_strong": rank["psnr_strong"],
            },
            "candidate_idx": candidate,
            "verdict": verdict,
            "verification": verification,
            "params": {
                "psnr_threshold": args.psnr_threshold,
                "vmaf_threshold": args.vmaf_threshold,
                "ssim_threshold": args.ssim_threshold,
                "jobs": jobs,
                "threads_per_input": threads_per_input,
            },
        }
        try:
            with open(args.json, "w") as fp:
                json.dump(payload, fp, indent=2, default=str)
            print(f"\nJSON report written to {args.json}", file=sys.stderr)
        except OSError as e:
            warn(f"could not write JSON report: {e}")

    return 0 if verdict == "confident" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted\n")
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(1)