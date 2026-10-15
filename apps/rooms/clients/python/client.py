"""A rooms chat client, written on glowcap actors in Python.

It enters the named room, waits until everyone it expects is present, posts one
line, and collects each expected member's line as the room pushes it back. All
the OCapN machinery lives in ``room_client.py`` (:class:`Room`), so this reads
like a chat client and nothing else, driven by ``async for msg in room``.

    python3 client.py 127.0.0.1:9099 general alice "hi" alice,bob,carol

The locator is transport-neutral: a ``host:port`` reaches a TCP room, an
``ocapn://<nodeid>.iroh?direct-addresses=…`` URI reaches an iroh room. The
second argument is the room name (entering one that does not exist opens it). The
last argument is the roster: a comma-separated list of the member nicks to
expect (default: just you). The client posts only once every roster member is
present, it learns who is present from the structured presence the room attaches
to each membership line (the roster on arrival and each join), and exits 0 once
it has seen a line from every roster member. Members outside the roster (people
already chatting in an attached room, say) are printed but never counted, so a
busy room cannot fake or break the assertion.

This is the same application as the Deno, Racket, Rust, and Zig clients, on one
OCapN wire, the room cannot tell which language a member is written in.
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

from room_client import Directory, Room, RoomInfo  # the glowcap-backed clients, next to this file
from _protocol_gen import ARRIVE, DEPART, SESSION_DEADLINE_MS  # the generated wire grammar, next to this file

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "_demo"))
from rooms_cli import enter_or_open  # noqa: E402

# The whole-roster deadline every sibling client holds, in seconds.
SESSION_DEADLINE_S = SESSION_DEADLINE_MS / 1000


def _fmt_rooms(rooms: "list[RoomInfo]") -> str:
    """Render the live room list for one line of output."""
    return ", ".join(f"{room.name} ({room.count if room.count is not None else 'unknown'})" for room in rooms) if rooms else "(none yet)"


async def run_client(locator: str, room_name: str, nick: str, line: str, roster: list[str]) -> None:
    directory = await Directory.connect(locator)
    # Discovery: show the rooms that already have people in them, then follow the
    # live list, both the snapshot (`list`) and the change feed (`watch`).
    live = await directory.list()
    more = "" if live.next is None else " and more"
    print(f"[{nick}] rooms: {_fmt_rooms(live.rooms)}{more}", flush=True)
    await directory.watch(
        lambda kind, room: print(
            f"[{nick}] directory: {kind} {room.name} ({room.count if room.count is not None else 'unknown'})",
            flush=True,
        )
    )
    room_ref = await enter_or_open(directory, room_name)
    room = await Room.subscribe(directory.session, room_ref, nick)
    want = set(roster)
    present: set[str] = set()
    seen: set[str] = set()
    posted = False
    try:
        async for message in room:
            print(f"[{nick}] {message.sender}: {message.text}", flush=True)
            if message.presence is not None:
                # Membership arrives as structure. Only an arrival or a departure
                # moves a member in or out; the other tails are facts about a
                # member who is still here.
                if message.presence.effect == DEPART:
                    present.difference_update(message.presence.names)
                elif message.presence.effect == ARRIVE:
                    present.update(message.presence.names)
            elif not message.system:
                present.add(message.sender)  # a line is presence too
                if message.sender in want:
                    seen.add(message.sender)
            # Post once every roster member is present, so each one receives it.
            if not posted and want <= present:
                await room.say(line)
                posted = True
            if want <= seen:
                break
    finally:
        await room.leave()
        await directory.close()
    if not want <= seen:
        missing = ", ".join(sorted(want - seen))
        raise RuntimeError(f"{nick} saw lines from {len(seen)}/{len(want)} members before the room ended (missing: {missing})")


def main() -> int:
    if len(sys.argv) < 5:
        print("usage: client.py <locator> <room> <nick> <line> [roster]   (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)", file=sys.stderr)
        return 2
    locator, room_name, nick, line = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    roster = sys.argv[5].split(",") if len(sys.argv) > 5 else [nick]
    try:
        asyncio.run(asyncio.wait_for(run_client(locator, room_name, nick, line, roster), timeout=SESSION_DEADLINE_S))
        return 0
    except asyncio.TimeoutError:
        # str(TimeoutError()) is empty; name the failure so it is never blank.
        print(f"client {nick} failed: timed out after {SESSION_DEADLINE_S:g}s", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"client {nick} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
