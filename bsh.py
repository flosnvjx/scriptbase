#!/usr/bin/env python3
import argparse
import re
import json
import urllib.request

API_BASE = "https://api.github.com"
SPDX_MAP = {
    "MIT": "MIT",
    "Apache-2.0": "Apache-2.0",
    "GPL-2.0": "GPLv2",
    "GPL-3.0": "GPLv3",
    "LGPL-2.1": "LGPLv2.1",
    "LGPL-3.0": "LGPLv3",
    "BSD-2-Clause": "BSD",
    "BSD-3-Clause": "BSD-3",
    "Unlicense": "Unlicense",
    "0BSD": "0BSD",
}

# Raw string templates (no jinja2)
TPL_CARGO = """TERMUX_PKG_NAME="{pkg_name}"
TERMUX_PKG_VERSION="{pkg_version}"
TERMUX_PKG_SRCURL="{src_url}"
TERMUX_PKG_DESCRIPTION="{description}"
TERMUX_PKG_HOMEPAGE="{homepage}"
TERMUX_PKG_LICENSE="{license}"
{license_file_line}
TERMUX_PKG_BUILD_DEPENDS="rust"

termux_step_pre_configure() {{
	termux_setup_rust
}}

termux_step_make() {{
	cargo build --jobs $TERMUX_PKG_MAKE_PROCESSES --target $CARGO_TARGET_NAME --release{cargo_locked_flag}
}}

termux_step_make_install() {{
	install -Dm700 target/$CARGO_TARGET_NAME/release/{cargo_bin} "$TERMUX_PREFIX/bin/{cargo_bin}"
}}"""

TPL_CMAKE = """TERMUX_PKG_NAME="{pkg_name}"
TERMUX_PKG_VERSION="{pkg_version}"
TERMUX_PKG_SRCURL="{src_url}"
TERMUX_PKG_DESCRIPTION="{description}"
TERMUX_PKG_HOMEPAGE="{homepage}"
TERMUX_PKG_LICENSE="{license}"
{license_file_line}
TERMUX_PKG_BUILD_DEPENDS="cmake"

termux_step_pre_configure() {{
	termux_setup_cmake
}}

termux_step_configure() {{
	cmake -B build -DCMAKE_INSTALL_PREFIX="$TERMUX_PREFIX"
}}

termux_step_make() {{
	make -C build -j$TERMUX_PKG_MAKE_PROCESSES
}}

termux_step_make_install() {{
	make -C build install
}}"""

TPL_AUTOTOOLS = """TERMUX_PKG_NAME="{pkg_name}"
TERMUX_PKG_VERSION="{pkg_version}"
TERMUX_PKG_SRCURL="{src_url}"
TERMUX_PKG_DESCRIPTION="{description}"
TERMUX_PKG_HOMEPAGE="{homepage}"
TERMUX_PKG_LICENSE="{license}"
{license_file_line}

termux_step_configure() {{
	./configure --prefix="$TERMUX_PREFIX"
}}

termux_step_make() {{
	make -j$TERMUX_PKG_MAKE_PROCESSES
}}

termux_step_make_install() {{
	make install
}}"""

TPL_GOLANG = """TERMUX_PKG_NAME="{pkg_name}"
TERMUX_PKG_VERSION="{pkg_version}"
TERMUX_PKG_SRCURL="{src_url}"
TERMUX_PKG_DESCRIPTION="{description}"
TERMUX_PKG_HOMEPAGE="{homepage}"
TERMUX_PKG_LICENSE="{license}"
{license_file_line}
TERMUX_PKG_BUILD_DEPENDS="golang"

termux_step_pre_configure() {{
	termux_setup_golang
}}

termux_step_make() {{
	go build
}}

termux_step_make_install() {{
	install -Dm700 {pkg_name} "$TERMUX_PREFIX/bin/"
}}"""

TPL_MESON = """TERMUX_PKG_NAME="{pkg_name}"
TERMUX_PKG_VERSION="{pkg_version}"
TERMUX_PKG_SRCURL="{src_url}"
TERMUX_PKG_DESCRIPTION="{description}"
TERMUX_PKG_HOMEPAGE="{homepage}"
TERMUX_PKG_LICENSE="{license}"
{license_file_line}
TERMUX_PKG_BUILD_DEPENDS="meson ninja"

termux_step_pre_configure() {{
	termux_setup_meson
}}

termux_step_configure() {{
	meson setup build
}}

termux_step_make() {{
	ninja -C build
}}

termux_step_make_install() {{
	ninja -C build install
}}"""

def http_get(url: str) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "termux-pkg-gen/1.0",
            "Accept": "application/vnd.github.v3+json"
        }
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8")

def get_repo_meta(owner: str, repo: str) -> dict:
    return json.loads(http_get(f"{API_BASE}/repos/{owner}/{repo}"))

def get_root_files(owner: str, repo: str, branch: str) -> list[str]:
    data = json.loads(http_get(f"{API_BASE}/repos/{owner}/{repo}/git/trees/{branch}?recursive=0"))
    return [item["path"] for item in data.get("tree", [])]

def get_latest_release(owner: str, repo: str) -> dict | None:
    """Fetch latest release info. Returns None if no releases exist."""
    try:
        return json.loads(http_get(f"{API_BASE}/repos/{owner}/{repo}/releases/latest"))
    except Exception:
        return None

def get_raw_file(owner: str, repo: str, path: str, branch: str) -> str | None:
    try:
        return http_get(f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}")
    except Exception:
        return None

def sanitize_pkg_name(s: str) -> str:
    return re.sub(r"[^a-z0-9_-]", "", s.lower())

def strip_v_version(s: str) -> str:
    return s.lstrip("vV")

def parse_github_input(raw: str) -> tuple[str, str]:
    raw = raw.rstrip("/").rstrip(".git")
    if raw.startswith("https://github.com/"):
        return raw.replace("https://github.com/", "").split("/")[:2]
    return raw.split("/")

def normalize_license(spdx_id: str | None) -> str:
    if not spdx_id:
        return "unknown"
    return SPDX_MAP.get(spdx_id, spdx_id)

def detect_build_system(files: list[str]) -> str:
    if "Cargo.toml" in files:
        return "cargo"
    if "go.mod" in files:
        return "golang"
    if "CMakeLists.txt" in files:
        return "cmake"
    if "meson.build" in files:
        return "meson"
    if "configure.ac" in files or "autogen.sh" in files:
        return "autotools"
    return "make"

def has_cargo_lock(files: list[str]) -> bool:
    return "Cargo.lock" in files

def parse_cargo_name(txt: str) -> str | None:
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith("name") and "=" in line:
            return line.split("=", 1)[1].strip().strip("'\"")
    return None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", help="github url or owner/repo")
    parser.add_argument("--tag")
    parser.add_argument("--branch")
    parser.add_argument("--out", default="build.sh")
    args = parser.parse_args()

    owner, repo = parse_github_input(args.repo)
    meta = get_repo_meta(owner, repo)

    pkg_name = sanitize_pkg_name(repo)
    homepage = meta["html_url"]
    description = meta["description"] or ""
    def_branch = meta["default_branch"]

    if args.tag:
        pkg_ver = strip_v_version(args.tag)
        src_url = f"https://github.com/{owner}/{repo}/archive/refs/tags/{args.tag}.tar.gz"
    else:
        latest_release = get_latest_release(owner, repo)
        if latest_release:
            latest_tag = latest_release["tag_name"]
            pkg_ver = strip_v_version(latest_tag)
            src_url = f"https://github.com/{owner}/{repo}/archive/refs/tags/{latest_tag}.tar.gz"
        else:
            pkg_ver = def_branch
            src_url = f"https://github.com/{owner}/{repo}/archive/{def_branch}.tar.gz"

    lic_spdx = meta.get("license", {}).get("spdx_id")
    lic_file = meta.get("license", {}).get("name", "")
    termux_lic = normalize_license(lic_spdx)
    license_file_line = f'TERMUX_PKG_LICENSE_FILE="{lic_file}"' if lic_file else ""

    root_files = get_root_files(owner, repo, def_branch)
    bs = detect_build_system(root_files)
    cargo_lock = has_cargo_lock(root_files)
    cargo_bin = pkg_name
    cargo_locked_flag = " --locked" if cargo_lock else ""

    if bs == "cargo":
        toml_txt = get_raw_file(owner, repo, "Cargo.toml", def_branch)
        if toml_txt:
            bn = parse_cargo_name(toml_txt)
            if bn:
                cargo_bin = bn

    tpl_map = {
        "cargo": TPL_CARGO,
        "cmake": TPL_CMAKE,
        "autotools": TPL_AUTOTOOLS,
        "golang": TPL_GOLANG,
        "meson": TPL_MESON,
        "make": TPL_AUTOTOOLS
    }
    template = tpl_map[bs]

    out_content = template.format(
        pkg_name=pkg_name,
        pkg_version=pkg_ver,
        src_url=src_url,
        description=description,
        homepage=homepage,
        license=termux_lic,
        license_file_line=license_file_line,
        cargo_bin=cargo_bin,
        cargo_locked_flag=cargo_locked_flag
    )

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(out_content)

    print(f"Generated -> {args.out}")

if __name__ == "__main__":
    main()
