"""A small, friendly client for the rooms chat, built on pancake actors.

On the connection API this is barely a layer: connect, fetch the directory by
name, ask it to open or enter a room (which hands back a live reference to that
room), spawn an inbox the room can call back, subscribe by handing it that
capability, and surface the room's callbacks as a stream. Everything above it
reads like an app.

    directory = await Directory.connect("127.0.0.1:9099")
    room = await Room.subscribe(directory.conn, await directory.enter("general"), "alice")
    await room.say("hello")
    async for msg in room:
        print(msg.sender, msg.text)
    await room.leave()

:meth:`Directory.open` and :meth:`Directory.enter` mirror the wire one-to-one and
stay strict. The friendly "enter, opening it if new" behavior is a CLI
convenience and lives in ``client.py``, not here.
"""

from __future__ import annotations

import asyncio
import pathlib
import sys
from dataclasses import dataclass

# The idiomatic binding lives in bindings/python; add it to the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[4] / "bindings" / "python"))

from pancake import Connection, connect, tcp_locator  # noqa: E402
from pancake.iroh import Reachability  # noqa: E402

DIRECTORY = "directory"
OPEN, ENTER, LIST, WATCH = "open", "enter", "list", "watch"
SUBSCRIBE, POST, LEAVE, NOTIFY = "subscribe", "post", "leave", "notify"


def _rooms(raw) -> "list[tuple[str, int]]":
    """The wire shape of ``list``/``watch`` is a list of ``[name, count]`` pairs;
    lift it to ``(name, count)`` tuples."""
    out: list[tuple[str, int]] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, list) and len(item) >= 2:
                out.append((str(item[0]), int(item[1])))
    return out


async def _dial(locator: str) -> Connection:
    """Dial a transport-neutral rooms locator: an ``ocapn://`` URI goes over iroh,
    a bare ``host:port`` over TCP. The room's wire is identical either way; only
    how a member reaches it differs. The rooms URI carries direct-address hints,
    so the iroh dial uses the explicit ``Reachability.DIRECT`` posture."""
    if "://" in locator:
        return await connect(locator, Reachability.DIRECT)
    colon = locator.rfind(":")
    if colon < 0:
        raise ValueError(f"rooms locator is neither host:port nor an ocapn:// URI: {locator}")
    return await connect(tcp_locator(locator[:colon], int(locator[colon + 1:])))


class Directory:
    """The directory of rooms: the server's one published object. Connect to it,
    then :meth:`open` a new room or :meth:`enter` an existing one — each returns a
    reference to that room. Both mirror the wire: ``open`` raises if the name is
    taken, ``enter`` raises if there is no such room."""

    def __init__(self, conn: Connection, directory) -> None:
        self.conn = conn
        self._directory = directory

    @classmethod
    async def connect(cls, locator: str) -> "Directory":
        conn = await _dial(locator)
        conn.serve()  # start the inbound loop before fetching
        directory = await conn.fetch(DIRECTORY)
        return cls(conn, directory)

    async def open(self, name: str):
        """Create a new room and return a reference to it. Raises if taken."""
        return await self.conn.send(self._directory, OPEN, [name])

    async def enter(self, name: str):
        """Return a reference to an existing room. Raises if there is none."""
        return await self.conn.send(self._directory, ENTER, [name])

    async def list(self) -> "list[tuple[str, int]]":
        """The live rooms — the ones with people in them — as (name, count)."""
        return _rooms(await self.conn.send(self._directory, LIST, []))

    async def watch(self, on_event) -> "list[tuple[str, int]]":
        """Follow the live room list: hand the directory an inbox it calls back
        with each change, and return the current snapshot as a baseline.
        ``on_event(kind, name, count)`` then fires on every open/close/count
        change (``kind`` is ``"opened"``, ``"closed"``, or ``"count"``)."""
        def observer(verb: str, args: list):
            if verb != NOTIFY:
                raise ValueError(f"watch inbox has no method {verb!r}")
            kind = args[0] if args and isinstance(args[0], str) else "count"
            name = args[1] if len(args) > 1 and isinstance(args[1], str) else ""
            count = int(args[2]) if len(args) > 2 else 0
            on_event(kind, name, count)
            return None

        inbox = self.conn.spawn(observer)
        return _rooms(await self.conn.send(self._directory, WATCH, [inbox]))

    async def close(self) -> None:
        """Close the connection, ending every room's message stream."""
        await self.conn.close()


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
    async def subscribe(cls, conn: Connection, room_ref, nick: str) -> "Room":
        self = cls(conn, room_ref)

        # The room calls this back with every line; surface it on the stream.
        inbox = conn.spawn(self._inbox)

        # End the stream when the connection closes.
        asyncio.ensure_future(self._until_closed())

        # Subscribe, handing the room a capability to our inbox. The welcome it
        # returns is our first line.
        welcome = await conn.send(room_ref, SUBSCRIBE, [nick, inbox])
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
