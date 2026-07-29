#!/usr/bin/env python3
"""
从 yuc.wiki MHTML 归档中提取 2025Q4 新番数据，支持 EXCLBGM 环境变量过滤。
用法: python extract.py < page.mhtml
"""

import sys
import io
import os
import re
import email
from email import policy
from bs4 import BeautifulSoup

# 强制 stdout/stderr 使用 UTF-8，避免汉字乱码
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")


def extract_html_bytes_from_mhtml(raw_bytes: bytes) -> bytes:
    """从 MIME 字节串中提取 text/html 部分的原始字节（不解码）。"""
    msg = email.message_from_bytes(raw_bytes, policy=policy.default)
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                payload = part.get_payload(decode=True)
                if payload:
                    return payload
    else:
        if msg.get_content_type() == "text/html":
            payload = msg.get_payload(decode=True)
            if payload:
                return payload
    raise ValueError("MHTML 中未找到 text/html 部分")


def parse_animation_studio(staff_elem) -> str | None:
    if not staff_elem:
        return None
    text = staff_elem.get_text(separator="\n")
    lines = text.splitlines()
    studios = []
    for i, line in enumerate(lines):
        if not line.startswith("动画制作："):
            continue
        first = line[5:].strip()
        if first:
            studios.append(first)
        j = i + 1
        while j < len(lines) and lines[j].startswith("\u3000" * 5):
            subsequent = lines[j][5:].strip()
            if subsequent:
                studios.append(subsequent)
            j += 1
        break
    return "、".join(studios) if studios else None


def main() -> None:
    raw = sys.stdin.buffer.read()
    html_bytes = extract_html_bytes_from_mhtml(raw)
    soup = BeautifulSoup(html_bytes, "lxml")

    table_selector = "article .post-body .table-container table"

    # 编译排除正则（若环境变量有效）
    excl_raw = os.environ.get("EXCLBGM", "").strip()
    excl_re = re.compile(excl_raw) if excl_raw else None

    total = 0
    pv_count = 0
    no_pv_count = 0
    skipped = 0

    for table in soup.select(table_selector):
        if not table.select_one(".title_main_r"):
            continue

        # 总番数包含跳过的条目
        total += 1

        # 如果设置了排除正则，提前收集关键字段用于匹配
        if excl_re:
            cn_elem = table.select_one('[class^="title_cn_r"]')
            jp_elem = table.select_one('[class^="title_jp_r"]')
            tag_elem = table.select_one(".type_tag_r")
            staff_elem = table.select_one('[class^="staff_r"]')

            cn_name = cn_elem.get_text(strip=True) if cn_elem else ""
            jp_name = jp_elem.get_text(strip=True) if jp_elem else ""
            tag_text = tag_elem.get_text(strip=True) if tag_elem else ""
            staff_text = staff_elem.get_text(" ", strip=True) if staff_elem else ""

            combined = f"{cn_name} {jp_name} {tag_text} {staff_text}"
            if excl_re.search(combined):
                skipped += 1
                continue

        # 注意：由于前面可能已经提取过这些元素，但为了清晰仍重新获取（可优化，但无妨）
        cn_elem = table.select_one('[class^="title_cn_r"]')
        jp_elem = table.select_one('[class^="title_jp_r"]')
        cn_name = cn_elem.get_text(strip=True) if cn_elem else None
        jp_name = jp_elem.get_text(strip=True)

        if not cn_name and jp_name:
            cn_name = jp_name
            jp_name = None

        tag_elem = table.select_one(".type_tag_r")
        tag_text = tag_elem.get_text(strip=True) if tag_elem else None

        broad_elem = table.select_one(".broadcast_r")
        broad_text = broad_elem.get_text(strip=True) if broad_elem else None

        staff_elem = table.select_one('[class^="staff_r"]')
        studio = parse_animation_studio(staff_elem)

        # ---------- 组装括号内文本 ----------
        parts = []
        if jp_name:
            parts.append(f"《{jp_name}》")
        if tag_text:
            parts.append(f"#{tag_text}")
        if broad_text:
            parts.append(broad_text)
        if studio:
            parts.append(studio)
        inner = " ".join(parts)

        # ---------- PV 链接（需校验格式）----------
        pv_url = None
        for a in table.find_all("a", href=True):
            if a.get_text(strip=True).startswith("PV"):
                href = a["href"].strip()
                if href.startswith("http://") or href.startswith("https://"):
                    pv_url = href
                break   # 只取第一个 PV 链接
        if pv_url:
            print(pv_url)
            pv_count += 1
            continue

        print(f"#{cn_name or ''}（{inner}）")

        no_pv_count += 1

    # 统计信息输出到 stderr
    print(
        f"统计：总番数 {total}，有 PV {pv_count}，无 PV {no_pv_count}，跳过 {skipped}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
