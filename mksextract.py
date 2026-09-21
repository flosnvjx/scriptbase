#!/usr/bin/env python3
"""
extract_mkv_tracks.py — Extract MKV subtitle tracks and attachments.

Synopsis:
    extract_mkv_tracks.py INPUT [INPUT ...] [-o OUTDIR]
                                  [--overwrite] [--continue-on-error]
                                  [--subdir-regex PATTERN]
                                  [--subdir-replace REPL]
                                  [--attachments-subdir NAME_OR_PATH]
                                  [--debug] [--]

INPUT may be one or more MKV files and/or directories (searched recursively).

End-of-options marker:
    Use "--" to stop option parsing. Everything after it is a positional
    INPUT, even if it begins with "-".

Output folder layout:
    Each MKV produces a folder under OUTDIR whose name is derived from the
    MKV stem. By default the stem is used verbatim; --subdir-regex and
    --subdir-replace apply re.sub() to it:

        # strip a "Show - S01E01 - " prefix
        --subdir-regex '^Show - ' --subdir-replace ''

        # regroup into a per-show subfolder (\\g<0> = whole match)
        --subdir-regex '^(.*?) - S\\d+E\\d+.*$' --subdir-replace '\\g<1>'

    Subtitles are written directly into that folder.

    Attachments go into --attachments-subdir, interpreted as follows:

        ""            flat, alongside subtitles
        relative      subfolder under the per-MKV folder
        absolute      honored as-is (shared across all MKVs)

    Relative values have '.', '..', and empty components stripped so a
    subfolder cannot escape OUTDIR.

Extraction strategy:
    For each MKV, this script invokes mkvextract ONCE with both the
    'tracks' and 'attachments' modes combined, so the container is read
    only a single pass. mkvextract natively supports mode chaining:

        mkvextract source.mkv tracks TID1:out1 TID2:out2 \\
                               attachments AID1:outA AID2:outB

    Attachment specs are always AID:path, never path:AID.

Debug:
    --debug prints the reconstructed argv, the parsed argument namespace,
    and every external command run (with its working directory) to stderr.

Subtitle filename format:
    trackid(trackname).LegacyLanguageTag[ietfLanguageTag].extension

    (trackname)        included only if the track has a name
    LegacyLanguageTag  falls back to "und" when unknown
    [ietfLanguageTag]  included only when the container specifies it

Note: any --sync delay applied when the MKV was authored is already
reflected in the subtitle timestamps inside the container, so extracted
subtitle files are correctly shifted and no delay annotation is needed.

Attachments are extracted with their original filenames (basename only).

Exit codes:
    0  all extractions succeeded
    2  no MKV inputs found
    3  an extraction failed (fail-fast default)
    4  required tools missing

Requires MKVToolNix (mkvmerge, mkvextract) on PATH.
Targets Linux, BSD, macOS (POSIX).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SUBTITLE_EXT = {
    "S_TEXT/UTF8": ".srt",
    "S_TEXT/ASS": ".ass",
    "S_TEXT/SSA": ".ssa",
    "S_TEXT/WEBVTT": ".vtt",
    "S_TEXT/USF": ".usf",
    "S_TEXT/ASCII": ".srt",
    "S_HDMV/PGS": ".sup",
    "S_VOBSUB": ".sub",
    "S_DVBSUB": ".sub",
}

REQUIRED_TOOLS = ("mkvmerge", "mkvextract")

EXIT_OK = 0
EXIT_NO_INPUT = 2
EXIT_EXTRACT_FAILED = 3
EXIT_MISSING_TOOL = 4

# Conservative ARG_MAX budget for a single mkvextract invocation.
# POSIX guarantees only 4096, but real Linux is 128K, Darwin 256K,
# FreeBSD 512K.  We use 96 KiB as a safe floor that works everywhere
# and subtract the environment size at runtime.
DEFAULT_ARG_BUDGET = 96 * 1024


class ExtractError(RuntimeError):
    """Raised when a single extraction step fails."""


# --------------------------------------------------------------------------- #
# debug helpers
# --------------------------------------------------------------------------- #

DEBUG = False


def set_debug(enabled: bool) -> None:
    global DEBUG
    DEBUG = enabled


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[debug] {msg}", file=sys.stderr)


def debug_run(cmd: list[str], cwd: Path | None = None) -> None:
    if DEBUG:
        line = shlex.join(str(c) for c in cmd)
        if cwd is not None:
            line += f"  (cwd={cwd})"
        debug(f"run: {line}")


# --------------------------------------------------------------------------- #
# ARG_MAX safety
# --------------------------------------------------------------------------- #

def arg_budget() -> int:
    """Conservative per-invocation ARG_MAX budget.

    Reads SC_ARG_MAX when available, subtracts the environment size and
    a slack margin, and caps at DEFAULT_ARG_BUDGET so a single MKV with
    an absurd number of tracks still stays within what every POSIX
    system can pass to exec().
    """
    try:
        arg_max = os.sysconf("SC_ARG_MAX")
    except (AttributeError, OSError, ValueError):
        arg_max = 128 * 1024
    env_bytes = sum(len(k) + len(v) + 2 for k, v in os.environ.items())
    budget = arg_max - env_bytes - 8192
    return max(4096, min(budget, DEFAULT_ARG_BUDGET))


def fits_arg_budget(argv: list[str], budget: int) -> bool:
    total = 0
    for item in argv:
        total += len(item.encode("utf-8", "surrogateescape")) + 1
        if total > budget:
            return False
    return True


# --------------------------------------------------------------------------- #
# tool / metadata helpers
# --------------------------------------------------------------------------- #

def check_tools() -> None:
    missing = [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
    if missing:
        sys.exit(
            "error: required tool(s) not found on PATH: "
            + ", ".join(missing)
            + "\n       install MKVToolNix and try again."
        )


def identify(mkv: Path) -> dict:
    """Return mkvmerge -J JSON for an MKV file.

    mkvmerge returns exit code 1 for warnings but still emits valid JSON;
    treat 0 and 1 as success, anything else as fatal.
    """
    cmd = ["mkvmerge", "-J", str(mkv.resolve())]
    debug_run(cmd)
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode not in (0, 1):
        raise ExtractError(
            f"mkvmerge -J failed on {mkv} (exit {proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise ExtractError(f"cannot parse mkvmerge output for {mkv}: {e}") from e


# --------------------------------------------------------------------------- #
# path / filename construction
# --------------------------------------------------------------------------- #

def sanitize_part(value: str) -> str:
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value)
    return value.strip()


def sanitize_attachment_name(name: str) -> str:
    """Keep only the basename (no path traversal, no embedded separators)."""
    return re.split(r"[\\/]", name)[-1] or "attachment"


def safe_relpath(s: str) -> str:
    """Normalize a user-derived relative path.

    Drops empty, '.', and '..' components so a regex replacement or a
    subfolder name cannot escape OUTDIR. Returns '' if nothing remains.
    """
    parts = [p for p in re.split(r"[\\/]+", s) if p and p not in (".", "..")]
    return "/".join(parts)


def output_subdir(mkv: Path, pattern: str | None, replacement: str) -> str:
    """Derive the per-MKV output folder from the MKV stem."""
    stem = mkv.stem
    if pattern is None:
        return safe_relpath(stem)
    try:
        result = re.sub(pattern, replacement, stem)
    except re.error as e:
        raise ExtractError(f"invalid --subdir-regex {pattern!r}: {e}") from e
    result = safe_relpath(result)
    if not result:
        raise ExtractError(
            f"--subdir-regex {pattern!r} produced an empty folder for {mkv}"
        )
    return result


def resolve_attachments_dir(value: str, dest: Path) -> tuple[Path, str]:
    """Resolve --attachments-subdir against the per-MKV folder.

    Returns (absolute_dir, spec_prefix).

      ""            -> (dest, "")             flat, alongside subtitles
      absolute path -> (normpath(value), normpath(value))
                                             honored as-is
      relative path -> (dest/safe, safe)      '.', '..', '' stripped
    """
    if value == "":
        return dest, ""

    p = Path(value)
    if p.is_absolute():
        normalized = os.path.normpath(value)
        return Path(normalized), normalized

    safe = safe_relpath(value)
    if not safe:
        return dest, ""
    return dest / safe, safe


def subtitle_extension(track: dict) -> str:
    codec_id = track.get("properties", {}).get("codec_id", "")
    if codec_id in SUBTITLE_EXT:
        return SUBTITLE_EXT[codec_id]
    if "/" in codec_id:
        suffix = re.sub(r"[^a-z0-9]+", "_", codec_id.split("/")[-1].lower()).strip("_")
        if suffix:
            return "." + suffix
    return ".sub"


def subtitle_filename(track: dict) -> str:
    """Build 'trackid(trackname).legacy[ietf].ext'."""
    props = track.get("properties", {})
    tid = track["id"]
    name = sanitize_part(props.get("track_name") or "")
    legacy = sanitize_part(props.get("language") or "und") or "und"
    ietf = sanitize_part(props.get("language_ietf") or "")

    parts = [str(tid)]
    if name:
        parts.append(f"({name})")
    parts.append(f".{legacy}")
    if ietf:
        parts.append(f"[{ietf}]")
    parts.append(subtitle_extension(track))
    return "".join(parts)


# --------------------------------------------------------------------------- #
# extraction
# --------------------------------------------------------------------------- #

def run_mkvextract(args: list[str], cwd: Path) -> None:
    debug_run(args, cwd=cwd)
    try:
        proc = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    except OSError as e:
        raise ExtractError(f"cannot launch mkvextract: {e}") from e

    if proc.returncode != 0:
        raise ExtractError(
            f"mkvextract exit {proc.returncode}: "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )


def plan_all(
    info: dict,
    dest: Path,
    att_dir: Path,
    att_prefix: str,
    overwrite: bool,
):
    """Return planning tuples.

    sub_pairs entries are 'TID:filename' — the filename is relative to dest.
    att_pairs entries are 'AID:path' where path is one of:
      - bare filename              (flat: att_prefix == "")
      - relative path under dest   (att_prefix is relative)
      - absolute path              (att_prefix is absolute)
    """
    sub_pairs: list[str] = []
    sub_targets: list[Path] = []

    for track in info.get("tracks", []):
        if track.get("type") != "subtitles":
            continue
        tid = track["id"]
        filename = subtitle_filename(track)
        target = dest / filename
        if target.exists() and not overwrite:
            print(f"  skip existing subtitle: {target}")
            continue
        sub_pairs.append(f"{tid}:{filename}")
        sub_targets.append(target)

    att_pairs: list[str] = []
    att_targets: list[Path] = []

    for att in info.get("attachments", []):
        att_id = att["id"]
        original = (
            att.get("file_name")
            or att.get("properties", {}).get("file_name")
            or f"attachment_{att_id}"
        )
        filename = sanitize_attachment_name(original)

        # AID:path — never path:AID.
        spec_path = f"{att_prefix}/{filename}" if att_prefix else filename
        target = att_dir / filename

        if target.exists() and not overwrite:
            print(f"  skip existing attachment: {target}")
            continue

        att_pairs.append(f"{att_id}:{spec_path}")
        att_targets.append(target)

    return sub_pairs, sub_targets, att_pairs, att_targets


def build_combined_argv(
    mkv_path: str,
    sub_pairs: list[str],
    att_pairs: list[str],
) -> list[str]:
    """mkvextract <mkv> [tracks TID:out ...] [attachments AID:path ...]."""
    argv = ["mkvextract", mkv_path]
    if sub_pairs:
        argv.append("tracks")
        argv.extend(sub_pairs)
    if att_pairs:
        argv.append("attachments")
        argv.extend(att_pairs)
    return argv


def ensure_parents(targets: list[Path]) -> None:
    for t in targets:
        t.parent.mkdir(parents=True, exist_ok=True)


def process(
    mkv: Path,
    out_root: Path,
    overwrite: bool,
    continue_on_error: bool,
    subdir_regex: str | None,
    subdir_replace: str,
    attachments_subdir: str,
) -> int:
    print(f"Processing: {mkv}")

    sub_dirname = output_subdir(mkv, subdir_regex, subdir_replace)
    dest = out_root / sub_dirname
    dest.mkdir(parents=True, exist_ok=True)
    debug(f"output folder: {dest.resolve()}")

    att_dir, att_prefix = resolve_attachments_dir(attachments_subdir, dest)

    info = identify(mkv)

    sub_pairs, sub_targets, att_pairs, att_targets = plan_all(
        info, dest, att_dir, att_prefix, overwrite,
    )

    if not sub_pairs and not att_pairs:
        debug("nothing to extract")
        return 0

    if att_pairs:
        att_dir.mkdir(parents=True, exist_ok=True)
        debug(f"attachments folder: {att_dir.resolve()}")

    ensure_parents(sub_targets)
    ensure_parents(att_targets)

    mkv_path = str(mkv.resolve())
    cmd = build_combined_argv(mkv_path, sub_pairs, att_pairs)

    if not fits_arg_budget(cmd, arg_budget()):
        debug("combined argv exceeds ARG budget; falling back to per-item")
        return _process_per_item(
            mkv_path, sub_pairs, sub_targets, att_pairs, att_targets,
            dest, continue_on_error,
        )

    try:
        run_mkvextract(cmd, cwd=dest)
    except ExtractError as e:
        if not continue_on_error:
            raise ExtractError(f"combined extraction failed: {e}") from e
        print(
            f"  error: combined extraction failed, retrying individually: {e}",
            file=sys.stderr,
        )
        return _process_per_item(
            mkv_path, sub_pairs, sub_targets, att_pairs, att_targets,
            dest, continue_on_error,
        )

    count = 0
    for t in sub_targets:
        print(f"  subtitle: {t}")
        count += 1
    for t in att_targets:
        print(f"  attachment: {t}")
        count += 1
    return count


def _process_per_item(
    mkv_path: str,
    sub_pairs: list[str],
    sub_targets: list[Path],
    att_pairs: list[str],
    att_targets: list[Path],
    dest: Path,
    continue_on_error: bool,
) -> int:
    """Fallback when combined argv is too large, or to isolate a failure.

    Runs each pair as its own mkvextract invocation from dest, so the
    relative paths inside the pairs resolve identically to the combined
    call. Absolute attachment paths in pairs remain absolute either way.
    """
    count = 0

    for pair, target in zip(sub_pairs, sub_targets):
        try:
            run_mkvextract(["mkvextract", mkv_path, "tracks", pair], cwd=dest)
            print(f"  subtitle: {target}")
            count += 1
        except ExtractError as e:
            if not continue_on_error:
                raise
            print(f"  error: {target}: {e}", file=sys.stderr)

    for pair, target in zip(att_pairs, att_targets):
        try:
            run_mkvextract(
                ["mkvextract", mkv_path, "attachments", pair], cwd=dest
            )
            print(f"  attachment: {target}")
            count += 1
        except ExtractError as e:
            if not continue_on_error:
                raise
            print(f"  error: {target}: {e}", file=sys.stderr)

    return count


# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #

def collect_inputs(items: list[str]) -> list[Path]:
    files: list[Path] = []
    for item in items:
        path = Path(item)
        if path.is_dir():
            files.extend(sorted(path.rglob("*.mkv")))
        elif path.is_file():
            files.append(path)
        else:
            print(f"warn: not found: {path}", file=sys.stderr)
    return files


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "inputs", nargs="+",
        help="MKV files and/or directories (use '--' before names starting with '-')",
    )
    ap.add_argument(
        "-o", "--output", default="extracted",
        help="Output root directory (default: %(default)s)",
    )
    ap.add_argument(
        "--overwrite", action="store_true",
        help="Overwrite existing extracted files",
    )
    ap.add_argument(
        "--continue-on-error", action="store_true",
        help="Keep processing after a failure; a failed combined call is "
             "retried per item so the culprit is named "
             "(default: abort on first failure)",
    )
    ap.add_argument(
        "--subdir-regex", default=None, metavar="PATTERN",
        help="Regex applied to each MKV stem (via re.sub) to derive the "
             "per-MKV output folder name. Default: no regex, use the stem.",
    )
    ap.add_argument(
        "--subdir-replace", default="", metavar="REPL",
        help="Replacement for --subdir-regex (default: empty; use \\\\g<0> "
             "in the shell to keep the matched text)",
    )
    ap.add_argument(
        "--attachments-subdir", default="attachments", metavar="NAME_OR_PATH",
        help="Where to write attachments, relative to the per-MKV folder "
             "(default: %(default)s). Pass '' to place them alongside "
             "subtitles. An absolute path is honored as-is; relative paths "
             "have '.', '..', and empty components stripped for safety.",
    )
    ap.add_argument(
        "--debug", action="store_true",
        help="Print argv, parsed args, and every external command to stderr",
    )
    args = ap.parse_args()

    set_debug(args.debug)

    if args.debug:
        debug(f"argv: {shlex.join(sys.argv)}")
        debug(f"parsed: {vars(args)}")

    check_tools()

    mkv_files = collect_inputs(args.inputs)
    debug(f"resolved inputs: {len(mkv_files)} MKV file(s)")
    if not mkv_files:
        print("No MKV files found.", file=sys.stderr)
        return EXIT_NO_INPUT

    out_root = Path(args.output)
    out_root.mkdir(parents=True, exist_ok=True)
    debug(f"output root: {out_root.resolve()}")

    total = 0
    for mkv in mkv_files:
        try:
            total += process(
                mkv, out_root, args.overwrite, args.continue_on_error,
                args.subdir_regex, args.subdir_replace,
                args.attachments_subdir,
            )
        except ExtractError as e:
            print(f"  error: {e}", file=sys.stderr)
            if not args.continue_on_error:
                print(
                    f"aborting (use --continue-on-error to skip failures). "
                    f"extracted={total}",
                    file=sys.stderr,
                )
                return EXIT_EXTRACT_FAILED
            print("  continuing (--continue-on-error)", file=sys.stderr)

    print(f"\nDone. extracted={total}")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
