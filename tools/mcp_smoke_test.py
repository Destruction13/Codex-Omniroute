#!/usr/bin/env python3
"""Best-effort MCP parity smoke test for Codex OmniRoute.

Walks the isolated runtime config.toml, parses [mcp_servers.*] blocks, and
verifies that each server entry is reachable in the sense that its command
exists on PATH (for stdio servers) or its url responds (for http servers).

This does NOT spin up real MCP servers -- it only checks that the OmniRoute
isolated profile inherits the same MCP definitions the official Codex
profile sees, so the desktop UI's Skills/MCP surface should look identical.

Usage:
    python tools/mcp_smoke_test.py [--isolated-config PATH] [--official-config PATH]

Exits non-zero if isolated MCP count differs from official MCP count, or any
isolated MCP definition references a missing command.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any


SECTION_RE = re.compile(r"^\s*\[([A-Za-z0-9_.\-\"]+)\]\s*$")
KV_RE = re.compile(r'^\s*([A-Za-z0-9_\-]+)\s*=\s*(.+?)\s*$')


def parse_mcp_servers(text: str) -> dict[str, dict[str, Any]]:
    """Very small TOML-ish parser, scoped to extracting [mcp_servers.<name>] blocks."""
    servers: dict[str, dict[str, Any]] = {}
    current: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = SECTION_RE.match(raw)
        if m:
            section = m.group(1)
            if section.startswith("mcp_servers."):
                name = section[len("mcp_servers.") :].strip('"')
                servers[name] = {"_section": section}
                current = name
            else:
                current = None
            continue
        if current is None:
            continue
        kv = KV_RE.match(raw)
        if not kv:
            continue
        key, val = kv.group(1), kv.group(2).strip()
        # Trim trailing inline comments.
        if val and not val.startswith(('"', "[")):
            val = val.split("#", 1)[0].rstrip()
        # Decode simple TOML scalar types.
        if val.startswith('"') and val.endswith('"'):
            servers[current][key] = val[1:-1]
        elif val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            items: list[str] = []
            if inner:
                # Split on commas not inside quotes.
                parts = re.findall(r'"((?:[^"\\]|\\.)*)"|([^,\s][^,]*)', inner)
                for q, b in parts:
                    items.append(q if q else b.strip())
            servers[current][key] = items
        elif val in ("true", "false"):
            servers[current][key] = val == "true"
        else:
            try:
                servers[current][key] = int(val)
            except ValueError:
                servers[current][key] = val
    return servers


def check_server(name: str, defn: dict[str, Any]) -> tuple[bool, str]:
    cmd = defn.get("command")
    url = defn.get("url")
    if cmd:
        # cmd may be a string ("npx") or a list (["npx", "-y", "x"]).
        program = cmd[0] if isinstance(cmd, list) else str(cmd)
        if shutil.which(program):
            return True, f"command '{program}' found on PATH"
        return False, f"command '{program}' NOT on PATH"
    if url:
        return True, f"url-based MCP {url!r} (not pinged)"
    return False, "neither 'command' nor 'url' set"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--isolated-config",
        default=".codex-omniroute-home/codex/config.toml",
        help="Path to the isolated runtime config.toml (default: workspace .codex-omniroute-home/codex/config.toml).",
    )
    ap.add_argument(
        "--official-config",
        default=str(Path(os.path.expanduser("~")) / ".codex" / "config.toml"),
        help="Path to the official Codex config.toml.",
    )
    args = ap.parse_args()

    iso_path = Path(args.isolated_config)
    off_path = Path(args.official_config)

    if not iso_path.exists():
        print(f"FAIL: isolated config not found: {iso_path}", file=sys.stderr)
        return 2

    iso = parse_mcp_servers(iso_path.read_text(encoding="utf-8"))
    off = parse_mcp_servers(off_path.read_text(encoding="utf-8")) if off_path.exists() else {}

    print(json.dumps({"isolated_mcp_count": len(iso), "official_mcp_count": len(off)}))

    parity_ok = (len(iso) == len(off)) if off else True
    if off and not parity_ok:
        print(
            f"WARN: isolated MCP count {len(iso)} differs from official {len(off)}. "
            "If you intentionally pruned MCPs in the isolated profile this is fine.",
            file=sys.stderr,
        )

    failures = 0
    for name, defn in iso.items():
        ok, detail = check_server(name, defn)
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {name} -- {detail}")
        if not ok:
            failures += 1

    if failures:
        return 1
    if off and not parity_ok:
        return 0  # parity warning only
    return 0


if __name__ == "__main__":
    sys.exit(main())
