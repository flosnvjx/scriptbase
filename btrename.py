#!/usr/bin/env python3
"""
torrent-rename — restore filenames of local files using .torrent metadata.

Given one or more .torrent files and a set of local paths, computes the
intended name of each local file from the entries in the torrents, and
optionally renames them.

Matching
--------

Local files are first grouped by exact byte length. Every entry in a
torrent carries an exact length, and a local file whose size on disk
differs from an entry's is a different file, not a near-miss; no
tolerance is applied at this stage. What remains is ranked by a
weighted combination of two signals.

  name   Similarity between the local basename and the entry's
         basename, after both are normalized (casefold, runs of
         non-alphanumerics collapsed to a single space). The score is
         the ratio returned by difflib.SequenceMatcher over the
         normalized strings. This is the dominant signal: within a
         size group, entries usually differ only by a token or two,
         and SequenceMatcher orders them correctly without needing to
         know what those tokens mean.

  magic  The MIME type of the local file, probed with python-magic,
         compared against the entry's extension. Agreement scores 1.0,
         same top-level category (video/video, audio/audio, ...) scores
         0.6, an unrelated pair scores 0.0. A missing or unprobeable
         MIME scores 0.5 so that the signal neither rewards nor
         penalizes candidates when it has nothing to say. It is a
         scoring term, never a filter: a mislabeled extension lowers a
         candidate's rank but does not remove it from consideration.

The two signals are combined as w_name*name + w_magic*magic with
defaults (0.8, 0.2). Pairing is greedy over the combined score,
consuming each target and each entry at most once, and emitting only
pairs at or above --min-confidence.

Design notes
------------

Why exact size rather than fuzzy.

A torrent's length field is a byte count, not an estimate. Tolerating
a mismatch invites renaming the wrong file under a plausible-looking
heuristic. The cost of a false rename exceeds the cost of a missed one
by a wide margin, and a missed file is loud — it appears in the
"unmatched" list — while a false rename is silent.

Why MIME is a score and not a filter.

MIME and extension usually agree, and when they agree they tell you
nothing that distinguishes two equal-size, similarly-named candidates.
The informative case is a disagreement, and there a filter is too
strong a response: libmagic is a heuristic, container sniffing is
imperfect, and a ".srt" that libmagic calls text/plain is not an error.
Scoring keeps the signal — a conflicting candidate ranks below a
matching one — while letting the name evidence decide when it is
strong. The signal is optional on top of this: python-magic is
imported lazily, and if it is not installed the program warns once,
probes nothing, and treats every MIME as unknown.

Why text similarity rather than metadata parsing.

Filenames in a season pack differ by a token or two. Extracting
episode numbers, resolutions, and source tags from arbitrary names is
a large problem with many edge cases and a small payoff.
SequenceMatcher over normalized strings orders candidates correctly
for typical inputs and fails gracefully — uniformly low scores —
rather than confidently wrong (misparsed tokens) on unfamiliar naming
conventions.

Why an external fzf rather than a builtin TUI.

fzf is a mature interactive filter whose keybindings users already
know. Wrapping it via subprocess preserves those semantics; a curses
reimplementation would be a worse version of the same thing.

Why a single file.

The program should be auditable in one reading and installable by
copying it. The bencode decoder is inlined rather than pulled from a
package that has been unmaintained for a decade. python-magic is the
only runtime dependency, and only for the optional MIME term.

Help text is extracted from this docstring at import time by a regex
matching the === HELP === / === END HELP === markers. The text below
is the --help output verbatim; there is no second copy.

=== HELP ===
usage: torrent-rename [OPTIONS] PATH...

Rename files to match the entries inside one or more .torrent files.

Each PATH is either a file to consider, or a directory whose immediate
children are considered (with -r, all descendants recursively). Local
files are grouped against the pooled entries from every -i torrent by
exact size, then ranked by a weighted combination of filename
similarity and (when python-magic is available) MIME agreement. A
plan is printed before anything is touched. Renaming requires --apply.

required:
  -i, --input TORRENT    A .torrent file. Repeatable. Entries from all
                         torrents are pooled, so a season split across
                         multiple files works.

options:
  -r, --recursive        Recurse into directories. Without this, only
                         immediate children of a directory PATH are
                         considered.

      --apply            Perform the renames. Without this the plan is
                         printed and the program exits (dry-run).

      --fzf              Present each target's ranked candidates in the
                         fzf executable (found on PATH) and let the user
                         pick. Cancelling fzf skips that file. The
                         --min-confidence threshold does not apply here.

      --min-confidence F Minimum combined score to accept a match, in
                         [0,1]. Default 0.75.

      --weights W,W      Two comma-separated floats giving the
                         name,magic weights. Must sum to 1.0. Default
                         0.8,0.2. The magic weight is inert when MIME
                         probing is unavailable.

      --preserve-dirs    Recreate the torrent's directory structure
                         underneath each target's parent directory.
                         Without this, only the basename is changed.

  -v, --verbose          Print the per-signal score breakdown for every
                         match.

  -q, --quiet            Print only the final summary line.

  -h, --help             Show this help and exit.

requirements:
  python-magic and its libmagic backend are optional. When absent, the
  MIME term is skipped and matching relies on size and filename alone.
  fzf is required only when --fzf is used.

examples:
  torrent-rename -i ubuntu.torrent ~/Downloads/mystery.iso
  torrent-rename -i s01.torrent -r --apply ~/Downloads/show/
  torrent-rename -i s01.torrent -r --fzf ~/Downloads/show/
  torrent-rename -i a.torrent -i b.torrent --apply ~/Downloads/*.mkv
  torrent-rename -i s01.torrent --verbose ~/Downloads/show/ep1.mkv

exit codes:
  0  success (including a dry-run with no matches)
  1  runtime error: unreadable torrent, I/O failure during rename
  2  usage error

=== END HELP ===
"""

import argparse
import mimetypes
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Optional

_HELP_RE = re.compile(r"=== HELP ===\n(.*?)\n=== END HELP ===", re.S)
HELP_TEXT = _HELP_RE.search(__doc__).group(1).rstrip()


def _try_str(b):
    if isinstance(b, str):
        return b
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b


def bdecode(data):
    """Decode a bencoded byte string into dicts, lists, ints, strs, bytes.

    Keys and string values are decoded to str when valid UTF-8; otherwise
    they stay as bytes. Only info.name, info.length, and the file paths
    are ever read by this program, so a bytes name degrades to its repr
    in diagnostics rather than crashing.
    """
    def parse(pos):
        c = data[pos:pos + 1]
        if c == b"i":
            end = data.index(b"e", pos)
            return int(data[pos + 1:end]), end + 1
        if c == b"l":
            pos += 1
            out = []
            while data[pos:pos + 1] != b"e":
                v, pos = parse(pos)
                out.append(v)
            return out, pos + 1
        if c == b"d":
            pos += 1
            out = {}
            while data[pos:pos + 1] != b"e":
                k, pos = parse(pos)
                v, pos = parse(pos)
                out[_try_str(k)] = v
            return out, pos + 1
        if c.isdigit():
            colon = data.index(b":", pos)
            n = int(data[pos:colon])
            return data[colon + 1:colon + 1 + n], colon + 1 + n
        raise ValueError(f"bencode: unexpected byte {c!r} at offset {pos}")
    value, _ = parse(0)
    return value


@dataclass(frozen=True)
class Entry:
    """A single file inside a torrent.

    `rel` is the path relative to the torrent root, with the torrent's
    top-level name at index 0. This mirrors the layout a well-behaved
    client would produce on disk, and is what --preserve-dirs recreates.

    `source` is the originating .torrent path, kept for diagnostics.
    """
    rel: tuple
    length: int
    source: str

    @property
    def name(self):
        return self.rel[-1]

    @property
    def ext(self):
        n = self.name
        i = n.rfind(".")
        return n[i + 1:].lower() if i > 0 else ""


def parse_torrent(path):
    """Parse a .torrent file into a list of Entries.

    BEP-47 padding files are dropped. They are synthetic bytes inserted
    by the client to align piece boundaries, carry no real filename, and
    would otherwise appear as phantom zero-content candidates. The marker
    is either the 'p' bit in the file's `attr` field or a path component
    starting with '.pad'; both spellings have been observed.
    """
    raw = Path(path).read_bytes()
    root = bdecode(raw)
    info = root.get("info") if isinstance(root, dict) else None
    if not isinstance(info, dict):
        raise ValueError("no info dictionary")
    name = _try_str(info.get("name"))
    if not isinstance(name, str) or not name:
        raise ValueError("info.name missing or invalid")

    files = info.get("files")
    out = []
    if files:
        for f in files:
            attr = _try_str(f.get("attr", ""))
            if isinstance(attr, str) and "p" in attr:
                continue
            parts = tuple(_try_str(p) for p in f.get("path", ()))
            if not parts:
                continue
            if any(isinstance(p, str) and p.startswith(".pad") for p in parts):
                continue
            out.append(Entry((name,) + parts, int(f["length"]), str(path)))
    else:
        length = info.get("length")
        if length is None:
            raise ValueError("neither info.files nor info.length present")
        out.append(Entry((name,), int(length), str(path)))
    return out


@dataclass(frozen=True)
class Target:
    """A local file under consideration, with its probed metadata.

    mime is Optional. It is None whenever MIME probing is unavailable
    (python-magic not installed) or has failed for this particular file
    (unreadable, unrecognized format). None makes the magic term score
    neutral; it never disqualifies the target.
    """
    path: Path
    size: int
    mime: Optional[str]

    @property
    def name(self):
        return self.path.name

    @property
    def ext(self):
        n = self.name
        i = n.rfind(".")
        return n[i + 1:].lower() if i > 0 else ""


_magic_instance = None
_magic_warned = False


def probe_mime(path):
    """Return the MIME type of a file via python-magic, or None.

    python-magic is optional. On first use, the import is attempted; if
    it fails, a single warning is printed to stderr and every subsequent
    call returns None without retrying. Per-file probing failures also
    return None. Callers must treat None as "no information", not as a
    negative signal.
    """
    global _magic_instance, _magic_warned
    if _magic_instance is None:
        if _magic_warned:
            return None
        try:
            import magic
        except ImportError:
            print("torrent-rename: python-magic not available; "
                  "MIME scoring disabled", file=sys.stderr)
            _magic_warned = True
            return None
        try:
            _magic_instance = magic.Magic(mime=True)
        except Exception as e:
            print(f"torrent-rename: libmagic init failed ({e}); "
                  "MIME scoring disabled", file=sys.stderr)
            _magic_warned = True
            return None
    try:
        return _magic_instance.from_file(str(path))
    except Exception:
        return None


_NORM = re.compile(r"[^a-z0-9]+")


def _norm(s):
    return _NORM.sub(" ", s.casefold()).strip()


def name_score(a, b):
    a, b = _norm(a), _norm(b)
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


_VIDEO_EXTS = frozenset("mkv mp4 m4v mov avi wmv flv webm ts m2ts mpg mpeg ogv".split())
_AUDIO_EXTS = frozenset("mp3 flac ogg oga wav m4a aac opus wma ape mka".split())
_IMAGE_EXTS = frozenset("jpg jpeg png gif webp bmp tiff svg heic".split())
_TEXT_EXTS = frozenset("txt nfo srt sub ass vtt md log cue sfv".split())

_CATEGORIES = {
    "video": _VIDEO_EXTS,
    "audio": _AUDIO_EXTS,
    "image": _IMAGE_EXTS,
    "text": _TEXT_EXTS,
}


def magic_score(mime, ext):
    """Score a probed MIME against an entry's extension, in [0,1].

    1.0 when the extension is listed for the MIME by mimetypes (or, for
    MIMEs mimetypes does not know — matroska, hevc-in-mp4 — when the
    extension shares the MIME's top-level category). 0.6 when the two
    share only a category via the builtin tables. 0.0 when they are
    unrelated. 0.5 when either side is unknown, so that missing
    information is neutral rather than punitive.

    A MIME/extension conflict lowers a candidate's rank but does not
    remove it; the name term can still carry the pair over the
    threshold when the evidence is strong.
    """
    if not mime or not ext:
        return 0.5
    known = {e.lstrip(".").lower() for e in mimetypes.guess_all_extensions(mime) or ()}
    if ext in known:
        return 1.0
    cat = mime.split("/", 1)[0]
    if ext in _CATEGORIES.get(cat, ()):
        return 0.6
    return 0.0


def combined_score(target, entry, weights):
    ns = name_score(target.name, entry.name)
    ms = magic_score(target.mime, entry.ext)
    wn, wm = weights
    return wn * ns + wm * ms, ns, ms


def match(targets, entries, weights, min_conf):
    """Greedy assignment over exact-size groups, ranked by combined score.

    Entries are bucketed by length so that each target only considers
    entries whose byte count matches exactly. Every surviving pair is
    scored; pairs are consumed in descending (score, target, entry)
    order, so each target and each entry is used at most once, and the
    result is deterministic across runs and platforms. Pairs below
    min_conf are dropped rather than emitted.
    """
    by_size = {}
    for ei, e in enumerate(entries):
        by_size.setdefault(e.length, []).append(ei)

    scored = []
    for ti, t in enumerate(targets):
        for ei in by_size.get(t.size, ()):
            s, ns, ms = combined_score(t, entries[ei], weights)
            scored.append((s, ti, ei, ns, ms))
    scored.sort(reverse=True)

    used_t, used_e = set(), set()
    out = []
    for s, ti, ei, ns, ms in scored:
        if ti in used_t or ei in used_e:
            continue
        if s < min_conf:
            break
        used_t.add(ti)
        used_e.add(ei)
        out.append((ti, ei, s, ns, ms))
    return out


@dataclass
class Rename:
    target: Target
    entry: Entry
    dst: Path
    score: float
    name_score: float
    magic_score: float


def _dst_for(target, entry, preserve_dirs):
    if preserve_dirs:
        return target.path.parent.joinpath(*entry.rel)
    return target.path.parent / entry.name


def build_plan(targets, entries, weights, min_conf, preserve_dirs):
    return [
        Rename(targets[ti], entries[ei],
               _dst_for(targets[ti], entries[ei], preserve_dirs),
               s, ns, ms)
        for ti, ei, s, ns, ms in match(targets, entries, weights, min_conf)
    ]


def human(n):
    f = float(n)
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if f < 1024 or u == "TiB":
            return f"{int(f)} B" if u == "B" else f"{f:.2f} {u}"
        f /= 1024


def fzf_assign(targets, entries, weights, preserve_dirs):
    """Interactive assignment via the external fzf executable.

    For each target, its exact-size candidates are piped to fzf in
    descending combined-score order. Fields are tab-separated;
    --with-nth hides the entry index from the display while keeping it
    on the line returned on stdout. A non-zero exit from fzf (the user
    pressed Esc) skips that file. No confidence threshold applies here;
    the user is the threshold.
    """
    from shutil import which
    if which("fzf") is None:
        raise SystemExit("torrent-rename: --fzf requested but `fzf` is not on PATH")

    by_size = {}
    for ei, e in enumerate(entries):
        by_size.setdefault(e.length, []).append(ei)

    plan = []
    for t in targets:
        cands = []
        for ei in by_size.get(t.size, ()):
            s, ns, ms = combined_score(t, entries[ei], weights)
            cands.append((s, ei, entries[ei], ns, ms))
        if not cands:
            continue
        cands.sort(reverse=True)
        lines = [
            f"{s:.4f}\t{ei}\t{e.name}\t{e.length}\t{ns:.2f}/{ms:.2f}"
            for s, ei, e, ns, ms in cands
        ]
        header = f"target: {t.path}   [{human(t.size)}, {t.mime or '?'}]"
        try:
            proc = subprocess.run(
                ["fzf", "--delimiter=\t", "--with-nth=3,4,5,1", "--no-multi",
                 f"--header={header}", "--prompt=match> "],
                input="\n".join(lines),
                capture_output=True, text=True,
            )
        except FileNotFoundError:
            raise SystemExit("torrent-rename: fzf disappeared from PATH mid-run")
        if proc.returncode != 0 or not proc.stdout.strip():
            continue
        ei = int(proc.stdout.split("\t", 2)[1])
        e = entries[ei]
        s, ns, ms = combined_score(t, e, weights)
        plan.append(Rename(t, e, _dst_for(t, e, preserve_dirs), s, ns, ms))
    return plan


def collect_paths(paths, recursive):
    """Expand positional arguments into a deduplicated list of files.

    Directories contribute their immediate children, or all descendants
    with -r. Symlinks are skipped: renaming through a symlink renames
    its target, which is almost never intended, and the flag to enable
    that is a footgun this program has chosen not to ship.
    """
    out, seen = [], set()
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            it = p.rglob("*") if recursive else p.iterdir()
            for c in it:
                if c.is_file() and not c.is_symlink() and c not in seen:
                    seen.add(c)
                    out.append(c)
        elif p.is_file() and not p.is_symlink():
            if p not in seen:
                seen.add(p)
                out.append(p)
        else:
            print(f"torrent-rename: skipping {raw}: not a regular file or directory",
                  file=sys.stderr)
    return out


def report(plan, targets, args):
    matched = {r.target for r in plan}
    no_ops = sum(1 for r in plan if r.target.path == r.dst)
    unmatched = [t for t in targets if t not in matched]

    if args.quiet:
        print(f"{'applied' if args.apply else 'planned'}: "
              f"{len(plan)} match(es), {no_ops} no-op, {len(unmatched)} unmatched")
        return

    print("APPLIED" if args.apply else "DRY RUN  (pass --apply to rename)")
    print()
    if not plan:
        print("  (no matches)")
    for r in plan:
        tag = "no-op" if r.target.path == r.dst else "rename"
        print(f"  [{r.score:.2f}] {tag:<6} {r.target.path}")
        print(f"           ->    {r.dst}")
        if args.verbose:
            print(f"           name={r.name_score:.2f} magic={r.magic_score:.2f}"
                  f"   size={human(r.target.size)} (exact)"
                  f"   mime={r.target.mime or '?'}  ext={r.entry.ext or '?'}")
    if unmatched:
        print()
        print(f"  {len(unmatched)} file(s) had no match:")
        for t in unmatched[:20]:
            print(f"    {t.path}  ({human(t.size)}, {t.mime or '?'})")
        if len(unmatched) > 20:
            print(f"    ... and {len(unmatched) - 20} more")
    print()
    print(f"total: {len(plan)} match(es), {no_ops} no-op, {len(unmatched)} unmatched")


def apply_plan(plan):
    """Execute the plan in order; per-rename failures are skipped.

    A single bad target should not prevent the rest of the batch from
    being fixed. The plan has already been shown to the user, so partial
    application is not surprising.
    """
    for r in plan:
        if r.target.path == r.dst:
            continue
        if r.dst.exists():
            print(f"  !! destination exists, skipped: {r.dst}", file=sys.stderr)
            continue
        try:
            r.dst.parent.mkdir(parents=True, exist_ok=True)
            os.rename(str(r.target.path), str(r.dst))
        except OSError as e:
            print(f"  !! rename failed: {r.target.path} -> {r.dst}: {e}",
                  file=sys.stderr)


class _HelpAction(argparse.Action):
    def __init__(self, option_strings, dest=argparse.SUPPRESS,
                 default=argparse.SUPPRESS, **kw):
        super().__init__(option_strings=option_strings, dest=dest,
                         default=default, nargs=0, **kw)

    def __call__(self, parser, namespace, values, option_string=None):
        print(HELP_TEXT)
        parser.exit(0)


def _weights(s):
    try:
        parts = tuple(float(x) for x in s.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"expected two comma-separated floats, got {s!r}")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(
            "expected exactly two weights (name,magic)")
    if abs(sum(parts) - 1.0) > 1e-6:
        raise argparse.ArgumentTypeError(
            f"weights must sum to 1.0, got {sum(parts):.4f}")
    return parts


def build_parser():
    p = argparse.ArgumentParser(
        prog="torrent-rename",
        usage="torrent-rename [OPTIONS] PATH...",
        add_help=False,
    )
    p.add_argument("-h", "--help", action=_HelpAction,
                   help="show this help and exit")
    p.add_argument("-i", "--input", action="append", required=True,
                   metavar="TORRENT", dest="inputs",
                   help="torrent file (repeatable)")
    p.add_argument("-r", "--recursive", action="store_true",
                   help="recurse into directories")
    p.add_argument("--apply", action="store_true",
                   help="perform the renames")
    p.add_argument("--fzf", action="store_true",
                   help="pick matches interactively via fzf")
    p.add_argument("--min-confidence", type=float, default=0.75,
                   metavar="F", help="minimum combined score")
    p.add_argument("--weights", type=_weights, default=(0.8, 0.2),
                   metavar="W,W", help="name,magic weights")
    p.add_argument("--preserve-dirs", action="store_true",
                   help="recreate torrent directory structure")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    p.add_argument("paths", nargs="+", metavar="PATH")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    if not (0.0 <= args.min_confidence <= 1.0):
        sys.exit("torrent-rename: --min-confidence must be in [0,1]")

    entries = []
    for t in args.inputs:
        try:
            entries.extend(parse_torrent(t))
        except (OSError, ValueError) as e:
            sys.exit(f"torrent-rename: {t}: {e}")
    if not entries:
        sys.exit("torrent-rename: no entries found in the given torrent(s)")

    paths = collect_paths(args.paths, args.recursive)
    if not paths:
        sys.exit("torrent-rename: no files to rename")

    targets = [Target(p, p.stat().st_size, probe_mime(p)) for p in paths]

    if args.fzf:
        plan = fzf_assign(targets, entries, args.weights, args.preserve_dirs)
    else:
        plan = build_plan(targets, entries, args.weights,
                          args.min_confidence, args.preserve_dirs)

    report(plan, targets, args)

    if args.apply and plan:
        apply_plan(plan)

    return 0


if __name__ == "__main__":
    sys.exit(main())
