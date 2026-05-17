#!/usr/bin/env python3
"""
txtar - extract or list files from a txtar archive.

This tool reads a txtar archive (as defined by the Go toolchain) and either
extracts its file entries to the current directory or lists them. It follows
GNU-style long options and mimics some behaviours of tar(1).

By default, the tool extracts files. Use -l/--list to list entries instead.
If the archive argument is omitted or '-', input is read from stdin.

Directory entries (filenames ending with '/') are rejected in both modes:
- In extract mode: the tool aborts with an error.
- In list mode: the tool prints the size and name to stderr and aborts.

Extraction rules:
- Parent directories are created automatically (like mkdir -p).
- Regular files: overwritten in place (no unlink), but if content is identical,
  the write is skipped to reduce wear (verbose mode shows 'skip').
- Symbolic links: unlinked before writing the new file.
- Directories: error (cannot overwrite) and abort.
- Paths that would escape the current directory (absolute or with '..') are
  rejected as a security measure.

Verbose output (-v/--verbose):
- For list mode: prints '<size> <filename>' for each normal file.
- For extract mode: prints 'created:', 'overwrite:', or 'skip:' before each file.

Helper support (--helpers SPEC):
- Enables special processing for selected file entries.
- SPEC is comma-separated list of helperName[:option[=value]].
- Only helper 'roodiff' is currently supported.
- roodiff recognizes file members containing a RooCode-style diff patch
  (with '<<<<<<< SEARCH' marker). In extract mode, such members are not written
  to disk; instead the patch is applied to the target file using an external
  script (apply_diff.py by default). In list mode, such members are prefixed
  with '(roodiff[:N])' where N is the number of diff blocks.
- Options for roodiff: runpipe=PATH (path to patch application script).

Exit codes:
  0: success
  1: any error (I/O, parse, security, directory entry, patch failure, etc.)
"""

import argparse
import os
import sys
import subprocess
from pathlib import Path

# ---------------------------------------------------------------------------
# Helper specification parsing
# ---------------------------------------------------------------------------
def parse_helpers_spec(spec: str):
    """
    Parse --helpers SPEC string.

    Format: helperName[:option[=value]][,helperName[:option[=value]]...]
    Returns: dict { helperName: { optionName: value } }
    Raises ValueError on malformed input.
    """
    if not spec:
        return {}

    helpers = {}
    for part in spec.split(','):
        if not part:
            raise ValueError("empty helper name")
        # Split helperName and options
        if ':' in part:
            name, opt_str = part.split(':', 1)
        else:
            name, opt_str = part, ''
        if not name:
            raise ValueError("empty helper name")
        if name in helpers:
            raise ValueError(f"duplicate helper: '{name}'")
        helpers[name] = {}
        if opt_str:
            # Split options by colon
            for opt_pair in opt_str.split(':'):
                if '=' in opt_pair:
                    opt, val = opt_pair.split('=', 1)
                    if not opt:
                        raise ValueError(f"empty option name in helper '{name}'")
                    helpers[name][opt] = val
                else:
                    # boolean option, default true
                    opt = opt_pair
                    if not opt:
                        raise ValueError(f"empty option name in helper '{name}'")
                    helpers[name][opt] = True
    return helpers


# ---------------------------------------------------------------------------
# Txtar parsing
# ---------------------------------------------------------------------------
def parse_txtar(data: bytes) -> list[tuple[str, bytes]]:
    """
    Parse a txtar archive from bytes.

    The txtar format is:
        optional comment (ignored)
        -- filename --
        file content (bytes, may contain newlines)
        -- next filename --
        ...

    Args:
        data: Raw bytes of the txtar archive.

    Returns:
        A list of (filename, content_bytes) tuples, in order of appearance.

    Raises:
        ValueError: If the archive is malformed (e.g., invalid marker,
                    empty filename, invalid UTF-8 in filename).
    """
    lines = data.splitlines(keepends=True)
    files = []
    i = 0

    # Skip leading comment until first marker
    while i < len(lines):
        if lines[i].startswith(b'-- ') and lines[i].endswith(b' --\n'):
            break
        i += 1

    if i == len(lines):
        # No markers → empty archive
        return files

    while i < len(lines):
        # Expect a marker line
        line = lines[i]
        if not (line.startswith(b'-- ') and line.endswith(b' --\n')):
            raise ValueError("malformed archive: expected file marker")
        # Extract filename: remove '-- ' prefix and ' --\n' suffix
        filename = line[3:-4].decode('utf-8')
        if not filename:
            raise ValueError("empty filename")
        i += 1

        # Accumulate content until next marker or EOF
        content_parts = []
        while i < len(lines):
            if lines[i].startswith(b'-- ') and lines[i].endswith(b' --\n'):
                break
            content_parts.append(lines[i])
            i += 1
        content = b''.join(content_parts)
        files.append((filename, content))

    return files


# ---------------------------------------------------------------------------
# File extraction (normal mode)
# ---------------------------------------------------------------------------
def extract_file(dest_path: str, content: bytes, verbose: bool) -> str:
    """
    Write a single file to the filesystem, handling existing entries.

    Args:
        dest_path: Destination path (relative or absolute).
        content: File content as bytes.
        verbose: If True, print status messages.

    Returns:
        A status string: 'created', 'overwrite', or 'skip'.

    Raises:
        ValueError: If the path is invalid (e.g., attempts to escape CWD).
        OSError: If the destination is a directory or a special file that
                 cannot be overwritten, or if writing fails.
    """
    dest = Path(dest_path)

    # Security: reject absolute paths or paths with '..' that escape CWD
    try:
        resolved = dest.resolve()
        cwd = Path.cwd().resolve()
        if not str(resolved).startswith(str(cwd)):
            raise ValueError(f"path tries to escape current directory: {dest_path}")
    except Exception as e:
        raise ValueError(f"invalid path {dest_path}: {e}")

    # Create parent directories if needed
    dest.parent.mkdir(parents=True, exist_ok=True)

    exists = dest.exists()
    status = None

    if exists:
        if dest.is_dir():
            raise OSError(f"cannot overwrite directory: {dest}")
        elif dest.is_symlink():
            # Remove symlink before writing new file
            dest.unlink()
            status = "overwrite"
        elif dest.is_file():
            # Compare content to avoid unnecessary writes
            with dest.open('rb') as f:
                existing = f.read()
            if existing == content:
                status = "skip"
            else:
                status = "overwrite"
        else:
            raise OSError(f"cannot overwrite special file: {dest}")
    else:
        status = "created"

    # Write only if not skipped
    if status != "skip":
        with dest.open('wb') as f:
            f.write(content)

    if verbose and status:
        # Print relative path for cleaner output
        rel_path = dest.relative_to(Path.cwd())
        print(f"{status}: {rel_path}")

    return status


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract or list files from a txtar archive.",
        epilog="If ARCHIVE is '-' or omitted, read from stdin.",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument('-e', '--extract', action='store_true', help='Extract files (default)')
    group.add_argument('-l', '--list', action='store_true', help='List files only')
    parser.add_argument('-C', '--chdir', metavar='DIR', help='Change to DIR before operation')
    parser.add_argument('-v', '--verbose', action='count', default=0,
                        help='Increase verbosity (-v, -vv for more)')
    parser.add_argument('--helpers', metavar='SPEC', help='Enable helpers (comma-separated specs)')
    parser.add_argument('archive', nargs='?', default='-', help='Archive file (default: stdin)')

    args = parser.parse_args()

    # Determine mode: extract is default if neither -e nor -l given
    extract_mode = not args.list

    # Parse helper spec if provided
    helpers = {}
    roodiff_enabled = False
    roodiff_runpipe = 'apply_diff.py'
    if args.helpers:
        try:
            helpers = parse_helpers_spec(args.helpers)
        except ValueError as e:
            sys.stderr.write(f"txtar: invalid --helpers spec: {e}\n")
            sys.exit(1)

        if 'roodiff' in helpers:
            roodiff_enabled = True
            roodiff_runpipe = helpers['roodiff'].get('runpipe', 'apply_diff.py')

    # Change directory if requested
    if args.chdir:
        try:
            os.chdir(args.chdir)
        except OSError as e:
            sys.stderr.write(f"txtar: cannot chdir to '{args.chdir}': {e}\n")
            sys.exit(1)

    # Read archive data
    try:
        if args.archive == '-':
            data = sys.stdin.buffer.read()
        else:
            with open(args.archive, 'rb') as f:
                data = f.read()
    except OSError as e:
        sys.stderr.write(f"txtar: cannot read '{args.archive}': {e}\n")
        sys.exit(1)

    # Parse archive
    try:
        files = parse_txtar(data)
    except (ValueError, UnicodeDecodeError) as e:
        sys.stderr.write(f"txtar: parse error: {e}\n")
        sys.exit(1)

    # -----------------------------------------------------------------------
    # List mode
    # -----------------------------------------------------------------------
    if not extract_mode:
        for filename, content in files:
            # Directory entry handling: abort with size+name to stderr
            if filename.endswith('/'):
                sys.stderr.write(f"{len(content)} {filename}\n")
                sys.exit(1)

            # Determine prefix based on roodiff detection
            if roodiff_enabled and b'<<<<<<< SEARCH' in content:
                blocks = content.count(b'<<<<<<< SEARCH')
                if blocks == 1:
                    prefix = "(roodiff)"
                else:
                    prefix = f"(roodiff:{blocks})"
            else:
                prefix = "(file)"

            if args.verbose:
                print(f"{prefix} {len(content)} {filename}")
            else:
                print(f"{prefix} {filename}")
        return

    # -----------------------------------------------------------------------
    # Extract mode
    # -----------------------------------------------------------------------
    for filename, content in files:
        # Directory entry handling: abort
        if filename.endswith('/'):
            sys.stderr.write(f"txtar: aborting: directory entry not allowed: '{filename}'\n")
            sys.exit(1)

        # Check if this is a roodiff patch and helper is enabled
        is_roodiff = roodiff_enabled and b'<<<<<<< SEARCH' in content

        if is_roodiff:
            # Target file path (same as filename)
            target = Path(filename)

            # Security: reject absolute paths or path traversal
            try:
                resolved = target.resolve()
                cwd = Path.cwd().resolve()
                if not str(resolved).startswith(str(cwd)):
                    raise ValueError("path tries to escape current directory")
            except Exception as e:
                sys.stderr.write(f"txtar: [roodiff] invalid target path '{filename}': {e}\n")
                sys.exit(1)

            # Check if target is a symlink -> skip with warning
            if target.is_symlink():
                sys.stderr.write(f"txtar: [roodiff] target is a symlink, skipping: {filename}\n")
                continue

            # Check if target is a regular file (and exists)
            if not target.is_file():
                sys.stderr.write(f"txtar: [roodiff] unable to locate {filename} as patch target file\n")
                continue

            # Build command for apply_diff script
            cmd = [roodiff_runpipe, '-f', '-', str(target)]
            if args.verbose >= 2:
                # Insert -v after the script name
                cmd.insert(1, '-v')

            # Invoke script
            try:
                proc = subprocess.run(
                    cmd,
                    input=content,
                    capture_output=True,
                    text=True,
                    check=False
                )
            except FileNotFoundError:
                sys.stderr.write(f"txtar: cannot run apply script '{roodiff_runpipe}': command not found\n")
                sys.exit(1)
            except Exception as e:
                sys.stderr.write(f"txtar: cannot run apply script '{roodiff_runpipe}': {e}\n")
                sys.exit(1)

            # Handle script output
            if proc.returncode != 0:
                # Failure: print error details
                sys.stderr.write(f"txtar: patch application failed for '{filename}' (exit code {proc.returncode})\n")
                if proc.stdout:
                    for line in proc.stdout.splitlines():
                        sys.stderr.write(f"[roodiff] {line}\n")
                if proc.stderr:
                    for line in proc.stderr.splitlines():
                        sys.stderr.write(f"[roodiff] {line}\n")
                sys.exit(1)
            else:
                # Success: optionally print script output if verbose
                if args.verbose >= 1:
                    if proc.stdout:
                        for line in proc.stdout.splitlines():
                            sys.stderr.write(f"[roodiff] {line}\n")
                    if proc.stderr:
                        for line in proc.stderr.splitlines():
                            sys.stderr.write(f"[roodiff] {line}\n")
                # Do NOT write patch content to disk
                continue

        # Not a roodiff patch (or helper not enabled) -> normal extraction
        try:
            extract_file(filename, content, args.verbose >= 1)
        except (OSError, ValueError) as e:
            sys.stderr.write(f"txtar: error extracting '{filename}': {e}\n")
            sys.exit(1)


if __name__ == '__main__':
    main()
