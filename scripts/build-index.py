#!/usr/bin/env python3
"""build-index.py — regenerate index.json from providers/*/provider.lua.

Zero dependencies (Python 3 stdlib only). Scans every providers/<id>/provider.lua,
parses the `-- @key value` metadata header, hashes the script + icon, and emits a
stable, sorted index.json that the Kumo app + server consume for sha-verified
auto-update.

Output is byte-stable across runs so CI's `git diff --exit-code index.json` only
trips on real changes: per-provider created/updated come from git history
(deterministic once committed), falling back to now only for never-committed
working files. There is no volatile top-level timestamp.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROVIDERS_DIR = os.path.join(ROOT, "providers")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_meta(src: str) -> dict:
    """Parse the leading `-- @key value` comment header. Stops at the first line
    that is not a comment (blank comment lines `--` are skipped, not terminal)."""
    meta = {}
    for raw in src.splitlines():
        line = raw.strip()
        if line == "":
            continue
        if not line.startswith("--"):
            break  # first non-comment line ends the header
        m = re.match(r"^--\s*@(\w+)\s*(.*)$", line)
        if m:
            meta[m.group(1).lower()] = m.group(2).strip()
    return meta


def git_dates(path: str):
    """git log dates for a path: (firstISO, lastISO). (None, None) outside git."""
    def run(args):
        try:
            out = subprocess.run(
                ["git"] + args + ["--", path],
                cwd=ROOT, capture_output=True, text=True, check=True,
            ).stdout.strip()
            return out
        except Exception:
            return ""
    created_lines = run(["log", "--follow", "--diff-filter=A", "--format=%aI"])
    created = [x for x in created_lines.splitlines() if x]
    created = created[-1] if created else None
    updated = run(["log", "-1", "--format=%aI"]) or None
    return created, updated


def split_langs(v):
    if not v:
        return []
    return [s.strip() for s in v.split(",") if s.strip()]


def to_bool(v) -> bool:
    return str(v).strip().lower() == "true"


def icon_for(dirpath):
    for name in ("icon.avif", "icon.png", "icon.webp", "icon.jpg"):
        if os.path.exists(os.path.join(dirpath, name)):
            return name
    return None


def main() -> int:
    now_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    entries = []

    dirs = sorted(
        d for d in os.listdir(PROVIDERS_DIR)
        if os.path.isdir(os.path.join(PROVIDERS_DIR, d))
    )

    for dir_name in dirs:
        dirpath = os.path.join(PROVIDERS_DIR, dir_name)
        lua_path = os.path.join(dirpath, "provider.lua")
        if not os.path.exists(lua_path):
            print(f"skip {dir_name}: no provider.lua", file=sys.stderr)
            continue

        with open(lua_path, "rb") as f:
            src = f.read()
        meta = parse_meta(src.decode("utf-8"))
        pid = meta.get("id") or dir_name
        if meta.get("id") and meta["id"] != dir_name:
            raise SystemExit(
                f'provider dir "{dir_name}" mismatches @id "{meta["id"]}" '
                f"— dir name MUST equal @id"
            )

        lua_rel = os.path.relpath(lua_path, ROOT).replace("\\", "/")
        created, updated = git_dates(lua_rel)
        if not created:
            created = now_iso
        if not updated:
            updated = now_iso

        icon_name = icon_for(dirpath)
        icon_rel = None
        icon_sha = None
        if icon_name:
            icon_path = os.path.join(dirpath, icon_name)
            icon_rel = os.path.relpath(icon_path, ROOT).replace("\\", "/")
            with open(icon_path, "rb") as f:
                icon_sha = sha256(f.read())

        # Key order mirrors the published index.json exactly.
        entries.append({
            "id": pid,
            "name": meta.get("name") or pid,
            "version": meta.get("version") or "0.0.0",
            "langs": split_langs(meta.get("langs")),
            "nsfw": to_bool(meta.get("nsfw")),
            "requires_verification": "verify" in meta,
            "created": created,
            "updated": updated,
            "url": lua_rel,
            "sha256": sha256(src),
            "icon": icon_rel,
            "icon_sha256": icon_sha,
            "ua_hint": meta.get("ua") or None,
        })

    entries.sort(key=lambda e: e["id"])
    index = {"schema": 1, "providers": entries}

    out = os.path.join(ROOT, "index.json")
    # Match JS JSON.stringify(index, null, 2) + "\n": 2-space indent, ": "/","
    # separators, non-ASCII preserved, no trailing whitespace.
    text = json.dumps(index, indent=2, ensure_ascii=False, separators=(",", ": "))
    with open(out, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(f"wrote {os.path.relpath(out, ROOT)} — {len(entries)} provider(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
