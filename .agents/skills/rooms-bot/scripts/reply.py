#!/usr/bin/env python3
"""Queue one outbound line for the peer to send — a room line or a DM.

Usage:
  reply.py --text '...'            # say it in your room
  reply.py --dm NICK --text '...'  # DM that member
  reply.py --dm NICK --stdin       # read the text from stdin

Env: BRIDGE_DIR / ROOMS_DIR
"""
from __future__ import annotations

import argparse
import sys

from lib import append_jsonl, require_bridge_dir


def main() -> None:
    p = argparse.ArgumentParser(description="rooms-bot outbox reply")
    p.add_argument("--text", default="")
    p.add_argument("--stdin", action="store_true")
    p.add_argument("--dm", default="", help="DM target nick; omit to say it in the room")
    args = p.parse_args()

    text = sys.stdin.read().strip() if args.stdin else args.text.strip()
    if not text:
        print("rooms-bot reply: empty text", file=sys.stderr)
        sys.exit(2)

    if args.dm:
        payload = {"text": text, "channel": "dm", "peer": args.dm}
    else:
        payload = {"text": text, "channel": "room"}

    append_jsonl(require_bridge_dir() / "outbox.jsonl", payload)
    print(payload)


if __name__ == "__main__":
    main()
