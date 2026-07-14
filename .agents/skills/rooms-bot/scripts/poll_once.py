#!/usr/bin/env python3
"""Print the unanswered inbound chat (room + DM) as JSON — a read-only mirror of
what the wake loop computes in-process, for inspecting "what would I answer now?"
while offline. Marking replied has exactly one door: mark_pending.py.

Env:
  BRIDGE_DIR / ROOMS_DIR
  NICK / ROOMS_NICK
  ROOM / ROOMS_ROOM        home channel (default general)

Flags:
  --room NAME              override ROOM
  --room-only              exclude DMs
"""
from __future__ import annotations

import argparse
import json

from lib import poll_pending, require_bridge_dir, require_nick, room_name


def main() -> None:
    p = argparse.ArgumentParser(description="rooms-bot pending poll (read-only)")
    p.add_argument("--room", default="")
    p.add_argument("--room-only", action="store_true", help="exclude DMs")
    args = p.parse_args()

    items = poll_pending(
        require_bridge_dir(), require_nick(), room_name(args.room), include_dm=not args.room_only
    )
    print(json.dumps(items, indent=2))


if __name__ == "__main__":
    main()
