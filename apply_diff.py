#!/usr/bin/env python3
"""
apply_diff – Apply a SEARCH/REPLACE patch to a file (RooCode/OpenViking style).

The tool supports two modes of operation:

1. **File patch** (``-f FILE``):  
   Read a multi‑block patch in ``<<<<<<< SEARCH`` / ``=======`` / ``>>>>>>> REPLACE``
   format from *FILE* (use ``-`` to read from stdin).  The patch is applied to the
   target file using the same strategy as RooCode’s apply_diff: exact substring
   replacement is tried first, then a line‑based middle‑out fuzzy search with
   indentation preservation.

2. **Inline StrPatch** (``-s SEARCH -r REPLACE [-L N]``):  
   Supply a single search/replace pair directly on the command line.  ``-s`` and
   ``-r`` are both required; ``-L`` defaults to **1** (line‑number hint).  The
   tool internally constructs a SEARCH/REPLACE diff block and applies it.

For both modes the modified content can be written back to the target file **in
place** (default), or to a different output file (``-o PATH``, ``-`` for stdout).
When patching fails, the original target file is **never** overwritten, and no
output file is written.

If the patch cannot be applied, a detailed error message is printed to stderr,
containing:

- similarity score of the best match,
- the search range (line numbers),
- the best‑match fragment with line numbers,
- the original search content,
- additional debug hints.

Options:
  -f FILE, --file FILE   patch file path (“-” for stdin)
  -s SEARCH, --search SEARCH
                         search string (requires -r)
  -r REPLACE, --replace REPLACE
                         replace string (required with -s)
  -L N, --start-line N   start‑line hint (default 0 when -s is used)
  -o PATH, --output PATH write output to PATH (“-” for stdout)
  -l N, --buffer-lines N extra context lines for fuzzy search (default 40)
  -v, --verbose          increase log verbosity (-v INFO, -vv DEBUG)
  -t F, --fuzzy-threshold F
                         similarity threshold 0.0–1.0 (default 1.0 = exact)
  TARGET                 file to patch (positional)

Examples:
  apply_diff -f changes.patch myfile.py
  apply_diff -s "old code" -r "new code" -L 42 myfile.py
  apply_diff -f - -o - myfile.py < patch.diff
"""

import argparse
import logging
import sys
import re
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, List, Optional

__version__ = "1.0.0"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logger = logging.getLogger("apply_diff")
_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
logger.addHandler(_handler)
logger.setLevel(logging.WARNING)  # changed by -v


# ---------------------------------------------------------------------------
# Utility functions (from RooCode / OpenViking)
# ---------------------------------------------------------------------------
def levenshtein_distance(s1: str, s2: str) -> int:
    """Calculate Levenshtein distance between two strings."""
    if len(s1) < len(s2):
        return levenshtein_distance(s2, s1)
    if len(s2) == 0:
        return len(s1)

    previous_row = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    return previous_row[-1]


def normalize_string(text: str) -> str:
    """Normalize smart quotes and invisible characters."""
    replacements = {
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u00a0": " ",
        "\u200b": "",
        "\u200c": "",
        "\u200d": "",
        "\u200e": "",
        "\u200f": "",
        "\ufeff": "",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def get_similarity(original: str, search: str) -> float:
    """Return similarity ratio between 0 and 1."""
    if search == "":
        return 0.0
    normalized_original = normalize_string(original)
    normalized_search = normalize_string(search)
    if normalized_original == normalized_search:
        return 1.0
    dist = levenshtein_distance(normalized_original, normalized_search)
    max_length = max(len(normalized_original), len(normalized_search))
    return 1.0 - (dist / max_length) if max_length > 0 else 1.0


def add_line_numbers(content: str, start_line: int = 1) -> str:
    """Prepend 'N | ' to each line."""
    lines = content.split("\n")
    numbered_lines = [f"{start_line + i} | {line}" for i, line in enumerate(lines)]
    return "\n".join(numbered_lines)


def strip_line_numbers(content: str, aggressive: bool = False) -> str:
    """Remove leading line numbers from content."""
    if aggressive:
        return re.sub(r"^\s*\d+\s*[|:]\s*", "", content, flags=re.MULTILINE)
    return re.sub(r"^\d+\s*\|\s*", "", content, flags=re.MULTILINE)


def every_line_has_line_numbers(content: str) -> bool:
    """Check whether every non‑empty line starts with a line‑number pattern."""
    lines = content.split("\n")
    if not lines:
        return False
    return all(re.match(r"^\d+\s*\|\s*", line) for line in lines)


def unescape_markers(content: str) -> str:
    """Unescape escaped diff markers."""
    return (
        content.replace(r"\<<<<<<<", "<<<<<<<")
        .replace(r"\=======", "=======")
        .replace(r"\>>>>>>>", ">>>>>>>")
        .replace(r"\-------", "-------")
        .replace(r"\:end_line:", ":end_line:")
        .replace(r"\:start_line:", ":start_line:")
    )


class State(Enum):
    START = 1
    AFTER_SEARCH = 2
    AFTER_SEPARATOR = 3


def validate_marker_sequencing(diff_content: str) -> Dict[str, Any]:
    """Validate that SEARCH/SEPARATOR/REPLACE markers are correctly ordered."""
    state = {"current": State.START, "line": 0}
    SEARCH_PATTERN = r"^<<<<<<< SEARCH>?$"
    SEP = "======="
    REPLACE = ">>>>>>> REPLACE"
    SEARCH_PREFIX = "<<<<<<<"
    REPLACE_PREFIX = ">>>>>>>"

    def report_merge_conflict_error(found: str, _expected: str) -> Dict[str, Any]:
        return {
            "success": False,
            "error": (
                f"ERROR: Special marker '{found}' found in your diff content at line {state['line']}:\n"
                "\n"
                f"When removing merge conflict markers like '{found}' from files, you MUST escape them\n"
                "in your SEARCH section by prepending a backslash (\\) at the beginning of the line:\n"
                "\n"
                "CORRECT FORMAT:\n\n"
                "<<<<<<< SEARCH\n"
                "content before\n"
                f"\\{found}    <-- Note the backslash here in this example\n"
                "content after\n"
                "=======\n"
                "replacement content\n"
                ">>>>>>> REPLACE\n"
                "\n"
                "Without escaping, the system confuses your content with diff syntax markers.\n"
                "You may use multiple diff blocks in a single diff request, but ANY of ONLY the following "
                "separators that occur within SEARCH or REPLACE content must be escaped, as follows:\n"
                f"\\{SEARCH_PREFIX}\n"
                f"\\{SEP}\n"
                f"\\{REPLACE}\n"
            ),
        }

    def report_invalid_diff_error(found: str, expected: str) -> Dict[str, Any]:
        return {
            "success": False,
            "error": (
                f"ERROR: Diff block is malformed: marker '{found}' found in your diff content at line {state['line']}. "
                f"Expected: {expected}\n"
                "\n"
                "CORRECT FORMAT:\n\n"
                "<<<<<<< SEARCH\n"
                ":start_line: (required) The line number of original content where the search block starts.\n"
                "-------\n"
                "[exact content to find including whitespace]\n"
                "=======\n"
                "[new content to replace with]\n"
                ">>>>>>> REPLACE\n"
            ),
        }

    def report_line_marker_in_replace_error(marker: str) -> Dict[str, Any]:
        return {
            "success": False,
            "error": (
                f"ERROR: Invalid line marker '{marker}' found in REPLACE section at line {state['line']}\n"
                "\n"
                "Line markers (:start_line: and :end_line:) are only allowed in SEARCH sections.\n"
                "\n"
                "CORRECT FORMAT:\n"
                "<<<<<<< SEARCH\n"
                ":start_line:5\n"
                "content to find\n"
                "=======\n"
                "replacement content\n"
                ">>>>>>> REPLACE\n"
                "\n"
                "INCORRECT FORMAT:\n"
                "<<<<<<< SEARCH\n"
                "content to find\n"
                "=======\n"
                ":start_line:5    <-- Invalid location\n"
                "replacement content\n"
                ">>>>>>> REPLACE\n"
            ),
        }

    lines = diff_content.split("\n")
    search_count = sum(1 for l in lines if re.match(SEARCH_PATTERN, l.strip()))
    sep_count = sum(1 for l in lines if l.strip() == SEP)
    replace_count = sum(1 for l in lines if l.strip() == REPLACE)
    likely_bad_structure = search_count != replace_count or sep_count < search_count

    for line in diff_content.split("\n"):
        state["line"] += 1
        marker = line.strip()

        if state["current"] == State.AFTER_SEPARATOR:
            if marker.startswith(":start_line:") and not line.strip().startswith(r"\:start_line:"):
                return report_line_marker_in_replace_error(":start_line:")
            if marker.startswith(":end_line:") and not line.strip().startswith(r"\:end_line:"):
                return report_line_marker_in_replace_error(":end_line:")

        if state["current"] == State.START:
            if marker == SEP:
                return (
                    report_invalid_diff_error(SEP, "SEARCH")
                    if likely_bad_structure
                    else report_merge_conflict_error(SEP, "SEARCH")
                )
            if marker == REPLACE:
                return report_invalid_diff_error(REPLACE, "SEARCH")
            if marker.startswith(REPLACE_PREFIX):
                return report_merge_conflict_error(marker, "SEARCH")
            if re.match(SEARCH_PATTERN, marker):
                state["current"] = State.AFTER_SEARCH
            elif marker.startswith(SEARCH_PREFIX):
                return report_merge_conflict_error(marker, "SEARCH")

        elif state["current"] == State.AFTER_SEARCH:
            if re.match(SEARCH_PATTERN, marker):
                return report_invalid_diff_error("SEARCH", SEP)
            if marker.startswith(SEARCH_PREFIX):
                return report_merge_conflict_error(marker, "SEARCH")
            if marker == REPLACE:
                return report_invalid_diff_error(REPLACE, SEP)
            if marker.startswith(REPLACE_PREFIX):
                return report_merge_conflict_error(marker, "SEARCH")
            if marker == SEP:
                state["current"] = State.AFTER_SEPARATOR

        elif state["current"] == State.AFTER_SEPARATOR:
            if re.match(SEARCH_PATTERN, marker):
                return report_invalid_diff_error("SEARCH", REPLACE)
            if marker.startswith(SEARCH_PREFIX):
                return report_merge_conflict_error(marker, REPLACE)
            if marker == SEP:
                return (
                    report_invalid_diff_error(SEP, REPLACE)
                    if likely_bad_structure
                    else report_merge_conflict_error(SEP, REPLACE)
                )
            if marker == REPLACE:
                state["current"] = State.START
            elif marker.startswith(REPLACE_PREFIX):
                return report_merge_conflict_error(marker, REPLACE)

    if state["current"] == State.START:
        return {"success": True}
    expected = "=======" if state["current"] == State.AFTER_SEARCH else ">>>>>>> REPLACE"
    return {
        "success": False,
        "error": f"ERROR: Unexpected end of sequence: Expected '{expected}' was not found.",
    }


# ---------------------------------------------------------------------------
# Fuzzy search (from RooCode)
# ---------------------------------------------------------------------------
def _find_best_substring_match(line: str, search_str: str) -> tuple[float, str]:
    """Find the best matching substring in a line."""
    best_score = 0.0
    best_content = ""
    search_len = len(search_str)
    line_len = len(line)
    if search_len >= line_len:
        return get_similarity(line, search_str), line

    positions_to_check = [0, line_len - search_len]
    if line_len > search_len * 3:
        positions_to_check.append(line_len // 2 - search_len // 2)

    for i in positions_to_check:
        if 0 <= i <= line_len - search_len:
            substring = line[i : i + search_len]
            score = get_similarity(substring, search_str)
            if score > best_score:
                best_score = score
                best_content = substring

    whole_line_score = get_similarity(line, search_str)
    if whole_line_score > best_score:
        best_score = whole_line_score
        best_content = line

    return best_score, best_content


def fuzzy_search(
    lines: List[str], search_chunk: str, start_index: int, end_index: int
) -> Dict[str, Any]:
    """Middle‑out search for the best matching slice."""
    best_score = 0.0
    best_match_index = -1
    best_match_content = ""
    search_lines = search_chunk.split("\n")
    search_len = len(search_lines)
    mid_point = (start_index + end_index) // 2
    left_index = mid_point
    right_index = mid_point + 1
    is_single_line = search_len == 1
    search_str = search_lines[0] if is_single_line else ""

    while left_index >= start_index or right_index <= end_index - search_len:
        if left_index >= start_index:
            if is_single_line:
                line = lines[left_index]
                if search_str in line:
                    best_score = 1.0
                    best_match_index = left_index
                    best_match_content = line
                    left_index -= 1
                    continue
                line_score, line_content = _find_best_substring_match(line, search_str)
                if line_score > best_score:
                    best_score = line_score
                    best_match_index = left_index
                    best_match_content = line_content
            else:
                original_chunk = "\n".join(lines[left_index : left_index + search_len])
                similarity = get_similarity(original_chunk, search_chunk)
                if similarity > best_score:
                    best_score = similarity
                    best_match_index = left_index
                    best_match_content = original_chunk
            left_index -= 1

        if right_index <= end_index - search_len:
            if is_single_line:
                line = lines[right_index]
                if search_str in line:
                    best_score = 1.0
                    best_match_index = right_index
                    best_match_content = line
                    right_index += 1
                    continue
                line_score, line_content = _find_best_substring_match(line, search_str)
                if line_score > best_score:
                    best_score = line_score
                    best_match_index = right_index
                    best_match_content = line_content
            else:
                original_chunk = "\n".join(lines[right_index : right_index + search_len])
                similarity = get_similarity(original_chunk, search_chunk)
                if similarity > best_score:
                    best_score = similarity
                    best_match_index = right_index
                    best_match_content = original_chunk
            right_index += 1

    return {
        "bestScore": best_score,
        "bestMatchIndex": best_match_index,
        "bestMatchContent": best_match_content,
    }


# ---------------------------------------------------------------------------
# Multi‑Search‑Replace Strategy (from RooCode)
# ---------------------------------------------------------------------------
@dataclass
class DiffResult:
    success: bool
    content: Optional[str] = None
    error: Optional[str] = None
    fail_parts: Optional[List[Dict]] = None


class MultiSearchReplaceDiffStrategy:
    """Apply a multi‑block SEARCH/REPLACE diff with fuzzy matching."""

    def __init__(self, fuzzy_threshold: float = 1.0, buffer_lines: int = 40):
        self.fuzzy_threshold = fuzzy_threshold
        self.buffer_lines = buffer_lines

    def apply_diff(
        self,
        original_content: str,
        diff_content: str,
        _param_start_line: Optional[int] = None,
        _param_end_line: Optional[int] = None,
    ) -> DiffResult:
        # Validate markers
        valid_seq = validate_marker_sequencing(diff_content)
        if not valid_seq["success"]:
            return DiffResult(success=False, error=valid_seq["error"])

        matches = self._parse_diff_blocks(diff_content)
        if not matches:
            return DiffResult(success=True, content=original_content)

        # Simple exact replacement pass (substring)
        result_content = original_content
        all_applied = True
        processed_matches = []
        for match in matches:
            search_content = unescape_markers(match.get("searchContent", ""))
            replace_content = unescape_markers(match.get("replaceContent", ""))
            if search_content == replace_content:
                continue

            has_line_numbers = (
                every_line_has_line_numbers(search_content)
                and every_line_has_line_numbers(replace_content)
            ) or (every_line_has_line_numbers(search_content) and replace_content.strip() == "")

            if has_line_numbers:
                search_content = strip_line_numbers(search_content)
                replace_content = strip_line_numbers(replace_content)

            if not search_content:
                all_applied = False
                break

            if search_content not in result_content:
                all_applied = False
                break
            processed_matches.append((search_content, replace_content))

        if all_applied and processed_matches:
            for s, r in processed_matches:
                result_content = result_content.replace(s, r)
            return DiffResult(success=True, content=result_content)

        # Fallback: line‑based middle‑out fuzzy search
        line_ending = "\r\n" if "\r\n" in original_content else "\n"
        result_lines = re.split(r"\r?\n", original_content)
        diff_results = []
        applied_count = 0

        replacements = [
            {
                "startLine": int(m.get("startLine", 0)),
                "searchContent": m.get("searchContent", ""),
                "replaceContent": m.get("replaceContent", ""),
            }
            for m in matches
        ]
        replacements.sort(key=lambda x: x["startLine"])

        for replacement in replacements:
            search_content = replacement["searchContent"]
            replace_content = replacement["replaceContent"]
            start_line = replacement["startLine"]

            search_content = unescape_markers(search_content)
            replace_content = unescape_markers(replace_content)

            has_all_line_numbers = (
                every_line_has_line_numbers(search_content)
                and every_line_has_line_numbers(replace_content)
            ) or (every_line_has_line_numbers(search_content) and replace_content.strip() == "")

            if has_all_line_numbers and start_line == 0:
                first_line = search_content.split("\n")[0]
                if "|" in first_line:
                    start_line = int(first_line.split("|")[0].strip())

            if has_all_line_numbers:
                search_content = strip_line_numbers(search_content)
                replace_content = strip_line_numbers(replace_content)

            if search_content == replace_content:
                diff_results.append(
                    {
                        "success": True,
                        "message": "Search and replace content are identical - no changes needed",
                    }
                )
                continue

            search_lines = [] if search_content == "" else search_content.split("\n")
            replace_lines = [] if replace_content == "" else replace_content.split("\n")

            if len(search_lines) == 0:
                diff_results.append(
                    {
                        "success": False,
                        "error": (
                            "Empty search content is not allowed\n\n"
                            "Debug Info:\n"
                            "- Search content cannot be empty\n"
                            "- For insertions, provide a specific line using :start_line: "
                            "and include content to search for\n"
                            "- For example, match a single line to insert before/after it"
                        ),
                    }
                )
                continue

            end_line = replacement["startLine"] + len(search_lines) - 1
            match_index = -1
            best_match_score = 0.0
            best_match_content = ""
            search_chunk = "\n".join(search_lines)

            search_start_index = 0
            search_end_index = len(result_lines)

            if start_line:
                exact_start_index = start_line - 1
                search_len = len(search_lines)
                exact_end_index = exact_start_index + search_len - 1
                if exact_start_index < len(result_lines) and exact_end_index < len(result_lines):
                    original_chunk = "\n".join(result_lines[exact_start_index : exact_end_index + 1])
                    similarity = get_similarity(original_chunk, search_chunk)
                    if similarity >= self.fuzzy_threshold:
                        match_index = exact_start_index
                        best_match_score = similarity
                        best_match_content = original_chunk
                    else:
                        search_start_index = max(0, start_line - (self.buffer_lines + 1))
                        search_end_index = min(
                            len(result_lines),
                            start_line + len(search_lines) + self.buffer_lines,
                        )
                else:
                    search_start_index = max(0, start_line - (self.buffer_lines + 1))
                    search_end_index = min(
                        len(result_lines),
                        start_line + len(search_lines) + self.buffer_lines,
                    )

            if match_index == -1:
                fuzzy_result = fuzzy_search(
                    result_lines, search_chunk, search_start_index, search_end_index
                )
                match_index = fuzzy_result["bestMatchIndex"]
                best_match_score = fuzzy_result["bestScore"]
                best_match_content = fuzzy_result["bestMatchContent"]

            # Aggressive line‑number stripping fallback
            if match_index == -1 or best_match_score < self.fuzzy_threshold:
                aggressive_search_content = strip_line_numbers(search_content, aggressive=True)
                aggressive_replace_content = strip_line_numbers(replace_content, aggressive=True)
                aggressive_search_lines = [] if aggressive_search_content == "" else aggressive_search_content.split("\n")
                aggressive_search_chunk = "\n".join(aggressive_search_lines)
                fuzzy_result = fuzzy_search(
                    result_lines, aggressive_search_chunk, search_start_index, search_end_index
                )
                if (
                    fuzzy_result["bestMatchIndex"] != -1
                    and fuzzy_result["bestScore"] >= self.fuzzy_threshold
                ):
                    match_index = fuzzy_result["bestMatchIndex"]
                    best_match_score = fuzzy_result["bestScore"]
                    best_match_content = fuzzy_result["bestMatchContent"]
                    search_content = aggressive_search_content
                    replace_content = aggressive_replace_content
                    search_lines = aggressive_search_lines
                    replace_lines = [] if replace_content == "" else replace_content.split("\n")
                else:
                    if start_line and end_line:
                        original_section = "\n\nOriginal Content:\n" + add_line_numbers(
                            "\n".join(
                                result_lines[
                                    max(0, start_line - 1 - self.buffer_lines) : min(
                                        len(result_lines), end_line + self.buffer_lines
                                    )
                                ]
                            ),
                            max(1, start_line - self.buffer_lines),
                        )
                    else:
                        original_section = "\n\nOriginal Content:\n" + add_line_numbers(
                            "\n".join(result_lines)
                        )

                    best_match_section = (
                        "\n\nBest Match Found:\n"
                        + add_line_numbers(best_match_content, match_index + 1)
                        if best_match_content
                        else "\n\nBest Match Found:\n(no match)"
                    )

                    line_range = f" at line: {start_line}" if start_line else ""

                    diff_results.append(
                        {
                            "success": False,
                            "error": (
                                f"No sufficiently similar match found{line_range} "
                                f"({int(best_match_score * 100)}% similar, "
                                f"needs {int(self.fuzzy_threshold * 100)}%)\n\n"
                                "Debug Info:\n"
                                f"- Similarity Score: {int(best_match_score * 100)}%\n"
                                f"- Required Threshold: {int(self.fuzzy_threshold * 100)}%\n"
                                f"- Search Range: {f'starting at line {start_line}' if start_line else 'start to end'}\n"
                                "- Tried both standard and aggressive line number stripping\n"
                                "- Tip: Use read_file tool to get the latest content of the file before "
                                "attempting to use apply_diff tool again, as file content may have changed\n\n"
                                f"Search Content:\n{search_chunk}"
                                f"{best_match_section}"
                                f"{original_section}"
                            ),
                        }
                    )
                    continue

            # Indentation preservation
            matched_lines = result_lines[match_index : match_index + len(search_lines)]
            original_indents = []
            for line in matched_lines:
                m = re.match(r"^[\t ]*", line)
                original_indents.append(m.group(0) if m else "")
            search_indents = []
            for line in search_lines:
                m = re.match(r"^[\t ]*", line)
                search_indents.append(m.group(0) if m else "")
            indented_replace_lines = []
            for i, line in enumerate(replace_lines):
                matched_indent = original_indents[i] if i < len(original_indents) else (original_indents[0] if original_indents else "")
                search_indent = search_indents[i] if i < len(search_indents) else (search_indents[0] if search_indents else "")
                current_replace_match = re.match(r"^[\t ]*", line)
                current_replace_indent = current_replace_match.group(0) if current_replace_match else ""
                relative_level = len(current_replace_indent) - len(search_indent)
                if relative_level >= 0:
                    final_indent = matched_indent + current_replace_indent[len(search_indent):]
                else:
                    final_indent = matched_indent[: max(0, len(matched_indent) + relative_level)]
                if line.strip() == "":
                    indented_replace_lines.append(matched_indent)
                else:
                    line_content = line.lstrip(" \t")
                    indented_replace_lines.append(final_indent + line_content)

            before_match = result_lines[:match_index]
            after_match = result_lines[match_index + len(search_lines) :]
            result_lines = before_match + indented_replace_lines + after_match
            applied_count += 1

        final_content = line_ending.join(result_lines)

        all_successful = all(result.get("success", False) for result in diff_results)
        has_failures = any(not result.get("success", False) for result in diff_results)

        if applied_count == 0 and has_failures:
            return DiffResult(success=False, fail_parts=diff_results)
        if applied_count == 0 and all_successful:
            return DiffResult(success=True, content=original_content, fail_parts=diff_results)
        return DiffResult(
            success=True,
            content=final_content,
            fail_parts=diff_results if diff_results else None,
        )

    def _parse_diff_blocks(self, diff_content: str) -> List[Dict[str, Any]]:
        """Parse individual SEARCH/REPLACE blocks."""
        matches = []
        blocks = diff_content.split("<<<<<<< SEARCH")
        for block in blocks[1:]:
            if "=======" not in block or ">>>>>>> REPLACE" not in block:
                continue
            sep_parts = block.split("=======")
            if len(sep_parts) < 2:
                continue
            before_sep = sep_parts[0]
            after_sep = sep_parts[1]
            dash_parts = before_sep.split("-------")
            if len(dash_parts) >= 2:
                header = dash_parts[0]
                search_content = dash_parts[1].lstrip("\n").rstrip("\n")
            else:
                header = ""
                search_content = before_sep.lstrip("\n").rstrip("\n")
                lines = search_content.split("\n")
                if lines and lines[0].startswith(":start_line:"):
                    header = lines[0]
                    search_content = "\n".join(lines[1:])
            replace_content = after_sep.split(">>>>>>> REPLACE")[0].lstrip("\n").rstrip("\n")
            start_line = 0
            for line in header.split("\n"):
                if line.startswith(":start_line:"):
                    try:
                        start_line = int(line.split(":")[1].strip())
                    except:
                        pass
            matches.append(
                {
                    "startLine": start_line,
                    "searchContent": search_content,
                    "replaceContent": replace_content,
                }
            )
        return matches


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(
        description="Apply a SEARCH/REPLACE patch to a file (RooCode/OpenViking style).",
        epilog="Examples:\n  %(prog)s -f changes.patch file.py\n  %(prog)s -s 'old' -r 'new' -L 10 file.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("target", help="Target file to patch (overwritten in place unless -o is given)")
    parser.add_argument(
        "-f",
        "--file",
        dest="patch_file",
        default=None,
        metavar="FILE",
        help="Patch file (use '-' for stdin)",
    )
    parser.add_argument(
        "-s", "--search", dest="search", default=None, metavar="STR", help="Search string (requires -r)"
    )
    parser.add_argument(
        "-r", "--replace", dest="replace", default=None, metavar="STR", help="Replace string (required with -s)"
    )
    parser.add_argument(
        "-L",
        "--start-line",
        dest="start_line",
        type=int,
        default=None,
        metavar="N",
        help="Start line hint (default 1 when -s is used)",
    )
    parser.add_argument(
        "-o",
        "--output",
        dest="output",
        default=None,
        metavar="PATH",
        help="Write patched content to PATH (use '-' for stdout) instead of modifying target",
    )
    parser.add_argument(
        "-l",
        "--buffer-lines",
        dest="buffer_lines",
        type=int,
        default=40,
        metavar="N",
        help="Extra context lines for fuzzy search (default 40)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        dest="verbose",
        action="count",
        default=0,
        help="Increase log verbosity (-v INFO, -vv DEBUG)",
    )
    parser.add_argument(
        "-t",
        "--fuzzy-threshold",
        dest="fuzzy_threshold",
        type=float,
        default=1.0,
        metavar="F",
        help="Fuzzy match threshold 0.0–1.0 (default 1.0 = exact)",
    )

    args = parser.parse_args(argv)

    # ------------------------------------------------------------------ logging
    if args.verbose == 1:
        logger.setLevel(logging.INFO)
    elif args.verbose >= 2:
        logger.setLevel(logging.DEBUG)
    logger.debug("Parsed arguments: %s", args)

    # ------------------------------------------------------- argument validation
    # -f and -s are mutually exclusive
    if args.patch_file is not None and args.search is not None:
        parser.error("-f/--file and -s/--search are mutually exclusive")
    if args.search is not None:
        if args.replace is None:
            parser.error("-r/--replace is required when -s/--search is used")
        if args.start_line is None:
            args.start_line = 0
    else:
        if args.replace is not None:
            parser.error("-r/--replace can only be used together with -s/--search")
        if args.start_line is not None:
            parser.error("-L/--start-line can only be used together with -s/--search")
    if args.patch_file is None and args.search is None:
        parser.error("either -f/--file or -s/--search must be provided")

    if not 0.0 <= args.fuzzy_threshold <= 1.0:
        parser.error("Fuzzy threshold must be between 0.0 and 1.0")
    if args.buffer_lines < 0:
        parser.error("Buffer lines must be non-negative")

    # ----------------------------------------------------------- read target file
    try:
        with open(args.target, "r", encoding="utf-8") as f:
            original_content = f.read()
    except Exception as e:
        logger.error("Cannot read target file '%s': %s", args.target, e)
        sys.exit(1)

    # --------------------------------------------------- obtain patch content
    if args.patch_file is not None:
        if args.patch_file == "-":
            diff_content = sys.stdin.read()
        else:
            try:
                with open(args.patch_file, "r", encoding="utf-8") as f:
                    diff_content = f.read()
            except Exception as e:
                logger.error("Cannot read patch file '%s': %s", args.patch_file, e)
                sys.exit(1)
    else:
        # Build a single SEARCH/REPLACE block from -s/-r/-L
        start_line = args.start_line
        diff_content = (
            "<<<<<<< SEARCH\n"
            f":start_line:{start_line}\n"
            "-------\n"
            f"{args.search}\n"
            "=======\n"
            f"{args.replace}\n"
            ">>>>>>> REPLACE\n"
        )
        logger.debug("Constructed diff content:\n%s", diff_content)

    # ------------------------------------------------------ apply patch
    strategy = MultiSearchReplaceDiffStrategy(
        fuzzy_threshold=args.fuzzy_threshold, buffer_lines=args.buffer_lines
    )
    result = strategy.apply_diff(original_content, diff_content)

    if result.success:
        if args.output is not None:
            # Write to the specified output path or stdout
            if args.output == "-":
                sys.stdout.write(result.content)
            else:
                try:
                    with open(args.output, "w", encoding="utf-8") as f:
                        f.write(result.content)
                except Exception as e:
                    logger.error("Failed to write patched content to '%s': %s", args.output, e)
                    sys.exit(1)
                logger.info("Patch applied successfully, output written to '%s'", args.output)
        else:
            # Write back to the target file (in-place)
            try:
                with open(args.target, "w", encoding="utf-8") as f:
                    f.write(result.content)
            except Exception as e:
                logger.error("Failed to write patched content to '%s': %s", args.target, e)
                sys.exit(1)
            logger.info("Patch applied successfully to '%s'", args.target)
    else:
        # Print diagnostics to stderr
        if result.error:
            print(result.error, file=sys.stderr)
        if result.fail_parts:
            for part in result.fail_parts:
                if "error" in part:
                    print(part["error"], file=sys.stderr)
                elif "message" in part:
                    print(part["message"], file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
