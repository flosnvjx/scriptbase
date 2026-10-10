#!/usr/bin/env python3
"""
AniLiberty CLI — search anime series and list torrents with magnet links.

Modes:
  search  — find releases by query
  list    — list torrents for a release (by id or alias)

API: https://aniliberty.top/api/v1  (OpenAPI 3.0, verified)
"""

import argparse
import json
import logging
import sys
import textwrap
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE_URL = "https://aniliberty.top"
API_PREFIX = "/api/v1"

_RETRY = Retry(
    total=3,
    backoff_factor=0.5,
    status_forcelist=[500, 502, 503, 504],
    allowed_methods=["GET"],
)
_LOG = logging.getLogger("aniliberty")


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

class ApiClient:
    def __init__(self, base_url: str = BASE_URL, timeout: int = 20):
        self.base_url = base_url.rstrip("/") + API_PREFIX
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update(
            {"Accept": "application/json", "User-Agent": "aniliberty-cli/2.0"}
        )
        adapter = HTTPAdapter(max_retries=_RETRY)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)

    def _get(self, path: str, params: Optional[Dict[str, Any]] = None) -> Any:
        url = self.base_url + path
        _LOG.debug("GET %s params=%s", url, params)
        resp = self.session.get(url, params=params, timeout=self.timeout)
        resp.raise_for_status()
        return resp.json()

    # -- endpoints -----------------------------------------------------------

    def search_releases(self, query: str) -> List[Dict]:
        """GET /app/search/releases?query=... → bare array of releases."""
        payload = self._get("/app/search/releases", params={"query": query})
        if isinstance(payload, dict) and "data" in payload:
            payload = payload["data"]
        return payload if isinstance(payload, list) else []

    def get_release(self, id_or_alias: str) -> Dict:
        """GET /anime/releases/{idOrAlias} → release object."""
        payload = self._get(f"/anime/releases/{id_or_alias}")
        if isinstance(payload, dict) and "data" in payload:
            payload = payload["data"]
        return payload if isinstance(payload, dict) else {}

    def get_release_torrents(self, release_id: int) -> List[Dict]:
        """
        GET /anime/torrents/release/{id} → bare array of full torrent objects.

        NOTE: Do NOT pass `include=torrent_members`. The API's `include`
        parameter replaces the default field set rather than augmenting it,
        which strips `magnet`, `seeders`, `size`, etc. The default response
        already contains `torrent_members` and every other field we need.
        """
        payload = self._get(f"/anime/torrents/release/{release_id}")
        # Defensive: some Laravel endpoints wrap the array in {"data": [...]}
        if isinstance(payload, dict) and "data" in payload:
            payload = payload["data"]
        return payload if isinstance(payload, list) else []


# ---------------------------------------------------------------------------
# Data models — mirror the OpenAPI schemas
# ---------------------------------------------------------------------------

@dataclass
class Series:
    id: int
    alias: str
    name_main: str
    name_english: str
    name_alternative: str
    year: int
    type: str
    episodes_total: int
    description: str
    is_ongoing: bool
    age_rating: str = ""

    @classmethod
    def from_api(cls, raw: Dict) -> "Series":
        name = raw.get("name") or {}
        type_obj = raw.get("type") or {}
        age_obj = raw.get("age_rating") or {}
        return cls(
            id=raw.get("id", 0) or 0,
            alias=raw.get("alias", "") or "",
            name_main=name.get("main", "") or "",
            name_english=name.get("english", "") or "",
            name_alternative=name.get("alternative", "") or "",
            year=raw.get("year", 0) or 0,
            type=type_obj.get("description", type_obj.get("value", "")) or "",
            episodes_total=raw.get("episodes_total", 0) or 0,
            description=raw.get("description", "") or "",
            is_ongoing=bool(raw.get("is_ongoing")),
            age_rating=age_obj.get("label", "") or "",
        )


@dataclass
class Torrent:
    id: int
    hash: str
    magnet: str
    size_bytes: int
    quality: str
    codec: str
    color: str
    source_type: str
    label: str
    seeders: int
    leechers: int
    created_at: str
    updated_at: str
    filename: str
    releasers: List[str] = field(default_factory=list)
    is_hardsub: bool = False
    completed_times: int = 0

    @classmethod
    def from_api(cls, raw: Dict) -> "Torrent":
        def _label(obj: Any) -> str:
            if isinstance(obj, dict):
                return obj.get("description") or obj.get("value") or ""
            return str(obj or "")

        members = raw.get("torrent_members") or []
        releasers = [
            m.get("nickname", "")
            for m in members
            if isinstance(m, dict) and m.get("nickname")
        ]

        return cls(
            id=raw.get("id", 0) or 0,
            hash=raw.get("hash", "") or "",
            magnet=raw.get("magnet", "") or "",
            size_bytes=raw.get("size", 0) or 0,
            quality=_label(raw.get("quality")),
            codec=_label(raw.get("codec")),
            color=_label(raw.get("color")),
            source_type=_label(raw.get("type")),
            label=raw.get("label", "") or "",
            seeders=raw.get("seeders", 0) or 0,
            leechers=raw.get("leechers", 0) or 0,
            created_at=raw.get("created_at", "") or "",
            updated_at=raw.get("updated_at", "") or "",
            filename=raw.get("filename", "") or "",
            releasers=releasers,
            is_hardsub=bool(raw.get("is_hardsub")),
            completed_times=raw.get("completed_times", 0) or 0,
        )

    @property
    def releaser(self) -> str:
        return ", ".join(self.releasers) if self.releasers else "—"

    @property
    def display_size(self) -> str:
        return human_bytes(self.size_bytes)


def human_bytes(n: int) -> str:
    if not n:
        return "?"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    f = float(n)
    for u in units:
        if f < 1024:
            return f"{f:.2f} {u}"
        f /= 1024
    return f"{f:.2f} EB"


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_series_table(rows: List[Series]) -> None:
    if not rows:
        print("No results.")
        return
    cw_id = max(6, max(len(str(r.id)) for r in rows))
    cw_alias = max(20, min(45, max(len(r.alias) for r in rows)))
    cw_year = 4
    cw_type = max(4, max(len(r.type) for r in rows))
    print(
        f"{'ID':<{cw_id}}  {'Alias':<{cw_alias}}  "
        f"{'Year':>{cw_year}}  {'Type':<{cw_type}}  Title"
    )
    print("-" * (cw_id + cw_alias + cw_year + cw_type + 40))
    for r in rows:
        title = r.name_main or r.name_english or r.name_alternative
        print(
            f"{r.id:<{cw_id}}  {r.alias[:cw_alias]:<{cw_alias}}  "
            f"{r.year:>{cw_year}}  {r.type:<{cw_type}}  {title}"
        )


def print_torrents_table(torrents: List[Torrent], series: Optional[Series] = None) -> None:
    if series:
        print(f"\n{series.name_main} ({series.year}) — alias: {series.alias}")
        if series.description:
            print(textwrap.fill(series.description, width=90))
        print()
    if not torrents:
        print("No torrents.")
        return

    print(f"Total torrents: {len(torrents)}\n")
    for i, t in enumerate(torrents, 1):
        print(f"─── [{i}] {t.label or t.filename or '(no label)'} ───")
        print(f"    Quality   : {t.quality or '—'}")
        print(f"    Codec     : {t.codec or '—'}   Color: {t.color or '—'}")
        print(f"    Type      : {t.source_type or '—'}")
        print(f"    Size      : {t.display_size}  ({t.size_bytes} bytes)")
        print(f"    Seeders   : {t.seeders}")
        print(f"    Leechers  : {t.leechers}")
        print(f"    Completed : {t.completed_times}")
        print(f"    Releaser  : {t.releaser}")
        print(f"    Created   : {t.created_at or '—'}")
        print(f"    Updated   : {t.updated_at or '—'}")
        print(f"    Hardsub   : {'yes' if t.is_hardsub else 'no'}")
        link_id = series.id if series else "?"
        print(f"    Link      : https://aniliberty.top/anime/releases/{link_id}")
        print(f"    Magnet    : {t.magnet or '—'}")
        print()


def print_json(obj: Any) -> None:
    print(json.dumps(obj, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_search(client: ApiClient, args: argparse.Namespace) -> int:
    try:
        raw = client.search_releases(args.query)
    except requests.HTTPError as e:
        print(f"API error: {e}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"Network error: {e}", file=sys.stderr)
        return 1

    series_list = [Series.from_api(r) for r in raw][: args.limit]

    if args.json:
        print_json(
            [
                {
                    "id": s.id,
                    "alias": s.alias,
                    "name_main": s.name_main,
                    "name_english": s.name_english,
                    "year": s.year,
                    "type": s.type,
                    "episodes_total": s.episodes_total,
                }
                for s in series_list
            ]
        )
    else:
        print_series_table(series_list)
    return 0


def cmd_list(client: ApiClient, args: argparse.Namespace) -> int:
    # 1. Resolve release by id or alias
    try:
        raw_release = client.get_release(args.id_or_alias)
    except requests.HTTPError as e:
        if e.response is not None and e.response.status_code == 404:
            print(f"Release '{args.id_or_alias}' not found.", file=sys.stderr)
        else:
            print(f"API error: {e}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"Network error: {e}", file=sys.stderr)
        return 1

    series = Series.from_api(raw_release)
    if not series.id:
        print(f"Release '{args.id_or_alias}' has no id in response.", file=sys.stderr)
        return 1

    # 2. Fetch torrents for the release
    try:
        raw_torrents = client.get_release_torrents(series.id)
    except requests.HTTPError as e:
        print(f"API error fetching torrents: {e}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"Network error: {e}", file=sys.stderr)
        return 1

    torrents = [Torrent.from_api(t) for t in raw_torrents]

    # 3. Filters
    if args.quality:
        needle = args.quality.lower()
        torrents = [t for t in torrents if needle in t.quality.lower()]
    if args.codec:
        needle = args.codec.lower()
        torrents = [t for t in torrents if needle in t.codec.lower()]
    if args.type:
        needle = args.type.lower()
        torrents = [t for t in torrents if needle in t.source_type.lower()]
    if args.min_seeders is not None:
        torrents = [t for t in torrents if t.seeders >= args.min_seeders]

    # 4. Sort
    if args.sort == "seeders":
        torrents.sort(key=lambda t: t.seeders, reverse=True)
    elif args.sort == "date":
        torrents.sort(key=lambda t: t.created_at, reverse=True)
    elif args.sort == "updated":
        torrents.sort(key=lambda t: t.updated_at, reverse=True)
    elif args.sort == "size":
        torrents.sort(key=lambda t: t.size_bytes, reverse=True)

    # 5. Output
    if args.json:
        print_json(
            {
                "series": {
                    "id": series.id,
                    "alias": series.alias,
                    "name_main": series.name_main,
                    "name_english": series.name_english,
                    "year": series.year,
                    "episodes_total": series.episodes_total,
                },
                "torrents": [
                    {
                        "id": t.id,
                        "hash": t.hash,
                        "magnet": t.magnet,
                        "label": t.label,
                        "filename": t.filename,
                        "releasers": t.releasers,
                        "created_at": t.created_at,
                        "updated_at": t.updated_at,
                        "quality": t.quality,
                        "codec": t.codec,
                        "color": t.color,
                        "type": t.source_type,
                        "size_bytes": t.size_bytes,
                        "size_human": t.display_size,
                        "seeders": t.seeders,
                        "leechers": t.leechers,
                        "completed_times": t.completed_times,
                        "is_hardsub": t.is_hardsub,
                    }
                    for t in torrents
                ],
            }
        )
    else:
        print_torrents_table(torrents, series)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="aniliberty",
        description="Search AniLiberty releases and list torrents with magnet links.",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--base-url", default=BASE_URL)
    p.add_argument("--timeout", type=int, default=20)

    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("search", help="search releases by query")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_search)

    l = sub.add_parser("list", help="list torrents for a release (id or alias)")
    l.add_argument("id_or_alias")
    l.add_argument("--quality", help="filter by quality substring (e.g. 1080p)")
    l.add_argument("--codec", help="filter by codec substring (e.g. HEVC, AV1)")
    l.add_argument("--type", help="filter by source type (e.g. WEBRip, BDRip)")
    l.add_argument("--min-seeders", type=int, default=None)
    l.add_argument(
        "--sort",
        choices=["none", "seeders", "date", "updated", "size"],
        default="none",
    )
    l.add_argument("--json", action="store_true")
    l.set_defaults(func=cmd_list)

    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    client = ApiClient(base_url=args.base_url, timeout=args.timeout)
    try:
        return args.func(client, args)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
