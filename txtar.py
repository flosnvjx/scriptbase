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

Exit codes:
  0: success
  1: any error (I/O, parse, security, directory entry, etc.)
"""

import argparse
import os
import sys
from pathlib import Path

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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract or list files from a txtar archive.",
        epilog="If ARCHIVE is '-' or omitted, read from stdin.",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument('-e', '--extract', action='store_true', help='Extract files (default)')
    group.add_argument('-l', '--list', action='store_true', help='List files only')
    parser.add_argument('-C', '--chdir', metavar='DIR', help='Change to DIR before operation')
    parser.add_argument('-v', '--verbose', action='store_true', help='Increase verbosity')
    parser.add_argument('archive', nargs='?', default='-', help='Archive file (default: stdin)')

    args = parser.parse_args()

    # Default to extract mode if neither -e nor -l is given
    extract_mode = not args.list

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

    if extract_mode:
        # Extract files – abort on directory entry
        for filename, content in files:
            if filename.endswith('/'):
                sys.stderr.write(f"txtar: aborting: directory entry not allowed: '{filename}'\n")
                sys.exit(1)
            try:
                extract_file(filename, content, args.verbose)
            except (OSError, ValueError) as e:
                sys.stderr.write(f"txtar: error extracting '{filename}': {e}\n")
                sys.exit(1)
    else:
        # List mode – also abort on directory entry, but print size+name to stderr
        for filename, content in files:
            if filename.endswith('/'):
                sys.stderr.write(f"{len(content)} {filename}\n")
                sys.exit(1)
            if args.verbose:
                print(f"{len(content)} {filename}")
            else:
                print(filename)


if __name__ == '__main__':
    main()
