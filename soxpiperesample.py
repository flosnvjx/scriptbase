#!/usr/bin/env python3
# vim: set tabstop=2 shiftwidth=2:

"""
soxpiperesample - resample audio from stdin, applying gain to avoid clipping.

Pipeline: stdin -> ffprobe (read metadata) -> ffmpeg decode test
         -> sox gain-search loop (with opposite-rate resampling to detect
            clipping on the alternate playback rate) -> final sox output.

The single argument selects the desired output sample rate: 44100 or 48000.
If unspecified, usage is printed and the script exits.

The final output sample format is always 16‑bit PCM, dithered if the input
is a higher bit depth.  A minimal gain is applied so that no clipping
occurs when the stream is later converted to the *other* sample rate
(e.g. if the user requests 44100, the gain is determined at 48000).
"""

import sys
import subprocess
import re


def parse_args():
	"""Return user-requested target sample rate (44100 or 48000).

	If no argument is given, print usage to stderr and exit.
	"""
	if len(sys.argv) == 1:
		print("Usage: soxpiperesample.py [44100|48000]", file=sys.stderr)
		sys.exit(1)
	if len(sys.argv) > 2:
		print("Usage: soxpiperesample.py [44100|48000]", file=sys.stderr)
		sys.exit(1)
	rate_str = sys.argv[1]
	if rate_str not in ("44100", "48000"):
		print("Error: target rate must be 44100 or 48000", file=sys.stderr)
		sys.exit(1)
	return int(rate_str)


def ffprobe_info(stdin_source, is_seekable, input_data=None):
	"""Run ffprobe on the audio source and return stream metadata dict."""
	cmd = [
		"ffprobe", "-loglevel", "warning",
		"-of", "flat", "-show_streams",
		"-i", "pipe:0",
	]
	if is_seekable:
		stdin_source.seek(0)
		proc = subprocess.Popen(cmd, stdin=stdin_source,
		                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	else:
		proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
		                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		proc.stdin.write(input_data)
		proc.stdin.close()

	out, err = proc.communicate()
	if proc.returncode != 0:
		print("ffprobe failed:", err.decode(errors="replace"), file=sys.stderr)
		sys.exit(1)

	info = {}
	for line in out.decode().splitlines():
		m = re.match(r"^([^=]+)=(.*)$", line)
		if m:
			key = m.group(1)
			val = m.group(2).strip('"')
			info[key] = val
	return info


def test_decode(stdin_source, is_seekable, input_data=None):
	"""Decode the whole input to NULL to verify it is valid."""
	cmd = [
		"ffmpeg", "-loglevel", "warning", "-xerror", "-err_detect", "explode",
		"-i", "pipe:0", "-f", "null", "-",
	]
	if is_seekable:
		stdin_source.seek(0)
		proc = subprocess.Popen(cmd, stdin=stdin_source,
		                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
	else:
		proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
		                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
		proc.stdin.write(input_data)
		proc.stdin.close()

	out, err = proc.communicate()
	if proc.returncode != 0:
		print("ffmpeg test decode failed:", err.decode(errors="replace"), file=sys.stderr)
		sys.exit(1)


def build_sox_effects(gain, is_s16, input_rate, target_rate, opposite_rate=None):
	"""Construct the list of SoX effects for a pipeline stage.

	opposite_rate, if given, appends a final 'rate -m <opposite_rate>'
	conversion used only during gain estimation to detect clipping at the
	alternate playback rate.
	"""
	effects = []
	if gain > 0:
		effects += ["vol", "-{:.1f}dB".format(gain)]
	if input_rate != target_rate:
		effects += ["rate", str(target_rate)]
	if not is_s16:
		effects.append("dither")
	if opposite_rate is not None:
		effects += ["rate", "-m", str(opposite_rate)]
	return effects


def run_gain_trial(stdin_source, is_seekable, input_data, gain,
                   is_s16, input_rate, target_rate, opposite_rate):
	"""Run ffmpeg | sox pipeline, capturing stderr to check for clipping."""
	ffmpeg_cmd = [
		"ffmpeg", "-loglevel", "warning", "-xerror", "-err_detect", "explode",
		"-i", "pipe:0", "-f", "wav", "-",
	]
	sox_cmd = ["sox", "-D", "-t", "wav", "--ignore-length", "-"]
	if not is_s16:
		sox_cmd += ["-b", "16"]
	sox_cmd += build_sox_effects(gain, is_s16, input_rate, target_rate, opposite_rate)
	sox_cmd += ["-t", "wav", "-"]

	if is_seekable:
		stdin_source.seek(0)
		ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=stdin_source,
		                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	else:
		ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE,
		                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		ffmpeg_proc.stdin.write(input_data)
		ffmpeg_proc.stdin.close()

	sox_proc = subprocess.Popen(sox_cmd, stdin=ffmpeg_proc.stdout,
	                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
	ffmpeg_proc.stdout.close()

	ffmpeg_stderr = ffmpeg_proc.stderr.read()
	sox_stderr = sox_proc.stderr.read()
	ffmpeg_ret = ffmpeg_proc.wait()
	sox_ret = sox_proc.wait()

	combined = ffmpeg_stderr.decode(errors="replace") + sox_stderr.decode(errors="replace")

	if ffmpeg_ret != 0:
		return False, combined

	return True, combined


def run_final_output(stdin_source, is_seekable, input_data, gain,
                     is_s16, input_rate, target_rate):
	"""Run ffmpeg | sox pipeline, stderr goes directly to the script's stderr."""
	ffmpeg_cmd = [
		"ffmpeg", "-loglevel", "warning", "-xerror", "-err_detect", "explode",
		"-i", "pipe:0", "-f", "wav", "-",
	]
	sox_cmd = ["sox", "-D", "-t", "wav", "--ignore-length", "-"]
	if not is_s16:
		sox_cmd += ["-b", "16"]
	sox_cmd += build_sox_effects(gain, is_s16, input_rate, target_rate)
	sox_cmd += ["-t", "wav", "-"]

	if is_seekable:
		stdin_source.seek(0)
		ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=stdin_source,
		                               stdout=subprocess.PIPE, stderr=sys.stderr)
	else:
		ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE,
		                               stdout=subprocess.PIPE, stderr=sys.stderr)
		ffmpeg_proc.stdin.write(input_data)
		ffmpeg_proc.stdin.close()

	sox_proc = subprocess.Popen(sox_cmd, stdin=ffmpeg_proc.stdout,
	                            stdout=sys.stdout.buffer, stderr=sys.stderr)
	ffmpeg_proc.stdout.close()

	ffmpeg_ret = ffmpeg_proc.wait()
	sox_ret = sox_proc.wait()

	if ffmpeg_ret != 0 or sox_ret != 0:
		sys.exit(1)


def print_summary(gain, is_s16, input_fmt, input_rate, target_rate):
	"""Print processing summary to stderr if stderr is a terminal."""
	if not sys.stderr.isatty():
		return
	parts = []
	if input_rate != target_rate:
		parts.append("{}Hz -> {}Hz".format(input_rate, target_rate))
	if not is_s16:
		fmt_label = input_fmt if input_fmt else "non-s16"
		parts.append(fmt_label)
		parts.append("dither")
	if gain > 0:
		parts.append("gain -{:.1f}dB".format(gain))
	if parts:
		print("soxpipe: {}".format(", ".join(parts)), file=sys.stderr)


def main():
	target_rate = parse_args()

	if sys.stdin.isatty():
		print("Error: stdin must be a pipe or file", file=sys.stderr)
		sys.exit(1)

	stdin_buf = sys.stdin.buffer
	is_seekable = stdin_buf.seekable()

	if not is_seekable:
		input_data = stdin_buf.read()
		if not input_data:
			print("Error: no input data", file=sys.stderr)
			sys.exit(1)
	else:
		input_data = None

	# Probe parameters
	info = ffprobe_info(stdin_buf, is_seekable, input_data)
	try:
		input_rate = int(info.get("streams.stream.0.sample_rate", 0))
	except ValueError:
		print("Invalid sample rate from ffprobe", file=sys.stderr)
		sys.exit(1)
	input_fmt = info.get("streams.stream.0.sample_fmt", "")
	is_s16 = input_fmt in ("s16", "s16p")

	# Verify decodable
	test_decode(stdin_buf, is_seekable, input_data)

	# The rate our playback hardware might use (opposite of target)
	opposite_rate = 48000 if target_rate == 44100 else 44100

	# Gain estimation - iterate until no clipping is reported at opposite rate
	gain = 0.0
	while True:
		success, stderr_text = run_gain_trial(
			stdin_buf, is_seekable, input_data, gain,
			is_s16, input_rate, target_rate, opposite_rate
		)
		if not success:
			print("Pipeline error:", stderr_text, file=sys.stderr)
			sys.exit(1)
		if "clipped" not in stderr_text:
			break
		gain += 0.1

	# Print summary before final output (only to terminal)
	print_summary(gain, is_s16, input_fmt, input_rate, target_rate)

	# Final output - stderr passes through directly, audio goes to stdout
	run_final_output(stdin_buf, is_seekable, input_data, gain,
	                 is_s16, input_rate, target_rate)


if __name__ == "__main__":
	main()
