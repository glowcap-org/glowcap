"""A small, friendly client for the rooms chat, built on pancake actors.

On the new connection API this is barely a layer: connect, fetch the room by
name, spawn an inbox the room can call back, subscribe by handing it that
capability, and surface the room's callbacks as a stream. Everything above it
reads like an app.

    room = await Room.join("127.0.0.1", 9099, "alice")
    await room.say("hello")
    async for msg in room:
        print(msg.sender, msg.text)
    await room.leave()
"""

from __future__ import annotations

import asyncio
import pathlib
import sys
from dataclasses import dataclass
from typing import Optional

# The idiomatic binding lives in bindings/python; add it to the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[4] / "bindings" / "python"))

from pancake import Connection, connect  # noqa: E402

ROOM = "room"
SUBSCRIBE, POST, NOTIFY = "subscribe", "post", "notify"


@dataclass
class Message:
    """One line in the room. ``system`` is true for the room's own announcements
    (a member joining, your welcome); otherwise ``sender`` is who said it."""

    sender: str
    text: str
    system: bool


class Room:
    """A membership in a chat room. Get one with :meth:`join`, iterate it for the
    lines the room sends, :meth:`say` to talk, and :meth:`leave` when done."""

    def __init__(self, conn: Connection, room) -> None:
        self._conn = conn
        self._room = room
        self._lines: asyncio.Queue = asyncio.Queue()
        self._leaving = False

    @classmethod
    async def join(cls, host: str, port: int, nick: str) -> "Room":
        conn = await connect(host, port)
        conn.serve()  # start the inbound loop before fetching
        room = await conn.fetch(ROOM)
        self = cls(conn, room)

        # The room calls this back with every line; surface it on the stream.
        inbox = conn.spawn(self._inbox)

        # End the stream when the connection closes.
        asyncio.ensure_future(self._until_closed())

        # Subscribe, handing the room a capability to our inbox. The welcome it
        # returns is our first line.
        welcome = await conn.send(room, SUBSCRIBE, [nick, inbox])
        self._emit("room", welcome if isinstance(welcome, str) else "joined")
        return self

    async def say(self, text: str) -> None:
        """Say a line to everyone in the room."""
        await self._conn.send(self._room, POST, [text])

    async def leave(self) -> None:
        """Leave the room and release the connection."""
        self._leaving = True
        await self._conn.close()

    def __aiter__(self):
        """The lines the room sends, in order, until you leave or it hangs up:
        ``async for msg in room``."""
        return self._messages()

    async def _messages(self):
        while True:
            message = await self._lines.get()
            if message is None:  # sentinel: the stream has ended
                return
            yield message

    def _inbox(self, verb: str, args: list):
        if verb != NOTIFY:
            raise ValueError(f"inbox has no method {verb!r}")
        sender = args[0] if args and isinstance(args[0], str) else "?"
        text = args[1] if len(args) > 1 and isinstance(args[1], str) else ""
        self._emit(sender, text)
        return None

    def _emit(self, sender: str, text: str) -> None:
        self._lines.put_nowait(Message(sender, text, sender == "room"))

    async def _until_closed(self) -> None:
        try:
            await self._conn.serve()
            if not self._leaving:
                print("rooms: the room closed the connection", file=sys.stderr)
        except Exception as err:  # noqa: BLE001
            if not self._leaving:
                print(f"rooms: lost the connection — {err}", file=sys.stderr)
        finally:
            self._lines.put_nowait(None)  # end the messages stream
