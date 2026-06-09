"""A rooms chat client, written on pancake actors in native Python.

It joins the room, waits until it is full (learning the head count from the
room's own join announcements), posts one line, and collects every member's line
as the room pushes it back. All the OCapN machinery lives in ``room_client.py``
(:class:`Room`), so this reads like a chat client and nothing else — driven by
``async for msg in room``.

    python3 client.py 127.0.0.1 9099 alice "hi" 3

The last argument is how many members to expect; the client posts only once that
many have joined, so an all-to-all broadcast is deterministic no matter the order
members connect in. It exits 0 once it has seen a line from every member.

This is the same application as the Deno, Racket, Rust, and Zig clients, on one
OCapN wire — the room cannot tell which language a member is written in.
"""

from __future__ import annotations

import asyncio
import re
import sys

from room_client import Room  # the pancake-backed Room client, next to this file


def _room_size(message) -> "int | None":
    """Both the room's announcements carry the head count: a join says
    ``(<count> here)`` and the welcome says ``<count> in the room``. Pull it out
    of either so a client knows the room is full and can post."""
    if not message.system:
        return None
    m = re.search(r"\((\d+) here\)", message.text) or re.search(r"(\d+) in the room", message.text)
    return int(m.group(1)) if m else None


async def run_client(host: str, port: int, nick: str, line: str, expect: int) -> None:
    room = await Room.join(host, port, nick)
    present = 0
    posted = False
    chat_lines = 0
    try:
        async for message in room:
            print(f"[{nick}] {message.sender}: {message.text}", flush=True)
            if message.system:
                # A room announcement (welcome or a join) — never a chat line.
                size = _room_size(message)
                if size is not None:
                    present = max(present, size)
            else:
                chat_lines += 1
            # Post once the room is full, so every member is on the roster.
            if not posted and present >= expect:
                await room.say(line)
                posted = True
            if chat_lines >= expect:
                break
    finally:
        await room.leave()
    if chat_lines < expect:
        raise RuntimeError(f"{nick} saw {chat_lines}/{expect} chat lines before the room ended")


def main() -> int:
    if len(sys.argv) < 5:
        print("usage: client.py <host> <port> <nick> <line> [expectMembers]", file=sys.stderr)
        return 2
    host, port, nick, line = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    expect = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    try:
        asyncio.run(asyncio.wait_for(run_client(host, port, nick, line, expect), timeout=15))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"client {nick} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
