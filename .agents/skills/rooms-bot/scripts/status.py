#!/usr/bin/env python3
"""Print harness health: bridge/wake pids, pending count, inbox freshness."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from lib import find_bridge_pid, load_json_list, require_bridge_dir, require_nick, room_name


def main() -> None:
    bridge = require_bridge_dir()
    nick = require_nick()
    room = room_name()
    bridge_pid = find_bridge_pid(str(bridge))
    wake_pid = None
    try:
        wake_pid = int((bridge / "wake.pid").read_text(encoding="utf-8").strip())
        os.kill(wake_pid, 0)
    except Exception:
        wake_pid = None

    pending = load_json_list(bridge / "pending.json")
    inbox = bridge / "inbox.jsonl"
    inbox_bytes = inbox.stat().st_size if inbox.exists() else 0
    inbox_age = None
    if inbox.exists():
        inbox_age = round(time.time() - inbox.stat().st_mtime, 1)

    locator = None
    try:
        state = json.loads((bridge / "state.json").read_text(encoding="utf-8"))
        if isinstance(state, dict):
            locator = state.get("locator")
    except Exception:
        pass
    if not locator:
        locator = (os.environ.get("ROOMS_LOCATOR") or "").strip() or None

    body = {
        "ok": bridge_pid is not None,
        "locator": locator,
        "nick": nick,
        "room": room,
        "bridge_dir": str(bridge),
        "bridge_pid": bridge_pid,
        "wake_pid": wake_pid,
        "pending": len(pending),
        "inbox_bytes": inbox_bytes,
        "inbox_age_s": inbox_age,
        "replied": len(load_json_list(bridge / "replied.json")),
    }
    print(json.dumps(body, indent=2))
    sys.exit(0 if body["ok"] else 1)


if __name__ == "__main__":
    main()
