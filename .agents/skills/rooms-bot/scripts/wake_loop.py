#!/usr/bin/env python3
"""Responsive wake loop for a rooms-bot CapTP harness.

Run this as a monitored background shell and wake the agent on its output:
``notify_on_output`` matching ``^AGENT_LOOP_TICK_rooms_<nick>`` (the WAKE_TOKEN).
Each line the loop prints is one wake with a JSON payload the agent acts on.

Required env: NICK, BRIDGE_DIR
Optional: ROOM / ROOMS_ROOM, WAKE_TOKEN, POLL_SEC (default 1, capped at 2)

Contract:
  - Recompute pending at least every POLL_SEC seconds (never more than 2s).
  - Also wake as soon as inbox.jsonl grows (a new CapTP line landed).
  - Emit at most one tick per distinct pending id-set (until mark_pending).
  - Empty pending → silence. No busywork.
  - Peer down → one card; keep probing on the same interval.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

from lib import (
    atomic_write_json,
    atomic_write_text,
    env,
    find_bridge_pid,
    pending_fingerprint,
    poll_pending,
    require_bridge_dir,
    require_nick,
    room_name,
    wake_token,
)

NICK = require_nick()
BRIDGE = require_bridge_dir()
BRIDGE_DIR = str(BRIDGE)
ROOM = room_name()
WAKE_TOKEN = env("WAKE_TOKEN") or wake_token(NICK)
# Responsive default; hard-cap so a mis-set env cannot go sluggish.
POLL_SEC = min(2.0, max(0.1, float(env("POLL_SEC") or "1")))
SCRIPT_DIR = Path(__file__).resolve().parent
INBOX = BRIDGE / "inbox.jsonl"

os.chdir(BRIDGE)
atomic_write_text(BRIDGE / "wake.pid", f"{os.getpid()}\n")


def emit_card(card: str, n: int) -> None:
    if card == "peer-down":
        prompt = (
            f"{NICK}: CapTP peer down under {BRIDGE_DIR}. "
            f"Restart peer.py for this nick only, then keep chatting."
        )
    else:
        prompt = (
            f"{NICK}: {n} unanswered message(s) in {BRIDGE_DIR}/pending.json. "
            f"Reply to each in its channel (room → reply.py --text; dm → "
            f"reply.py --dm <peer> --text), then mark_pending.py. "
            f"Own {BRIDGE_DIR} only."
        )
    body = {
        "method": "rooms.wake",
        "card": card,
        "nick": NICK,
        "room": ROOM,
        "n": n,
        "dir": BRIDGE_DIR,
        "prompt": prompt,
        "scripts": str(SCRIPT_DIR),
    }
    print(f"{WAKE_TOKEN} {json.dumps(body, ensure_ascii=False)}", flush=True)


def refresh_pending() -> tuple[int, str]:
    """Recompute pending in-process and write pending.json for the agent."""
    items = poll_pending(BRIDGE, NICK, ROOM)
    atomic_write_json(BRIDGE / "pending.json", items)
    return pending_fingerprint(items)


def inbox_size() -> int:
    try:
        return INBOX.stat().st_size
    except OSError:
        return 0


def wait_for_activity(timeout: float, last_size: int) -> int:
    """Sleep up to timeout, returning early when inbox.jsonl grows."""
    deadline = time.monotonic() + timeout
    while True:
        size = inbox_size()
        if size != last_size:
            return size
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return size
        time.sleep(min(0.05, remaining))


def main() -> None:
    last_fp = ""
    down_announced = False
    last_inbox = inbox_size()
    while True:
        if find_bridge_pid(BRIDGE_DIR) is None:
            if not down_announced:
                down_announced = True
                emit_card("peer-down", 0)
            last_inbox = wait_for_activity(POLL_SEC, last_inbox)
            continue
        down_announced = False

        n, fp = refresh_pending()
        if n == 0:
            last_fp = ""
        elif fp != last_fp:
            last_fp = fp
            emit_card("pending", n)

        last_inbox = wait_for_activity(POLL_SEC, inbox_size())


if __name__ == "__main__":
    main()
