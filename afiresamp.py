#!/usr/bin/env python3
"""
afiresamp – resample piped audio with automatic dither and pre‑resampling headroom adjustment.

A two‑pass offline processor designed for mastering‑grade sample‑rate conversion (SRC) and
bit‑depth reduction.  It works on data received via stdin and outputs the processed audio to
stdout, supporting both seekable (regular file) and non‑seekable (pipe) inputs.
"""

import sys
import subprocess
import json
import argparse
import shutil
import os
from typing import Optional, Dict, List, Tuple


def parse_args() -> argparse.Namespace:
    """Parse command‑line arguments and return a namespace.
    """
    parser = argparse.ArgumentParser(
        description=(
            "Resample audio to a target sample rate, automatically applying "
            "dither when reducing bitdepth, adjusting pre‑SRC gain to prevent "
            "clipping from resampling overshoots.\n\n"
        ),
        epilog=(
            "Examples:\n"
            "  cat input.flac | afiresamp 48000 > output.wav\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "sample_rate",
        nargs="?",
        type=int,
        default=44100,
        help="Target sample rate in Hz (default: 44100).",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        default=False,
        help="Log all subprocess command lines and always print captured stderr.",
    )
    parser.add_argument(
        "--keep-input-bitdepth-if-8bit",
        action="store_true",
        default=False,
        help=(
            "Preserve 8‑bit depth instead of up‑converting to 16‑bit. "
            "When the input is 8‑bit unsigned (u8), the output will also be 8‑bit; "
            "otherwise the default is to convert to 16‑bit for safety."
        ),
    )
    return parser.parse_args()


def _sox_env() -> Dict[str, str]:
    """Return a copy of the current environment with LC_ALL=C.

    This ensures SoX prints numbers in a format that the parsing routines expect,
    regardless of the user's locale settings.
    """
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    return env


def _probe_input(ffprobe_stdout: bytes) -> Optional[Tuple[Dict, str]]:
    """Extract the first audio stream's metadata and the container format name.

    Returns (stream_info_dict, format_name) or None if there is not exactly
    one audio stream.
    """
    try:
        data = json.loads(ffprobe_stdout.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    streams = data.get("streams", [])
    audio_stream = None
    for s in streams:
        if s.get("codec_type") == "audio":
            if audio_stream is not None:
                # More than one audio stream – invalid.
                return None
            audio_stream = {
                "codec_name": s.get("codec_name", ""),
                "sample_rate": int(s.get("sample_rate", 0)),
                "sample_fmt": s.get("sample_fmt", ""),
            }
    if audio_stream is None:
        return None
    fmt_info = data.get("format", {})
    format_name = fmt_info.get("format_name", "")
    return audio_stream, format_name


def build_gain_estimation_sox_cmd(
    input_type: str,
    sample_fmt: str,
    src_sample_rate: int,
    target_sample_rate: int,
    need_dither: bool,
) -> List[str]:
    """Construct the SoX command line used for peak measurement.

    The chain is:
        input -> vol -20 dB -> [rate] -> [dither] -> stats

    * The **-20 dB pad** ensures that resampling overshoots (which can be
      as high as +6 dB for extreme test signals) will never clip the measurement.
    * Dither is only added when *need_dither* is True – this mirrors what the final
      production pass will do, so the measured peak accurately reflects the final
      peak after dither.
    * The ``stats`` effect prints peak level and other metrics to stderr, which are
      later parsed.
    """
    cmd = ["sox", "-D", "-t", input_type, "-"]

    if sample_fmt not in ("s16", "s16p"):
        cmd.append("-b16")

    cmd.extend(["-n", "vol", "-20dB"])

    if src_sample_rate != target_sample_rate:
        cmd.extend(["rate", str(target_sample_rate)])

    if need_dither:
        cmd.append("dither")

    cmd.append("stats")

    return cmd


def build_production_sox_cmd(
    input_type: str,
    sample_fmt: str,
    src_sample_rate: int,
    target_sample_rate: int,
    attenuation_db: float,
    keep_8bit: bool,
    need_dither: bool,
) -> Optional[List[str]]:
    """Construct the SoX command line for final audio production.

    The chain is built to apply only the necessary operations, in the correct order:
        1. Bit‑depth conversion to 16‑bit (unless keep_8bit and input is u8).
        2. Pre‑SRC volume adjustment (the computed attenuation).
        3. Sample‑rate conversion (if needed).
        4. Dither (always last, only if reducing effective bit‑depth).

    Returns None if no processing at all is required (i.e., output is identical
    to input), allowing the caller to simply copy the data.
    """
    need_vol = attenuation_db != 0.0
    need_resample = src_sample_rate != target_sample_rate

    is_u8 = sample_fmt == "u8"
    need_b16 = sample_fmt not in ("s16", "s16p") and not (is_u8 and keep_8bit)

    if not (need_vol or need_resample or need_b16 or need_dither):
        return None

    cmd = ["sox", "-D", "-t", input_type, "-"]

    # Output type and bit‑depth
    cmd.extend(["-t", input_type])
    if need_b16:
        cmd.append("-b16")
    cmd.append("-")

    # Effects in correct DSP order
    if need_vol:
        cmd.extend(["vol", f"{attenuation_db:.1f}dB"])

    if need_resample:
        cmd.extend(["rate", str(target_sample_rate)])

    if need_dither:
        cmd.append("dither")

    return cmd


def parse_peak_from_stats(sox_stderr: bytes) -> Optional[float]:
    """Extract the peak level (dB) from the SoX stats effect output.

    Looks for the line starting with 'Pk lev dB' and returns the numeric value
    (the fourth whitespace‑separated token).
    """
    lines = sox_stderr.decode("utf-8", errors="replace").splitlines()
    for line in lines:
        if line.startswith("Pk lev dB"):
            parts = line.split()
            if len(parts) >= 4:
                try:
                    return float(parts[3])
                except ValueError:
                    pass
    return None


def parse_bitdepth_from_stats(sox_stderr: bytes) -> Optional[int]:
    """Extract the effective bit‑depth from SoX stats output.

    The 'Bit-depth' line looks like 'Bit-depth      16/16' or '24/24'.
    We take the first part before the slash and convert to int.
    """
    lines = sox_stderr.decode("utf-8", errors="replace").splitlines()
    for line in lines:
        if line.startswith("Bit-depth"):
            parts = line.split()
            if len(parts) >= 2:
                val_str = parts[1].split("/")[0]
                try:
                    return int(val_str)
                except ValueError:
                    pass
    return None


def compute_attenuation(peak_db: float) -> float:
    """Calculate the pre‑SRC attenuation needed.

    *peak_db* is the peak measured **after** a −20 dB pad, so the true unattenuated
    peak would be 20 + peak_db.  If that value is positive, we attenuate to bring the
    peak down to −0.1 dBFS (an extra 0.1 dB safety margin).  The result is negative
    (or zero if no reduction is needed).
    """
    att = 20.0 + peak_db
    if att > 0.0:
        att += 0.1
        att = -att
    else:
        att = 0.0
    return att


def _log_cmd(cmd: List[str], debug: bool) -> None:
    """Print the command line to stderr if debug is enabled."""
    if debug:
        print("RUN:", " ".join(cmd), file=sys.stderr)


def _maybe_dump_stderr(stderr_data: bytes, proc_name: str, exit_code: int, debug: bool) -> None:
    """Write captured stderr to the script's stderr if debugging or the command failed."""
    if stderr_data and (debug or exit_code != 0):
        sys.stderr.buffer.write(
            f"--- {proc_name} stderr (exit {exit_code}) ---\n".encode()
        )
        sys.stderr.buffer.write(stderr_data)
        if not stderr_data.endswith(b"\n"):
            sys.stderr.buffer.write(b"\n")
        sys.stderr.buffer.write(b"--- end ---\n")
        sys.stderr.buffer.flush()


def _check_return_code(exit_code: int, proc_name: str, stderr_data: bytes, debug: bool) -> None:
    """Exit with an error if *exit_code* is non‑zero, dumping stderr first."""
    _maybe_dump_stderr(stderr_data, proc_name, exit_code, debug)
    if exit_code != 0:
        print(f"Error: {proc_name} failed with exit code {exit_code}", file=sys.stderr)
        sys.exit(1)


def _get_converter_cmd(format_name: str, seekable: bool, stdin_path: Optional[str] = None) -> List[str]:
    """Return the command line to decode the given format to WAV on stdout.

    Prefers dedicated decoders over ffmpeg for quality and efficiency:
      - flac: flac
      - wv (WavPack): wvunpack
      - ape (seekable with resolved path): mac
    Falls back to ffmpeg for everything else.
    When *seekable* is True and ffmpeg is used, the fd: protocol is invoked with
    ``-fd 0``, enabling the decoder to seek within the input.
    """
    if format_name == "flac" and shutil.which("flac"):
        return ["flac", "-d", "-c", "-"]
    if format_name == "wv" and shutil.which("wvunpack"):
        return ["wvunpack", "-wz0", "-o", "-", "-"]
    # APE: use mac if the real path of stdin is known and mac is available
    if format_name == "ape" and stdin_path is not None and shutil.which("mac"):
        return ["mac", stdin_path, "-", "-d"]
    # Fallback to ffmpeg
    if seekable:
        return [
            "ffmpeg",
            "-hide_banner",
            "-xerror",
            "-loglevel", "warning",
            "-i", "fd:", "-fd", "0",
            "-f", "wav",
            "-",
        ]
    else:
        return [
            "ffmpeg",
            "-hide_banner",
            "-xerror",
            "-loglevel", "warning",
            "-i", "pipe:0",
            "-f", "wav",
            "-",
        ]


def run_ffprobe_seekable(args: List[str], debug: bool) -> bytes:
    """Run ffprobe on a seekable stdin, rewinding afterwards.
    """
    _log_cmd(args, debug)
    proc = subprocess.Popen(
        args,
        stdin=sys.stdin.buffer,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout, stderr = proc.communicate()
    _check_return_code(proc.returncode, "ffprobe", stderr, debug)
    sys.stdin.buffer.seek(0)
    return stdout


def run_ffprobe_nonseekable(args: List[str], debug: bool) -> Tuple[bytes, bytes]:
    """Run ffprobe on a non‑seekable stdin, buffering the entire input.

    Since we can't re‑read a pipe, we read the whole stream into memory while
    simultaneously piping it to ffprobe.  Once ffprobe has seen enough data to
    identify the stream, we stop writing to it, but continue buffering the
    remainder.  The buffered data is returned for later processing phases.
    """
    _log_cmd(args, debug)
    proc = subprocess.Popen(
        args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    buffer_chunks: List[bytes] = []
    early_check = False
    write_to_ffprobe = True

    while True:
        chunk = sys.stdin.buffer.read(128 * 1024)
        if not chunk:
            break
        buffer_chunks.append(chunk)

        if write_to_ffprobe:
            try:
                proc.stdin.write(chunk)
                proc.stdin.flush()
            except BrokenPipeError:
                pass

            if proc.poll() is not None:
                ffprobe_stdout = proc.stdout.read()
                ret = proc.returncode
                if ret != 0 or _probe_input(ffprobe_stdout) is None:
                    stderr_tail = proc.stderr.read()
                    _maybe_dump_stderr(stderr_tail, "ffprobe", ret, debug)
                    print(
                        "Error: input must contain exactly one audio stream.",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                write_to_ffprobe = False
                early_check = True

    if not early_check:
        proc.stdin.close()
        ffprobe_stdout, stderr = proc.communicate()
        _check_return_code(proc.returncode, "ffprobe", stderr, debug)
        if _probe_input(ffprobe_stdout) is None:
            print(
                "Error: input must contain exactly one audio stream.",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        # consume remaining stderr
        stderr_tail = proc.stderr.read()

    original_data = b"".join(buffer_chunks)
    del buffer_chunks
    return ffprobe_stdout, original_data


def _detect_bitdepth_from_data(
    wav_data: bytes, debug: bool
) -> int:
    """Run SoX stats on *wav_data* and return the detected bit‑depth.

    Exits with an error if the bit‑depth cannot be determined.
    Used when the input is non‑seekable and has already been decoded to WAV.
    """
    sox_env = _sox_env()
    cmd = ["sox", "-D", "-t", "wav", "-", "-n", "stats"]
    _log_cmd(cmd, debug)
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=sox_env,
    )
    stderr = proc.communicate(input=wav_data)[1]
    _check_return_code(proc.returncode, "sox (bitdepth)", stderr, debug)
    bitdepth = parse_bitdepth_from_stats(stderr)
    if bitdepth is None:
        print("Error: could not determine audio bit‑depth.", file=sys.stderr)
        sys.exit(1)
    if debug:
        print(f"Detected bit‑depth: {bitdepth}", file=sys.stderr)
    return bitdepth


def _detect_bitdepth_seekable(
    needs_convert: bool, format_name: str, seekable: bool, debug: bool, stdin_path: Optional[str] = None
) -> int:
    """Detect bit‑depth from seekable stdin by (if necessary) decoding and running SoX stats.

    Rewinds stdin afterwards so that later passes can read the data afresh.
    """
    sys.stdin.buffer.seek(0)
    if needs_convert:
        conv_cmd = _get_converter_cmd(format_name, seekable, stdin_path=stdin_path)
        _log_cmd(conv_cmd, debug)
        conv_proc = subprocess.Popen(
            conv_cmd,
            stdin=sys.stdin.buffer,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        sox_env = _sox_env()
        sox_cmd = ["sox", "-D", "-t", "wav", "-", "-n", "stats"]
        _log_cmd(sox_cmd, debug)
        sox_proc = subprocess.Popen(
            sox_cmd,
            stdin=conv_proc.stdout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=sox_env,
        )
        conv_proc.stdout.close()
        sox_stderr = sox_proc.communicate()[1]
        conv_stderr = conv_proc.communicate()[1]
        _check_return_code(sox_proc.returncode, "sox (bitdepth)", sox_stderr, debug)
        _check_return_code(conv_proc.returncode, conv_cmd[0], conv_stderr, debug)
    else:
        sox_env = _sox_env()
        sox_cmd = ["sox", "-D", "-t", "wav", "-", "-n", "stats"]
        _log_cmd(sox_cmd, debug)
        sox_proc = subprocess.Popen(
            sox_cmd,
            stdin=sys.stdin.buffer,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=sox_env,
        )
        sox_stderr = sox_proc.communicate()[1]
        _check_return_code(sox_proc.returncode, "sox (bitdepth)", sox_stderr, debug)

    bitdepth = parse_bitdepth_from_stats(sox_stderr)
    if bitdepth is None:
        print("Error: could not determine audio bit‑depth.", file=sys.stderr)
        sys.exit(1)
    if debug:
        print(f"Detected bit‑depth: {bitdepth}", file=sys.stderr)
    sys.stdin.buffer.seek(0)  # rewind for later stages
    return bitdepth


def main() -> None:
    """Main entry point: orchestrate probing, gain estimation, and final processing."""
    args = parse_args()
    target_sr = args.sample_rate
    debug = args.debug
    keep_8bit = args.keep_input_bitdepth_if_8bit

    if sys.stdin.isatty():
        print(
            "Error: stdin is a terminal, input must be piped or redirected.",
            file=sys.stderr,
        )
        sys.exit(1)

    ffprobe_args = [
        "ffprobe",
        "-v",
        "warning",
        "-hide_banner",
        "-print_format",
        "json",
        "-show_streams",
        "-show_format",
        "-i",
        "-",
    ]

    # ------------------------------------------------------------------
    # Phase 1 – ffprobe & data acquisition
    # ------------------------------------------------------------------
    seekable = sys.stdin.buffer.seekable()
    if seekable:
        ffprobe_stdout = run_ffprobe_seekable(ffprobe_args, debug)
        original_data = None
    else:
        ffprobe_stdout, original_data = run_ffprobe_nonseekable(ffprobe_args, debug)

    probe_result = _probe_input(ffprobe_stdout)
    if probe_result is None:
        print(
            "Error: input must contain exactly one audio stream.",
            file=sys.stderr,
        )
        sys.exit(1)

    stream_info, format_name = probe_result
    src_sr = stream_info["sample_rate"]
    fmt = stream_info["sample_fmt"]

    # Try to resolve the real path of stdin for APE decoding via mac
    stdin_realpath = None
    if format_name == "ape" and seekable:
        try:
            # Linux /proc/self/fd/0
            stdin_realpath = os.readlink('/proc/self/fd/0')
        except (OSError, AttributeError):
            try:
                # macOS /dev/fd/0
                stdin_realpath = os.readlink('/dev/fd/0')
            except OSError:
                pass

    # Determine if input is already WAV format.
    needs_convert = format_name != "wav"
    need_resample = src_sr != target_sr

    # ------------------------------------------------------------------
    # Phase 1b – Determine effective bit‑depth (and dithering need)
    # ------------------------------------------------------------------
    if fmt in ("u8", "s16", "s16p"):
        need_dither = False
        actual_bitdepth = {"u8": 8, "s16": 16, "s16p": 16}[fmt]
    else:
        # For non‑trivial formats, detect actual bit‑depth via SoX stats.
        if seekable:
            actual_bitdepth = _detect_bitdepth_seekable(needs_convert, format_name, seekable, debug, stdin_path=stdin_realpath)
        else:
            # For non‑seekable input we must decode (if needed) into a single buffer first.
            if needs_convert:
                conv_cmd = _get_converter_cmd(format_name, seekable)
                _log_cmd(conv_cmd, debug)
                conv_proc = subprocess.Popen(
                    conv_cmd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                converted_wav, conv_stderr = conv_proc.communicate(input=original_data)
                _check_return_code(conv_proc.returncode, conv_cmd[0], conv_stderr, debug)
                original_data = None  # no longer needed
                data_for_detect = converted_wav
            else:
                data_for_detect = original_data
            actual_bitdepth = _detect_bitdepth_from_data(data_for_detect, debug)
            # Save the (possibly converted) data for later stages.
            if needs_convert:
                data_for_sox = data_for_detect  # already converted
            else:
                data_for_sox = data_for_detect

        need_dither = actual_bitdepth > 16

        if debug:
            print(
                f"Effective bit‑depth: {actual_bitdepth} → dither needed: {need_dither}",
                file=sys.stderr,
            )

    # ------------------------------------------------------------------
    # Phase 2 – Gain estimation (skip if no dithering/resampling would occur)
    # ------------------------------------------------------------------
    if not need_dither and not need_resample:
        attenuation_val = 0.0
        sox_stderr = b""
        if debug:
            print("Skipping gain estimation – no dither or resample needed.", file=sys.stderr)
    else:
        if seekable:
            sys.stdin.buffer.seek(0)

            def run_sox_with_input(stdin_src, input_type):
                cmd = build_gain_estimation_sox_cmd(
                    input_type, fmt, src_sr, target_sr, need_dither
                )
                _log_cmd(cmd, debug)
                return subprocess.Popen(
                    cmd,
                    stdin=stdin_src,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    env=_sox_env(),
                )

            if needs_convert:
                conv_cmd = _get_converter_cmd(format_name, seekable, stdin_path=stdin_realpath)
                _log_cmd(conv_cmd, debug)
                conv_proc = subprocess.Popen(
                    conv_cmd,
                    stdin=sys.stdin.buffer,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                sox_proc = run_sox_with_input(conv_proc.stdout, "wav")
                conv_proc.stdout.close()

                sox_stderr = sox_proc.communicate()[1]
                conv_stderr = conv_proc.communicate()[1]

                _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)
                _check_return_code(conv_proc.returncode, conv_cmd[0], conv_stderr, debug)
            else:
                sox_proc = run_sox_with_input(sys.stdin.buffer, "wav")
                sox_stderr = sox_proc.communicate()[1]
                _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)
        else:
            # non‑seekable: data_for_sox already contains decoded audio (if needed)
            sox_cmd = build_gain_estimation_sox_cmd(
                "wav", fmt, src_sr, target_sr, need_dither
            )
            _log_cmd(sox_cmd, debug)
            sox_proc = subprocess.Popen(
                sox_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                env=_sox_env(),
            )
            sox_stderr = sox_proc.communicate(input=data_for_sox)[1]
            _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)

        # Parse loudness statistics – both must succeed or we abort.
        if debug and sox_stderr:
            sys.stderr.buffer.write(sox_stderr)
            sys.stderr.buffer.flush()

        peak_db = parse_peak_from_stats(sox_stderr)
        if peak_db is None:
            print("Error: could not determine peak level from SoX stats.", file=sys.stderr)
            sys.exit(1)
        attenuation_val = compute_attenuation(peak_db)

    # ------------------------------------------------------------------
    # Phase 3 – Final audio production
    # ------------------------------------------------------------------
    production_input_type = "wav"
    need_sox_cmd = build_production_sox_cmd(
        production_input_type,
        fmt,
        src_sr,
        target_sr,
        attenuation_val,
        keep_8bit,
        need_dither,
    )

    sox_env = _sox_env()

    if seekable:
        sys.stdin.buffer.seek(0)

        if needs_convert:
            conv_cmd = _get_converter_cmd(format_name, seekable, stdin_path=stdin_realpath)
            _log_cmd(conv_cmd, debug)
            conv_proc = subprocess.Popen(
                conv_cmd,
                stdin=sys.stdin.buffer,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            if need_sox_cmd is not None:
                _log_cmd(need_sox_cmd, debug)
                sox_proc = subprocess.Popen(
                    need_sox_cmd,
                    stdin=conv_proc.stdout,
                    stdout=sys.stdout.buffer,
                    stderr=subprocess.PIPE,
                    env=sox_env,
                )
                conv_proc.stdout.close()
                sox_stderr = sox_proc.communicate()[1]
                conv_stderr = conv_proc.communicate()[1]
                _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)
                _check_return_code(conv_proc.returncode, conv_cmd[0], conv_stderr, debug)
            else:
                shutil.copyfileobj(conv_proc.stdout, sys.stdout.buffer)
                conv_stderr = conv_proc.communicate()[1]
                _check_return_code(conv_proc.returncode, conv_cmd[0], conv_stderr, debug)
        else:
            # Already WAV
            if need_sox_cmd is not None:
                _log_cmd(need_sox_cmd, debug)
                sox_proc = subprocess.Popen(
                    need_sox_cmd,
                    stdin=sys.stdin.buffer,
                    stdout=sys.stdout.buffer,
                    stderr=subprocess.PIPE,
                    env=sox_env,
                )
                sox_stderr = sox_proc.communicate()[1]
                _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)
            else:
                shutil.copyfileobj(sys.stdin.buffer, sys.stdout.buffer)
    else:
        # Non‑seekable: final data is still in memory.
        if needs_convert:
            data = data_for_sox  # converted WAV
        else:
            data = original_data

        if need_sox_cmd is not None:
            _log_cmd(need_sox_cmd, debug)
            sox_proc = subprocess.Popen(
                need_sox_cmd,
                stdin=subprocess.PIPE,
                stdout=sys.stdout.buffer,
                stderr=subprocess.PIPE,
                env=sox_env,
            )
            sox_stderr = sox_proc.communicate(input=data)[1]
            _check_return_code(sox_proc.returncode, "sox", sox_stderr, debug)
        else:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    sys.exit(0)


if __name__ == "__main__":
    main()
