#!/usr/bin/env python3
"""Inspect the active lock without editing files or starting authentication."""

import json
import os
from pathlib import Path
import subprocess
import sys

EXPLORER = "io.github.sirjul1337.lock-explorer"


def query(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=8)
        return json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def active_locks(rows):
    if not isinstance(rows, list):
        return []
    return [row for row in rows if isinstance(row, dict) and row.get("enabled") is True
            and (row.get("id") in ("omarchy.lock", EXPLORER) or row.get("clonedFrom") == "omarchy.lock")]


def integration(rows):
    locks = active_locks(rows)
    if len(locks) != 1:
        return "unknown"
    return "legacy" if locks[0].get("id") in ("omarchy.lock", EXPLORER) else "custom"


def runtime_health(payload):
    if not isinstance(payload, dict):
        return "unknown"
    face, password = payload.get("howdy"), payload.get("passwordPam")
    if not isinstance(face, bool) or not isinstance(password, bool):
        return "unknown"
    return "ok" if face and password else "broken"


def legacy_health(rows, pam=None, stock=None, home=None):
    """Compatibility for the two lock implementations the patchers support."""
    if integration(rows) != "legacy":
        return "unknown"
    home = Path(home) if home is not None else Path.home()
    pam = Path(pam) if pam is not None else Path("/etc/pam.d/omarchy-lock-howdy")
    if active_locks(rows)[0]["id"] == EXPLORER:
        qml = home / ".config/omarchy/plugins" / EXPLORER / "Service.qml"
    elif stock is not None:
        qml = Path(stock)
    else:
        qml = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell/plugins/lock/Service.qml"
        if not qml.is_file():
            qml = Path("/usr/share/omarchy/shell/plugins/lock/Service.qml")
    try:
        return "ok" if pam.is_file() and "omarchy-lock-howdy" in qml.read_text() else "broken"
    except OSError:
        return "unknown"


def health():
    result = runtime_health(query(["omarchy-shell", "lock", "status"]))
    if result != "unknown":
        return result
    rows = query(["omarchy", "plugin", "list", "--json"])
    return legacy_health(rows) if integration(rows) == "legacy" else "unknown"


def main():
    if sys.argv[1:] == ["health"]:
        print(health())
    elif sys.argv[1:] == ["integration"]:
        print(integration(query(["omarchy", "plugin", "list", "--json"])))
    else:
        print("Usage: howdy-lock-state.py <health|integration>", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
