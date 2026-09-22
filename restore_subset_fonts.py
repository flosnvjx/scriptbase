#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
restore_all_fonts.py
批量还原 ASS/SSA 中的
  - Style 字体名
  - Dialogue 行内 {\fnXXX} / {\fn@XXX} 字体名
并删除 ; Font Subset 注释行

Usage:
    python restore_all_fonts.py <dir_or_file> [<dir_or_file> ...] [--no-backup]
"""

import argparse
import re
from pathlib import Path

SUBSET_RE   = re.compile(r'^; Font Subset:\s*([A-Z0-9]+)\s*-\s*(.+)$', re.I)
STYLE_RE    = re.compile(r'^(Style:\s*)(.+)$', re.I)
DIALOGUE_RE = re.compile(r'^(Dialogue:\s*)(.+)$', re.I)
FN_TAG_RE   = re.compile(r'(\\fn@?)([A-Z0-9]+)(?=[\\}])', re.I)  # 支持 @ 前缀


def build_map_and_filter(lines):
    """返回 (mapping, 删除 Subset 行后的新行列表)"""
    mapping = {}
    new_lines = []
    for ln in lines:
        m = SUBSET_RE.match(ln)
        if m:
            sid, font = m.groups()
            mapping[sid.strip()] = font.strip()
        else:
            new_lines.append(ln)
    return mapping, new_lines


def replace_fn_tags(text, mapping):
    """替换 {\fn[@]子集ID} -> {\fn真实名}"""
    def _repl(m):
        prefix, sid = m.groups()
        return prefix + mapping.get(sid, sid)
    return FN_TAG_RE.sub(_repl, text)


def process_file(path, backup=True):
    with open(path, encoding='utf-8-sig') as f:
        lines = f.readlines()

    mapping, new_lines = build_map_and_filter(lines)
    if not mapping:
        print(f'[SKIP] 无映射: {path}')
        return False

    changed = False
    final_lines = []
    inside_styles = False

    for ln in new_lines:
        raw = ln.rstrip('\n')

        # 区块标记
        if raw.strip().lower().startswith('[v4+ styles]'):
            inside_styles = True
        elif raw.startswith('[') and inside_styles:
            inside_styles = False

        # 1) Style 行
        if inside_styles:
            m = STYLE_RE.match(raw)
            if m:
                prefix, fields_str = m.groups()
                fields = [f.strip() for f in fields_str.split(',', maxsplit=23)]
                if len(fields) >= 2 and fields[1] in mapping:
                    fields[1] = mapping[fields[1]]
                    raw = prefix + ','.join(fields)
                    changed = True

        # 2) Dialogue 行内 {\fn...}
        m = DIALOGUE_RE.match(raw)
        if m:
            prefix, rest = m.groups()
            new_rest = replace_fn_tags(rest, mapping)
            if new_rest != rest:
                raw = prefix + new_rest
                changed = True

        final_lines.append(raw + '\n')

    if not changed:
        print(f'[SKIP] 无改动: {path}')
        return False

    # 写回
    if backup:
        bak = path.with_suffix(path.suffix + '.bak')
        path.rename(bak)

    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.writelines(final_lines)
    print(f'[OK] 已处理: {path}')
    return True


def collect_files(targets):
    """收集所有需要处理的 .ass/.ssa 文件，支持目录递归和直接文件。"""
    files = []
    seen = set()

    for target in targets:
        p = Path(target)

        if p.is_dir():
            candidates = [
                x for x in p.rglob('*')
                if x.is_file() and x.suffix.lower() in ('.ass', '.ssa')
            ]
        elif p.is_file():
            if p.suffix.lower() in ('.ass', '.ssa'):
                candidates = [p]
            else:
                print(f'[SKIP] 非 ASS/SSA 文件: {p}')
                continue
        else:
            print(f'[SKIP] 路径不存在: {p}')
            continue

        for fp in candidates:
            try:
                key = fp.resolve()
            except OSError:
                key = fp

            if key in seen:
                continue
            seen.add(key)
            files.append(fp)

    files.sort(key=lambda x: str(x).lower())
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        'targets',
        nargs='+',
        help='目标目录或 ASS/SSA 文件（可多个，目录会递归）'
    )
    parser.add_argument('--no-backup', action='store_true', help='不生成 .bak')
    args = parser.parse_args()

    files = collect_files(args.targets)
    if not files:
        print('未找到 .ass/.ssa 文件')
        return

    for fp in files:
        process_file(fp, backup=not args.no_backup)


if __name__ == '__main__':
    main()
