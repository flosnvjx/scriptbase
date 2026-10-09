#!/usr/bin/env python3
"""
mpvframeshot.py — frame-accurate screenshot extraction from video using mpv.

SYNOPSIS
    mpvframeshot.py [options] videofile [options] [videofile ...]

    Global options (persist, apply to all subsequent videofiles):
        -S SPEC       default frame spec
        -O PATTERN    default output pattern
        -T SECONDS    default timeout (initial default: 15)
        -V            increase default verbosity (repeatable)

    Per-file options (apply only to the next videofile):
        -s SPEC       frame spec
        -o PATTERN    output pattern
        -t SECONDS    timeout
        -v            increase verbosity (repeatable)

    Global-only options:
        -n, -N, --dry-run    print mpv invocations without executing
        -h, -H, --help       show this help

OPTION SCOPE
    Scope is determined by case, not position. Uppercase options set
    global defaults that persist across the whole invocation and may be
    updated mid-stream to affect only subsequent files. Lowercase options
    apply only to the next videofile and are discarded after it.

    On each videofile, the effective value of a field is the per-file
    value if set for that file, otherwise the current global value. If
    neither -o nor -O is given anywhere, the default pattern
    {stem}_{index:04d}.png applies. Every videofile must resolve to a
    non-empty spec; a file with no -s and no -S is an error.

    An uppercase option takes effect immediately; files processed after
    it use the new value as their default. Files processed before it are
    unaffected.

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

    Remote inputs may require a larger timeout. -t or -T sets the maximum
    wait for file load, seek settle, screenshot write, and ffprobe; local
    IPC operations keep a short floor so a hung mpv is still reported
    quickly.

    For remote HTTP/HTTPS inputs, the program enables libavformat's
    reconnection logic (reconnect, reconnect_on_network_error,
    reconnect_streamed) to survive transient TCP RST and similar network
    errors.

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

    PNG output uses maximum compression (level 9). JPEG output uses
    maximum quality (100). WebP output uses lossless mode when the target
    extension is .webp, otherwise quality 100.

EXAMPLES
    # one frame from one file
    mpvframeshot.py -s 12345 video.mkv

    # one frame, timestamp, custom output pattern
    mpvframeshot.py -s 00:01:30.500 -o '/tmp/{stem}-{time}.png' video.mkv

    # one spec applies to both files; second file overrides verbosity
    mpvframeshot.py -S 100,200 video1.mkv \\
                    -v -o '/tmp/{stem}_{index}.png' video2.mkv

    # remote input over HTTP
    mpvframeshot.py -s 1000 https://example.com/video.mkv

    # slow remote origin, globally
    mpvframeshot.py -T 120 -s 500 https://archive.example/old.mkv

    # dry run
    mpvframeshot.py -n -s 500 video.mkv

ARCHITECTURE
    Both engines use mpv's image writer via --vo=image. The writer always
    produces files named "<counter>.<format>" in a directory selected by
    --vo-image-outdir. Before mpv runs, the program snapshots the target
    directory; after mpv exits (or after each seek in IPC mode), it finds
    the newly created numbered file and renames it into place.

    1. DIRECT CLI (default for one file, one frame)
       One mpv process is launched with --frames=1, --hr-seek=yes,
       --start=T, --vo=image, and --vo-image-outdir=<dir>. After exit, the
       numbered file is renamed to the requested output path. If no new
       file appeared, the program retries the same frame through IPC.

    2. IPC (used when a file has >1 frame, or >1 file is given)
       One mpv process in idle mode, --pause=yes, --vo=image,
       --vo-image-outdir=<dir>, and --input-ipc-server=SOCKET. For each
       frame: seek absolute+exact, wait until core-idle is true, then
       rename the newest numbered file in the capture directory to the
       requested output path. Any IPC reply whose "error" field is not
       "success" aborts the run.

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

DEFAULT_TIMEOUT = 15.0
LOCAL_IPC_TIMEOUT = 10.0
IMAGE_SETTLE_SECONDS = 0.15
DEFAULT_OUTPUT_PATTERN = "{stem}_{index:04d}.png"

NETWORK_OPTS = [
    "reconnect=1",
    "reconnect_on_network_error=1",
    "reconnect_streamed=1",
]


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


def parse_timeout(s: str) -> float:
    """
    Parse a positive float number of seconds. Raises UsageError on
    non-numeric input or a non-positive value.
    """
    try:
        v = float(s)
    except ValueError:
        raise UsageError(f"invalid timeout: {s!r}")
    if v <= 0:
        raise UsageError(f"timeout must be positive: {s!r}")
    return v


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
    timeout: Optional[float] = None
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


def probe_fps(path: str, timeout: float) -> Tuple[Fraction, Fraction, bool]:
    """
    Run ffprobe and return (r_frame_rate, avg_frame_rate, is_vfr).

    The VFR heuristic compares r_frame_rate (FFmpeg's ideal base rate) to
    avg_frame_rate (total frames / duration). They can coincide on some
    VFR content, but this is the standard cheap check.

    timeout bounds the ffprobe subprocess; a stalled remote connection
    raises RuntimeError rather than blocking forever.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate,avg_frame_rate",
        "-of", "json",
        path,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, check=True,
                             text=True, timeout=timeout)
    except FileNotFoundError:
        raise RuntimeError("ffprobe not found in PATH")
    except subprocess.TimeoutExpired:
        raise RuntimeError(
            f"ffprobe timed out after {timeout:.1f}s for {path}")
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


def _image_format_for(path: str) -> Tuple[str, str]:
    """
    Map a target filename extension to (vo_image_format, expected_ext).
    Unknown extensions default to png. jpeg normalizes to jpg because
    that is the value vo_image accepts.
    """
    ext = (Path(path).suffix.lower().lstrip(".") or "png")
    if ext == "jpeg":
        return "jpg", "jpg"
    if ext in ("jpg", "png", "webp"):
        return ext, ext
    return "png", "png"


def _resolve_input(path: str) -> str:
    """
    Return an absolute path for local inputs. URLs are returned unchanged.
    """
    return path if is_url(path) else os.path.abspath(path)


def _find_new_numbered(dirpath: str, before: set,
                       expected_ext: str) -> Optional[str]:
    """
    Return the path of the newest file in dirpath that (a) ends with
    .expected_ext and (b) did not exist in the before snapshot. Returns
    None if no such file exists. The before snapshot comparison guards
    against pre-existing numbered files; the extension guards against
    unrelated files that might appear concurrently.
    """
    try:
        after = set(os.listdir(dirpath))
    except OSError:
        return None
    candidates = sorted(
        f for f in (after - before)
        if f.lower().endswith(f".{expected_ext}"))
    if not candidates:
        return None
    return os.path.join(dirpath, candidates[-1])


def _rename_into_place(src: str, dst: str) -> None:
    """
    Move src to dst, replacing any existing file at dst. Raises OSError
    on failure.
    """
    dst_abs = os.path.abspath(dst)
    _ensure_parent(dst_abs)
    os.replace(src, dst_abs)


def _add_network_opts(cmd: list, path: str) -> None:
    """
    Append libavformat reconnection options to cmd when path looks like a
    network URI. These enable reconnect, reconnect_on_network_error, and
    reconnect_streamed, which together let libavformat survive transient
    TCP RST and similar errors without surfacing them to mpv.
    """
    if is_url(path):
        cmd.extend([f"--stream-lavf-o={opt}" for opt in NETWORK_OPTS])


def _add_image_quality_opts(cmd: list, img_format: str) -> None:
    """
    Append max-quality options for the given image writer format. PNG uses
    compression level 9 (highest). JPEG uses quality 100. WebP uses
    lossless mode.
    """
    if img_format == "png":
        cmd.append("--vo-image-png-compression=9")
    elif img_format == "jpg":
        cmd.append("--vo-image-jpeg-quality=100")
    elif img_format == "webp":
        cmd.append("--vo-image-webp-lossless=yes")


def run_direct(job: FileJob, item: FrameItem, out_path: str,
               dry_run: bool, verbosity: int) -> bool:
    """
    Extract a single frame via mpv's --vo=image writer.

    mpv's image writer writes "<counter>.<format>" into the directory
    selected by --vo-image-outdir. This function snapshots the target
    directory before launch, and renames the newly created numbered file
    into place after mpv exits. No temporary directory is used; the only
    file the program ever creates is the requested output.

    Returns True on success. Returns False if mpv exited non-zero, timed
    out, produced no new file, or the rename failed; the caller then
    falls back to the IPC engine for the same frame.

    @note The input path is resolved to an absolute path for local files
    before launch, so changing the child's cwd does not break it.
    """
    img_format, expected_ext = _image_format_for(out_path)
    out_abs = os.path.abspath(out_path)
    out_dir = os.path.dirname(out_abs)
    input_abs = _resolve_input(job.path)

    cmd = [
        "mpv", "--no-config", "--no-audio", "--hr-seek=yes",
        f"--start={float(item.seconds):.6f}",
        "--frames=1",
        "--vo=image",
        f"--vo-image-format={img_format}",
        f"--vo-image-outdir={out_dir}",
    ]
    _add_image_quality_opts(cmd, img_format)
    _add_network_opts(cmd, job.path)
    cmd.append(input_abs)

    if dry_run:
        print("[direct] " + " ".join(shlex.quote(c) for c in cmd))
        return True
    if verbosity >= 2:
        sys.stderr.write("[direct] " + " ".join(shlex.quote(c) for c in cmd) + "\n")

    _ensure_parent(out_abs)
    try:
        os.unlink(out_abs)
    except FileNotFoundError:
        pass

    try:
        before = set(os.listdir(out_dir))
    except OSError as e:
        if verbosity >= 2:
            sys.stderr.write(f"[direct] cannot list {out_dir}: {e}\n")
        return False

    try:
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True,
                           timeout=job.timeout)
    except subprocess.TimeoutExpired:
        if verbosity >= 2:
            sys.stderr.write(f"[direct] mpv timed out after "
                             f"{job.timeout:.1f}s\n")
        return False
    except OSError as e:
        if verbosity >= 2:
            sys.stderr.write(f"[direct] spawn failed: {e}\n")
        return False

    new_path = _find_new_numbered(out_dir, before, expected_ext)
    if new_path is None:
        if verbosity >= 2:
            sys.stderr.write(
                f"[direct] mpv rc={r.returncode}, no new image in "
                f"{out_dir} (looking for .{expected_ext})\n"
                f"[direct] stderr:\n{r.stderr}\n")
        return False

    try:
        _rename_into_place(new_path, out_abs)
    except OSError as e:
        if verbosity >= 2:
            sys.stderr.write(f"[direct] rename failed: {e}\n")
        try:
            os.unlink(new_path)
        except OSError:
            pass
        return False

    return True


class MpvIPC:
    """
    Minimal synchronous JSON IPC client for mpv.

    Responses are matched to requests via request_id. Unsolicited events
    are queued and can be retrieved with wait_event. Malformed JSON lines
    are dropped (mpv is documented to occasionally emit invalid UTF-8 in
    corner cases) and logged at verbosity >= 2.

    default_timeout is the fallback for calls that do not pass an explicit
    timeout. It is kept short (LOCAL_IPC_TIMEOUT) because every IPC
    operation other than file-loaded and seek is a local round-trip that
    should return instantly; the caller passes per-file -t values
    explicitly to the network-sensitive calls.
    """

    def __init__(self, sockpath: str, verbosity: int = 1,
                 default_timeout: float = LOCAL_IPC_TIMEOUT):
        self.sockpath = sockpath
        self.verbosity = verbosity
        self.default_timeout = default_timeout
        self.sock: Optional[socket.socket] = None
        self.buf = b""
        self.rid = 0
        self.event_queue: List[dict] = []

    def connect(self, timeout: Optional[float] = None) -> None:
        """
        Poll the socket path until mpv creates it. Bounded by
        min(timeout or default_timeout, LOCAL_IPC_TIMEOUT): a hung mpv
        launch should be reported quickly regardless of any -T value the
        user set for remote reads.
        """
        bound = min(timeout or self.default_timeout, LOCAL_IPC_TIMEOUT)
        deadline = time.time() + bound
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
        """
        Send a command and wait for its reply. Commands are acknowledged
        instantly by mpv, so this uses min(timeout, LOCAL_IPC_TIMEOUT)
        rather than the full -T value.
        """
        eff = min(timeout or self.default_timeout, LOCAL_IPC_TIMEOUT)
        self.rid += 1
        rid = self.rid
        self._send_raw({"command": cmd, "request_id": rid})
        return self.wait_reply(rid, eff)

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

    def seek_and_wait(self, seconds: float, timeout: float) -> None:
        """
        Seek to an absolute timestamp and wait for mpv to settle.

        A prior implementation returned as soon as the playback-restart
        event fired. That event marks the beginning of the internal resume
        that a seek triggers, not the moment the decode/render/display
        pipeline has settled on the target frame. A capture issued right
        after it can therefore grab the pre-seek frame on one run and the
        target frame on another, giving non-deterministic output.

        This implementation waits for playback-restart first (a positive
        signal that the seek was accepted and started), then polls
        core-idle until it is true. core-idle=true means the pipeline has
        fully drained and the displayed frame is the seek target.
        """
        self.drain()
        r = self.command(["seek", f"{seconds:.6f}", "absolute+exact"], timeout)
        if r.get("error") != "success":
            raise RuntimeError(f"seek failed: {r}")
        try:
            self.wait_event("playback-restart", timeout=2.0)
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
            --input-ipc-server=SOCKET --pause=yes
            --vo=image --vo-image-format=FMT --vo-image-outdir=DIR

    The image writer's output directory is the target directory of the
    first frame in the first job. Every frame mpv displays is written
    there as "<counter>.<FMT>". For each requested frame, the program
    snapshots that directory, seeks, waits for core-idle, then renames
    the newly created file to the requested output path.

    FMT is derived from the first target's extension. If later targets
    use a different extension, the file content matches the first
    target's format; this is a documented limitation of mpv's writer,
    which cannot change format between frames within one process.

    IPC error handling: every command reply is a JSON object whose
    "error" field is "success" or an error string. A reply with "error"
    != "success", or a missing output file after seek settle, aborts the
    run with exit code 1. Socket and mpv child are cleaned up in the
    finally block regardless of how we exit.
    """
    first_out = render_output_path(jobs[0].output_pattern, jobs[0],
                                   jobs[0].items[0], 0, 1)
    first_out_abs = os.path.abspath(first_out)
    capture_dir = os.path.dirname(first_out_abs)
    _ensure_parent(first_out_abs)

    img_format, expected_ext = _image_format_for(first_out_abs)

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
            "--vo=image",
            f"--vo-image-format={img_format}",
            f"--vo-image-outdir={capture_dir}",
        ]
        _add_image_quality_opts(cmd, img_format)

        if globals_["dry_run"]:
            print("[ipc] " + " ".join(shlex.quote(c) for c in cmd))
            n = 0
            for job in jobs:
                print(f"[ipc] loadfile {shlex.quote(_resolve_input(job.path))} "
                      f"replace")
                for idx, item in enumerate(job.items):
                    n += 1
                    out = render_output_path(job.output_pattern, job,
                                             item, idx, n)
                    print(f"[ipc] seek {float(item.seconds):.6f} "
                          f"absolute+exact")
                    print(f"[ipc] rename newest .{expected_ext} in "
                          f"{capture_dir} -> {shlex.quote(out)}")
            return 0

        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        ipc = MpvIPC(sockpath, verbosity=verbosity,
                     default_timeout=LOCAL_IPC_TIMEOUT)
        ipc.connect()

        n = 0
        for job in jobs:
            ipc.drain()
            input_abs = _resolve_input(job.path)
            r = ipc.command(["loadfile", input_abs, "replace"])
            if r.get("error") != "success":
                sys.stderr.write(f"error: loadfile failed for {job.path}: "
                                 f"{r}\n")
                return 1
            ipc.wait_event("file-loaded", timeout=job.timeout)
            ipc.command(["set_property", "pause", True])

            for idx, item in enumerate(job.items):
                n += 1
                out = render_output_path(job.output_pattern, job,
                                         item, idx, n)
                out_abs = os.path.abspath(out)
                _ensure_parent(out_abs)

                if job.verbosity >= 1:
                    sys.stderr.write(
                        f"[{n}] {job.path} frame={item.frame} "
                        f"t={float(item.seconds):.3f}s -> {out_abs}\n")

                try:
                    before = set(os.listdir(capture_dir))
                except OSError as e:
                    sys.stderr.write(f"error: cannot list {capture_dir}: "
                                     f"{e}\n")
                    return 1

                try:
                    ipc.seek_and_wait(float(item.seconds),
                                      timeout=job.timeout)
                except RuntimeError as e:
                    sys.stderr.write(f"error: {e}\n")
                    return 1

                time.sleep(IMAGE_SETTLE_SECONDS)

                src = _find_new_numbered(capture_dir, before, expected_ext)
                if src is None:
                    sys.stderr.write(
                        f"error: no frame captured in {capture_dir} "
                        f"(expected .{expected_ext})\n")
                    return 1

                try:
                    os.unlink(out_abs)
                except FileNotFoundError:
                    pass
                try:
                    _rename_into_place(src, out_abs)
                except OSError as e:
                    sys.stderr.write(f"error: rename failed: {e}\n")
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
    Case determines scope, not position.

    Uppercase paired options (-S, -O, -T, -V) update a persistent G dict
    of global defaults. Lowercase paired options (-s, -o, -t, -v) update
    a P dict of pending per-file overrides that is consumed and reset at
    every videofile. On a videofile, each field resolves to P's value if
    set, else G's value.

    Mixed-case verbosity bundles such as -Vv are rejected as ambiguous.
    Global-only options (-n/-N/--dry-run, -h/-H/--help) are recognized by
    exact match and are not affected by the case rule.

    At end of argv, a non-empty P is an error: per-file options must be
    followed by a videofile.
    """
    G = {"spec": None, "output": None, "timeout": DEFAULT_TIMEOUT,
         "verbosity": 0, "dry_run": False}
    P = {"spec": None, "output": None, "timeout": None, "verbosity": None}
    jobs: List[FileJob] = []

    i = 0
    while i < len(argv):
        arg = argv[i]

        if arg in ("-n", "-N", "--dry-run"):
            G["dry_run"] = True
        elif arg.startswith("-") and len(arg) > 1 and set(arg[1:]) == {"v"}:
            P["verbosity"] = (P["verbosity"] or 0) + len(arg) - 1
        elif arg.startswith("-") and len(arg) > 1 and set(arg[1:]) == {"V"}:
            G["verbosity"] += len(arg) - 1
        elif (arg.startswith("-") and len(arg) > 1
              and set(arg[1:]) <= {"v", "V"}):
            raise UsageError(f"mixed-case verbosity bundle not allowed: {arg}")
        elif arg == "-s":
            i += 1
            if i >= len(argv):
                raise UsageError("-s requires an argument")
            P["spec"] = argv[i]
        elif arg.startswith("-s") and len(arg) > 2:
            P["spec"] = arg[2:]
        elif arg == "-S":
            i += 1
            if i >= len(argv):
                raise UsageError("-S requires an argument")
            G["spec"] = argv[i]
        elif arg.startswith("-S") and len(arg) > 2:
            G["spec"] = arg[2:]
        elif arg == "-o":
            i += 1
            if i >= len(argv):
                raise UsageError("-o requires an argument")
            P["output"] = argv[i]
        elif arg.startswith("-o") and len(arg) > 2:
            P["output"] = arg[2:]
        elif arg == "-O":
            i += 1
            if i >= len(argv):
                raise UsageError("-O requires an argument")
            G["output"] = argv[i]
        elif arg.startswith("-O") and len(arg) > 2:
            G["output"] = arg[2:]
        elif arg == "-t":
            i += 1
            if i >= len(argv):
                raise UsageError("-t requires an argument")
            P["timeout"] = parse_timeout(argv[i])
        elif arg.startswith("-t") and len(arg) > 2:
            P["timeout"] = parse_timeout(arg[2:])
        elif arg == "-T":
            i += 1
            if i >= len(argv):
                raise UsageError("-T requires an argument")
            G["timeout"] = parse_timeout(argv[i])
        elif arg.startswith("-T") and len(arg) > 2:
            G["timeout"] = parse_timeout(arg[2:])
        elif arg.startswith("-"):
            raise UsageError(f"unknown option: {arg}")
        else:
            job = FileJob(path=arg)
            job.frames_spec = (P["spec"] if P["spec"] is not None
                               else G["spec"])
            job.output_pattern = (P["output"] if P["output"] is not None
                                  else G["output"])
            job.timeout = (P["timeout"] if P["timeout"] is not None
                           else G["timeout"])
            job.verbosity = (P["verbosity"] if P["verbosity"] is not None
                             else G["verbosity"])
            jobs.append(job)
            P = {"spec": None, "output": None, "timeout": None,
                 "verbosity": None}
        i += 1

    if (P["spec"] is not None or P["output"] is not None
            or P["timeout"] is not None or P["verbosity"] is not None):
        raise UsageError("per-file options specified without a following "
                         "videofile")

    globals_ = {
        "verbosity": G["verbosity"],
        "output": G["output"],
        "timeout": G["timeout"],
        "dry_run": G["dry_run"],
    }
    return globals_, jobs


def main(argv: List[str]) -> int:
    if not argv or "-h" in argv or "-H" in argv or "--help" in argv:
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
            sys.stderr.write(f"error: no frame spec for {job.path} "
                             f"(use -s or -S)\n")
            return 1
        if not is_url(job.path) and not os.path.isfile(job.path):
            sys.stderr.write(f"error: file not found: {job.path}\n")
            return 1
        if not job.output_pattern:
            job.output_pattern = DEFAULT_OUTPUT_PATTERN

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
                r, _avg, is_vfr = probe_fps(job.path, job.timeout)
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
