#!/usr/bin/env python3
"""
mpvframeshot.py — frame-accurate screenshot extraction from video using mpv.

SYNOPSIS
    mpvframeshot.py [globaloptions] [fileoptions] videofile
                    [[fileoptions] videofile ...]

    -s SPEC       comma-separated frame spec (REQUIRED per file)
    -o PATTERN    screenshot output path pattern
    -v            increase verbosity (repeatable; global or per-file)
    -n, --dry-run print mpv invocations without executing
    -h, --help    show this help

FRAME SPEC
    Each comma-separated item is one of:

        12345         frame sequence number (integer, 0-based, CFR only)
        00:01:30.500  timestamp (HH:MM:SS[.mmm] or MM:SS[.mmm] or SS[.mmm])

    Frame numbers are converted to timestamps via the video's r_frame_rate,
    obtained from ffprobe. ffprobe is invoked lazily: only when at least one
    frame-number item is present. If the stream is detected as VFR,
    frame-number items are rejected; timestamp items remain valid and
    require no ffprobe call at all.

INPUT
    Each videofile argument is either a local filesystem path or a
    protocol URI supported by both mpv and ffmpeg, such as:

        http://  https://  rtmp://  rtmps://  rtsp://  rtsps://
        ftp://   ftps://   sftp://  smb://    file://

    URI detection is heuristic (presence of '://'); schemes not listed
    above but accepted by both backends will also work. For URIs, the
    local-file existence check is skipped.

    In OUTPUT PATTERN, {stem} and {ext} for a URI are derived from the
    last path component of the URI, after percent-decoding. If the URI
    has no filename component, {stem} is "input".

OUTPUT PATTERN
    Python str.format substitution over these keys:

        {stem}   basename without directory and extension
        {ext}    original extension (no dot)
        {index}  0-based index within the current file's frame list
        {frame}  frame number if item was an integer, else empty
        {time}   timestamp in seconds, e.g. 90.500
        {n}      1-based global running counter

    Literal braces: {{ and }} produce { and }.

    Default: {stem}_{index:04d}.png  (written to the current directory)

EXAMPLES
    # one frame, frame number, direct CLI (fast path)
    mpvframeshot.py -s 12345 video.mkv

    # one frame, timestamp, custom output pattern
    mpvframeshot.py -s 00:01:30.500 -o '/tmp/{stem}-{time}.png' video.mkv

    # two files; second file overrides verbosity and pattern
    mpvframeshot.py -s 100,200 -v video1.mkv \\
                    -s 00:05:00 -vv -o '/tmp/{stem}_{index}.png' video2.mkv

    # remote input over HTTP
    mpvframeshot.py -s 1000 https://example.com/video.mkv

    # dry run
    mpvframeshot.py -n -s 500 video.mkv

ARCHITECTURE
    Two execution engines.

    1. DIRECT CLI (default for one file, one frame)
       Runs a single mpv with --vo=image --o=PATH. No temporary directory.
       If mpv exits non-zero or produces no file at PATH, the program
       retries that frame through IPC.

    2. IPC (used when a file has >1 frame, or >1 file is given)
       One mpv in idle mode with a Unix domain socket located directly
       under $TMPDIR (or /tmp). For each frame: loadfile, seek absolute+exact,
       wait for playback-restart, screenshot-to-file. Any IPC reply whose
       "error" field is not "success" aborts the run.

    Engine selection is fixed before any process starts:
        needs_ipc = (len(files) > 1) or any(len(f.frames) > 1)

ENVIRONMENT
    Requires: mpv, Python 3.8+. ffprobe (from ffmpeg) required only when
    frame-number items are used.
    Supported: macOS, Linux, BSD, Termux.
"""

import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
from typing import List, Optional, Tuple
from urllib.parse import unquote, urlparse

HELP = __doc__


class UsageError(Exception):
    """Raised for malformed command line. Printed without traceback."""


def die(msg: str) -> "None":
    """Print an error to stderr and terminate with exit code 1."""
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(1)


def is_url(path: str) -> bool:
    """
    True if path looks like a protocol URI rather than a local filesystem
    path. Heuristic: presence of '://'. This intentionally does not
    enumerate schemes, since mpv and ffmpeg between them accept far more
    than any hardcoded list, and the fallback on an unrecognized scheme is
    a clear error from the underlying tool.
    """
    return "://" in path


_TS_RE = re.compile(r"^(?:(\d+):)?(?:(\d+):)?(\d+)(?:\.(\d+))?$")


def parse_timestamp(s: str) -> Fraction:
    """
    Parse HH:MM:SS[.fff], MM:SS[.fff], or SS[.fff] into Fraction seconds.

    The regex greedily assigns components from the right, so:
        "45"         -> 45s
        "45.5"       -> 45.5s
        "1:30"       -> 1m30s
        "1:30.5"     -> 1m30.5s
        "1:30:45"    -> 1h30m45s
        "1:30:45.25" -> 1h30m45.25s
    """
    m = _TS_RE.match(s)
    if not m:
        raise ValueError(f"invalid timestamp: {s!r}")
    a, b, c, frac = m.groups()
    if a is not None and b is not None:
        h, mm, ss = int(a), int(b), int(c)
    elif a is not None:
        h, mm, ss = 0, int(a), int(c)
    else:
        h, mm, ss = 0, 0, int(c)
    sec = Fraction(ss)
    if frac:
        sec += Fraction(int(frac), 10 ** len(frac))
    return Fraction(h) * 3600 + Fraction(mm) * 60 + sec


def classify_item(raw: str) -> Tuple[str, object]:
    """
    Return ("frame", int) for a bare integer, or ("time", Fraction) for
    anything containing ':' or '.'. Raises ValueError otherwise.
    """
    raw = raw.strip()
    if not raw:
        raise ValueError("empty frame spec item")
    if raw.isdigit():
        return ("frame", int(raw))
    if ":" in raw or "." in raw:
        return ("time", parse_timestamp(raw))
    raise ValueError(f"cannot parse frame spec item: {raw!r}")


@dataclass
class FrameItem:
    kind: str
    raw: str
    frame: Optional[int] = None
    seconds: Optional[Fraction] = None


@dataclass
class FileJob:
    path: str
    frames_spec: Optional[str] = None
    output_pattern: Optional[str] = None
    verbosity: int = 0
    fps: Optional[Fraction] = None
    is_vfr: bool = False
    items: List[FrameItem] = field(default_factory=list)


def parse_rational(s: str) -> Fraction:
    """Parse 'n/d' or an integer string into a Fraction. '0/0' -> 0."""
    if "/" in s:
        num, den = s.split("/", 1)
        n, d = int(num), int(den)
        return Fraction(0) if d == 0 else Fraction(n, d)
    return Fraction(int(s))


def probe_fps(path: str) -> Tuple[Fraction, Fraction, bool]:
    """
    Run ffprobe and return (r_frame_rate, avg_frame_rate, is_vfr).

    The VFR heuristic compares r_frame_rate (FFmpeg's ideal base rate) to
    avg_frame_rate (total frames / duration). They can coincide on some
    VFR content, but this is the standard cheap check.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate,avg_frame_rate",
        "-of", "json",
        path,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, check=True, text=True)
    except FileNotFoundError:
        raise RuntimeError("ffprobe not found in PATH")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"ffprobe failed for {path}: {e.stderr.strip()}")
    data = json.loads(out.stdout)
    streams = data.get("streams") or []
    if not streams:
        raise RuntimeError(f"no video stream found in {path}")
    s = streams[0]
    r = parse_rational(s.get("r_frame_rate", "0"))
    avg = parse_rational(s.get("avg_frame_rate", "0"))
    return r, avg, r != avg


def render_output_path(pattern: str, job: FileJob, item: FrameItem,
                       index: int, n: int) -> str:
    """
    Python str.format substitution; supported keys are documented in the
    file-scope docstring. Braces are escaped by doubling, per str.format.

    For URL inputs, the stem/ext come from the last path component of the
    URI, after percent-decoding. If no filename component exists, the stem
    falls back to "input".
    """
    if is_url(job.path):
        parsed = urlparse(job.path)
        path_part = unquote(parsed.path) or ""
        p = Path(path_part)
        stem = p.stem or "input"
        ext = p.suffix.lstrip(".")
    else:
        p = Path(job.path)
        stem = p.stem
        ext = p.suffix.lstrip(".")

    frame_val = str(item.frame) if item.frame is not None else ""
    time_val = f"{float(item.seconds):.3f}" if item.seconds is not None else ""
    try:
        return pattern.format(
            stem=stem, ext=ext, index=index,
            frame=frame_val, time=time_val, n=n,
        )
    except KeyError as e:
        raise UsageError(f"unknown pattern key {e} in -o pattern")


def _ensure_parent(path: str) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)


def run_direct(job: FileJob, item: FrameItem, out_path: str,
               dry_run: bool, verbosity: int) -> bool:
    """
    Attempt single-frame extraction via mpv --vo=image --o=PATH.

    Returns True on success. Returns False if mpv exited non-zero or
    produced no file at out_path; the caller then falls back to the IPC
    engine for the same frame. This lets older mpv builds that do not
    support --o= still work, without paying the IPC cost when they aren't
    needed.

    @note The pre-existing file at out_path (if any) is unlinked before
    invocation and again on failure, so a stale file can never be mistaken
    for a fresh capture.
    """
    out_ext = (Path(out_path).suffix.lower().lstrip(".") or "png")
    img_format = "jpg" if out_ext == "jpeg" else (
        out_ext if out_ext in ("jpg", "png", "webp") else "png")

    cmd = [
        "mpv", "--no-config", "--no-audio", "--hr-seek=yes",
        f"--start={float(item.seconds):.6f}",
        "--frames=1",
        "--vo=image",
        f"--vo-image-format={img_format}",
        f"--o={out_path}",
        job.path,
    ]
    if dry_run:
        print("[direct] " + " ".join(shlex.quote(c) for c in cmd))
        return True
    if verbosity >= 2:
        sys.stderr.write("[direct] " + " ".join(shlex.quote(c) for c in cmd) + "\n")

    _ensure_parent(out_path)
    try:
        os.unlink(out_path)
    except FileNotFoundError:
        pass

    r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, text=True)
    if r.returncode == 0 and os.path.isfile(out_path):
        return True
    if verbosity >= 2:
        sys.stderr.write(
            f"[direct] mpv rc={r.returncode}, no usable output.\n"
            f"[direct] stderr:\n{r.stderr}\n")
    try:
        os.unlink(out_path)
    except FileNotFoundError:
        pass
    return False


class MpvIPC:
    """
    Minimal synchronous JSON IPC client for mpv.

    Responses are matched to requests via request_id. Unsolicited events
    are queued and can be retrieved with wait_event. Malformed JSON lines
    are dropped (mpv is documented to occasionally emit invalid UTF-8 in
    corner cases) and logged at verbosity >= 2.
    """

    def __init__(self, sockpath: str, verbosity: int = 1,
                 default_timeout: float = 10.0):
        self.sockpath = sockpath
        self.verbosity = verbosity
        self.default_timeout = default_timeout
        self.sock: Optional[socket.socket] = None
        self.buf = b""
        self.rid = 0
        self.event_queue: List[dict] = []

    def connect(self, timeout: Optional[float] = None) -> None:
        """Poll the socket path until mpv creates it, up to timeout."""
        deadline = time.time() + (timeout or self.default_timeout)
        last_err: Optional[Exception] = None
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.sockpath)
                self.sock = s
                return
            except OSError as e:
                last_err = e
                time.sleep(0.05)
        raise RuntimeError(f"could not connect to mpv IPC: {last_err}")

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _recv_line(self) -> str:
        assert self.sock is not None
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("mpv IPC connection closed unexpectedly")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")

    def _next_message(self) -> Optional[dict]:
        """Read one message; None if the socket timed out."""
        try:
            line = self._recv_line()
        except socket.timeout:
            return None
        if not line.strip():
            return self._next_message()
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            if self.verbosity >= 2:
                sys.stderr.write(f"[ipc] dropped malformed: {line!r}\n")
            return self._next_message()

    def _send_raw(self, obj: dict) -> None:
        assert self.sock is not None
        self.sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))

    def command(self, cmd: list, timeout: Optional[float] = None) -> dict:
        """Send a command and wait for its reply."""
        self.rid += 1
        rid = self.rid
        self._send_raw({"command": cmd, "request_id": rid})
        return self.wait_reply(rid, timeout)

    def wait_reply(self, rid: int, timeout: Optional[float] = None) -> dict:
        """
        Wait for the reply with request_id == rid. Events that arrive in
        the meantime are queued for later wait_event calls.
        """
        deadline = time.time() + (timeout or self.default_timeout)
        assert self.sock is not None
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise RuntimeError(f"timeout waiting for reply to request {rid}")
            self.sock.settimeout(remaining)
            try:
                msg = self._next_message()
            finally:
                self.sock.settimeout(None)
            if msg is None:
                raise RuntimeError(f"timeout waiting for reply to request {rid}")
            if msg.get("request_id") == rid and "error" in msg:
                return msg
            if "event" in msg:
                self.event_queue.append(msg)

    def wait_event(self, name: str, timeout: Optional[float] = None) -> dict:
        """
        Wait for a specific event. Events already queued are returned
        first, so no event is lost between a command reply and this call.
        """
        for i, ev in enumerate(self.event_queue):
            if ev.get("event") == name:
                return self.event_queue.pop(i)
        deadline = time.time() + (timeout or self.default_timeout)
        assert self.sock is not None
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise RuntimeError(f"timeout waiting for event {name!r}")
            self.sock.settimeout(remaining)
            try:
                msg = self._next_message()
            finally:
                self.sock.settimeout(None)
            if msg is None:
                raise RuntimeError(f"timeout waiting for event {name!r}")
            if msg.get("event") == name:
                return msg
            if "event" in msg:
                self.event_queue.append(msg)

    def drain(self, quiet_period: float = 0.05) -> None:
        """Consume and discard pending messages so stale events do not
        satisfy a subsequent wait_event."""
        assert self.sock is not None
        self.sock.settimeout(quiet_period)
        try:
            while True:
                msg = self._next_message()
                if msg is None:
                    break
                if self.verbosity >= 3 and "event" in msg:
                    sys.stderr.write(f"[ipc] drain event {msg['event']}\n")
        finally:
            self.sock.settimeout(None)
        self.event_queue.clear()

    def seek_and_wait(self, seconds: float, timeout: float = 15.0) -> None:
        """
        Seek to an absolute timestamp and wait for mpv to finish decoding
        the target frame. Waits for the playback-restart event; if that
        does not arrive (paused-idle corner case), falls back to polling
        core-idle until it becomes true.
        """
        self.drain()
        r = self.command(["seek", f"{seconds:.6f}", "absolute+exact"], timeout)
        if r.get("error") != "success":
            raise RuntimeError(f"seek failed: {r}")
        try:
            self.wait_event("playback-restart", timeout)
            return
        except RuntimeError:
            pass
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self.command(["get_property", "core-idle"], timeout=5.0)
            if r.get("error") == "success" and r.get("data") is True:
                return
            time.sleep(0.02)
        raise RuntimeError(f"timeout waiting for seek to {seconds}s")


def _sockpath() -> str:
    """Pick a socket path under $TMPDIR (or /tmp) unique to this process."""
    base = os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(
        base, f"mpvframeshot-{os.getpid()}-{os.urandom(4).hex()}.sock")


def run_ipc(jobs: List[FileJob], globals_: dict) -> int:
    """
    One mpv process serves all files and all frames.

    Launch:
        mpv --no-config --no-audio --idle=yes --hr-seek=yes
            --input-ipc-server=SOCKET --pause

    For each file: loadfile PATH replace, then wait for file-loaded.
    For each frame: seek T absolute+exact, wait for playback-restart,
    screenshot-to-file PATH video.

    IPC error handling: every command reply is a JSON object whose "error"
    field is "success" or an error string. A reply with "error" != "success",
    or a missing output file after screenshot-to-file, aborts the run with
    exit code 1 (per agreed policy). Socket and mpv child are cleaned up in
    the finally block regardless of how we exit.
    """
    sockpath = _sockpath()
    proc: Optional[subprocess.Popen] = None
    ipc: Optional[MpvIPC] = None
    verbosity = globals_["verbosity"]

    try:
        cmd = [
            "mpv", "--no-config", "--no-audio",
            "--idle=yes", "--hr-seek=yes",
            f"--input-ipc-server={sockpath}",
            "--pause=yes",
            "--vo=null", "--ao=null",
        ]

        if globals_["dry_run"]:
            print("[ipc] " + " ".join(shlex.quote(c) for c in cmd))
            n = 0
            for job in jobs:
                print(f"[ipc] loadfile {shlex.quote(job.path)} replace")
                for idx, item in enumerate(job.items):
                    n += 1
                    out = render_output_path(job.output_pattern, job,
                                             item, idx, n)
                    print(f"[ipc] seek {float(item.seconds):.6f} absolute+exact")
                    print(f"[ipc] screenshot-to-file {shlex.quote(out)} video")
            return 0

        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE)
        ipc = MpvIPC(sockpath, verbosity=verbosity)
        ipc.connect()

        n = 0
        for job in jobs:
            ipc.drain()
            r = ipc.command(["loadfile", job.path, "replace"])
            if r.get("error") != "success":
                sys.stderr.write(f"error: loadfile failed for {job.path}: {r}\n")
                return 1
            ipc.wait_event("file-loaded", timeout=30.0)
            ipc.command(["set_property", "pause", True])

            for idx, item in enumerate(job.items):
                n += 1
                out = render_output_path(job.output_pattern, job,
                                         item, idx, n)
                if job.verbosity >= 1:
                    sys.stderr.write(
                        f"[{n}] {job.path} frame={item.frame} "
                        f"t={float(item.seconds):.3f}s -> {out}\n")
                try:
                    ipc.seek_and_wait(float(item.seconds), timeout=15.0)
                except RuntimeError as e:
                    sys.stderr.write(f"error: {e}\n")
                    return 1

                _ensure_parent(out)
                try:
                    os.unlink(out)
                except FileNotFoundError:
                    pass
                r = ipc.command(["screenshot-to-file", str(out), "video"],
                                timeout=30.0)
                if r.get("error") != "success":
                    sys.stderr.write(f"error: screenshot-to-file failed: {r}\n")
                    return 1
                if not os.path.exists(out):
                    sys.stderr.write(
                        f"error: screenshot file not created: {out}\n")
                    return 1

        try:
            ipc.command(["quit"], timeout=3.0)
        except RuntimeError:
            pass
        return 0
    finally:
        if ipc is not None:
            ipc.close()
        if proc is not None:
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        try:
            os.unlink(sockpath)
        except FileNotFoundError:
            pass


def parse_args(argv: List[str]) -> Tuple[dict, List[FileJob]]:
    """
    Sequential group parser.

    Scanning is left-to-right. A new group starts at every videofile token.
    Options seen before the first videofile populate GLOBALS. Options seen
    after a videofile populate that file's overrides only.

    Inheritance:
        -v  inherits from GLOBALS if not present in the group
        -o  inherits from GLOBALS if not present in the group
        -s  NEVER inherits; required in every group (including group 0)
    """
    globals_ = {"verbosity": 0, "output": None, "dry_run": False}
    jobs: List[FileJob] = []
    pending = {"verbosity": None, "output": None, "spec": None}
    first_file_seen = False

    i = 0
    while i < len(argv):
        arg = argv[i]

        if arg in ("-n", "--dry-run"):
            globals_["dry_run"] = True
        elif arg == "-v":
            pending["verbosity"] = (pending["verbosity"] or 0) + 1
        elif arg.startswith("-") and len(arg) > 1 and set(arg[1:]) == {"v"}:
            pending["verbosity"] = (pending["verbosity"] or 0) + len(arg) - 1
        elif arg == "-o":
            i += 1
            if i >= len(argv):
                raise UsageError("-o requires an argument")
            pending["output"] = argv[i]
        elif arg.startswith("-o") and len(arg) > 2:
            pending["output"] = arg[2:]
        elif arg == "-s":
            i += 1
            if i >= len(argv):
                raise UsageError("-s requires an argument")
            pending["spec"] = argv[i]
        elif arg.startswith("-s") and len(arg) > 2:
            pending["spec"] = arg[2:]
        elif arg.startswith("-"):
            raise UsageError(f"unknown option: {arg}")
        else:
            job = FileJob(path=arg)
            job.frames_spec = pending["spec"]

            if not first_file_seen:
                if pending["verbosity"] is not None:
                    globals_["verbosity"] = pending["verbosity"]
                if pending["output"] is not None:
                    globals_["output"] = pending["output"]
                job.verbosity = globals_["verbosity"]
                job.output_pattern = globals_["output"]
                first_file_seen = True
            else:
                job.verbosity = (pending["verbosity"]
                                 if pending["verbosity"] is not None
                                 else globals_["verbosity"])
                job.output_pattern = (pending["output"]
                                      if pending["output"] is not None
                                      else globals_["output"])

            pending = {"verbosity": None, "output": None, "spec": None}
            jobs.append(job)
        i += 1

    if (pending["spec"] is not None or pending["output"] is not None
            or pending["verbosity"] is not None):
        raise UsageError("options specified without a following videofile")

    return globals_, jobs


def main(argv: List[str]) -> int:
    if not argv or "-h" in argv or "--help" in argv:
        sys.stdout.write(HELP)
        return 0

    try:
        globals_, jobs = parse_args(argv)
    except UsageError as e:
        sys.stderr.write(f"error: {e}\n")
        return 1

    if not jobs:
        sys.stderr.write("error: no video files specified\n")
        return 1

    for job in jobs:
        if not job.frames_spec:
            sys.stderr.write(f"error: no -s specified for {job.path}\n")
            return 1
        if not is_url(job.path) and not os.path.isfile(job.path):
            sys.stderr.write(f"error: file not found: {job.path}\n")
            return 1
        if not job.output_pattern:
            job.output_pattern = "{stem}_{index:04d}.png"

    try:
        for job in jobs:
            raw_items: List[FrameItem] = []
            for raw in job.frames_spec.split(","):
                raw = raw.strip()
                if not raw:
                    continue
                kind, val = classify_item(raw)
                if kind == "frame":
                    raw_items.append(FrameItem(kind="frame", raw=raw,
                                               frame=int(val)))
                else:
                    raw_items.append(FrameItem(kind="time", raw=raw,
                                               seconds=val))
            if not raw_items:
                raise RuntimeError(f"{job.path}: empty frame list")

            needs_fps = any(it.kind == "frame" for it in raw_items)
            if needs_fps:
                r, _avg, is_vfr = probe_fps(job.path)
                if r == 0:
                    raise RuntimeError(
                        f"could not determine fps for {job.path}")
                job.fps = r
                job.is_vfr = is_vfr
                for it in raw_items:
                    if it.kind == "frame":
                        if is_vfr:
                            raise RuntimeError(
                                f"{job.path}: frame number {it.frame} "
                                f"specified but stream looks VFR; "
                                f"use a timestamp instead")
                        it.seconds = Fraction(it.frame, 1) / r
            job.items = raw_items
    except (UsageError, ValueError, RuntimeError) as e:
        sys.stderr.write(f"error: {e}\n")
        return 1

    needs_ipc = (len(jobs) > 1) or any(len(j.items) > 1 for j in jobs)

    if globals_["dry_run"]:
        if not needs_ipc:
            job = jobs[0]
            item = job.items[0]
            out = render_output_path(job.output_pattern, job, item, 0, 1)
            run_direct(job, item, out, dry_run=True, verbosity=job.verbosity)
        else:
            run_ipc(jobs, globals_)
        return 0

    if not needs_ipc:
        job = jobs[0]
        item = job.items[0]
        out = render_output_path(job.output_pattern, job, item, 0, 1)
        if run_direct(job, item, out, dry_run=False,
                      verbosity=job.verbosity):
            return 0
        if job.verbosity >= 1:
            sys.stderr.write("[info] direct mode produced no output; "
                             "falling back to IPC\n")
        return run_ipc(jobs, globals_)

    return run_ipc(jobs, globals_)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted\n")
        sys.exit(130)
