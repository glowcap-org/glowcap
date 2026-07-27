"""A small, friendly client for the rooms chat, built on pancake actors.

On the connection API this is barely a layer: connect, fetch the directory by
name, ask it to open or enter a room (which hands back a live reference to that
room), spawn an inbox the room can call back, subscribe by handing it that
capability, and surface the room's callbacks as a stream. Everything above it
reads like an app.

    directory = await Directory.connect("127.0.0.1:9099")
    room = await Room.subscribe(directory.session, await directory.enter("general"), "alice")
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path()

from pancake import Session, connect, designator_host_port, parse_locator, tcp_locator  # noqa: E402
from pancake._constants import HINT_DIRECT_ADDRESSES, TRANSPORT_IROH  # noqa: E402
from pancake.iroh import Reachability  # noqa: E402

DIRECTORY = "directory"
OPEN, ENTER, LIST, WATCH = "open", "enter", "list", "watch"
REGISTER, INTRODUCE = "register", "introduce"
SUBSCRIBE, POST, LEAVE, NOTIFY = "subscribe", "post", "leave", "notify"
DM = "dm"

# How long `register` waits for the directory's `notify("registered")` before it
# gives up. Matches the TypeScript client's `REGISTER_ACK_TIMEOUT_MS`: a
# registration whose ack never lands must surface as a failure the caller can
# retry, not a silent hang, and the window sits far above the round-trip a
# healthy directory answers within.
REGISTER_ACK_TIMEOUT_S = 10.0


def _rooms(raw) -> "list[tuple[str, int]]":
    """The wire shape of ``list``/``watch`` is a list of ``[name, count]`` pairs;
    lift it to ``(name, count)`` tuples."""
    out: list[tuple[str, int]] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, list) and len(item) >= 2:
                out.append((str(item[0]), int(item[1])))
    return out


async def _dial(locator: str) -> Session:
    """Dial a transport-neutral rooms locator: an ``ocapn://`` URI goes over iroh,
    a bare ``host:port`` over TCP. The room's wire is identical either way; only
    how a member reaches it differs. A URI carrying direct-addresses dials those
    directly (relay-less Direct); a node-id-only URI resolves the peer through
    discovery."""
    if "://" in locator:
        loc = parse_locator(locator)
        if loc.transport != TRANSPORT_IROH:
            raise ValueError(
                f'rooms expected an iroh ocapn:// URI, got "{loc.transport}": {locator}',
            )
        hints = loc.hints.get(HINT_DIRECT_ADDRESSES, "")
        reach = Reachability.DIRECT if hints else Reachability.DISCOVERY
        return await connect(locator, reach)
    host, port = designator_host_port(locator)
    return await connect(tcp_locator(host, port))


class Directory:
    """The directory of rooms: the server's one published object. Connect to it,
    then :meth:`open` a new room or :meth:`enter` an existing one, each returns a
    reference to that room. Both mirror the wire: ``open`` raises if the name is
    taken, ``enter`` raises if there is no such room."""

    def __init__(self, session: Session, directory) -> None:
        self.session = session
        self._directory = directory

    @classmethod
    async def connect(cls, locator: str) -> "Directory":
        session = await _dial(locator)
        session.serve()  # start the inbound loop before fetching
        directory = await session.fetch(DIRECTORY)
        return cls(session, directory)

    async def open(self, name: str):
        """Create a new room and return a reference to it. Raises if taken."""
        return await self.session.send(self._directory, OPEN, [name])

    async def enter(self, name: str):
        """Return a reference to an existing room. Raises if there is none."""
        return await self.session.send(self._directory, ENTER, [name])

    async def list(self) -> "list[tuple[str, int]]":
        """The live rooms — the ones with people in them — as (name, count)."""
        return _rooms(await self.session.send(self._directory, LIST, []))

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

        inbox = self.session.spawn(observer)
        return _rooms(await self.session.send(self._directory, WATCH, [inbox]))

    async def register(self, nick: str, locator: str) -> None:
        """Announce a dialable DM member (publish ``dm`` on this session first).
        Resolves once the directory acks ``registered``, and raises
        :class:`TimeoutError` if that ack never lands, so a caller can retry
        instead of waiting forever on a directory that failed the registration
        after accepting the message."""
        done = asyncio.get_running_loop().create_future()

        def inbox(verb: str, args: list):
            if verb == NOTIFY and args and args[0] == "registered" and not done.done():
                done.set_result(None)
            return None

        observer = self.session.spawn(inbox)
        await self.session.send(self._directory, REGISTER, [nick, locator, observer])
        await asyncio.wait_for(done, REGISTER_ACK_TIMEOUT_S)

    async def introduce(self, nick: str):
        """Ask the directory to introduce us to a registered member; returns a
        live capability to that member's ``dm`` object (redeemed by direct dial)."""
        ref = await self.session.send(self._directory, INTRODUCE, [nick])
        if ref is None:
            raise ValueError(f'introduce("{nick}") did not return a capability')
        return ref

    async def close(self) -> None:
        """Close the session, ending every room's message stream."""
        await self.session.close()


@dataclass
class Presence:
    """A membership change a system line carries as structured wire args, not prose:
    the roster on arrival, or a join/leave. ``names`` is the roster, or ``[nick]`` for
    a join/leave."""

    kind: str  # "roster" | "join" | "leave"
    names: "list[str]"


def _read_presence(args: list) -> "Presence | None":
    """The structured presence after a room line's display text —
    ``notify("room", text, "roster", *names)`` or ``notify("room", text, kind, nick)``.
    Ordinary chat lines carry none."""
    kind = args[2] if len(args) > 2 else None
    if kind == "roster":
        return Presence("roster", [n for n in args[3:] if isinstance(n, str)])
    if kind in ("join", "leave") and len(args) > 3 and isinstance(args[3], str):
        return Presence(kind, [args[3]])
    return None


@dataclass
class Message:
    """One line in the room. ``system`` is true for the room's own announcements
    (a member joining, your welcome); otherwise ``sender`` is who said it.
    ``presence`` is set on a membership-change system line."""

    sender: str
    text: str
    system: bool
    presence: "Presence | None" = None


class DirectMessage:
    """A live direct line to one member, obtained by introduction."""

    def __init__(self, session: Session, dm, peer: str) -> None:
        self._session = session
        self._dm = dm
        self.peer = peer

    @classmethod
    async def open(cls, directory: Directory, peer: str) -> "DirectMessage":
        return cls(directory.session, await directory.introduce(peer), peer)

    async def say(self, from_nick: str, text: str) -> None:
        """Deliver one direct message, tagged with the sender's display nick."""
        await self._session.send(self._dm, DM, [from_nick, text])


class Room:
    """A membership in a chat room. Get one with :meth:`join`, iterate it for the
    lines the room sends, :meth:`say` to talk, and :meth:`leave` when done."""

    def __init__(self, session: Session, room) -> None:
        self._session = session
        self._room = room
        self._lines: asyncio.Queue = asyncio.Queue()
        self._leaving = False

    @classmethod
    async def subscribe(cls, session: Session, room_ref, nick: str) -> "Room":
        self = cls(session, room_ref)

        # The room calls this back with every line; surface it on the stream.
        inbox = session.spawn(self._inbox)

        # End the stream when the connection closes.
        asyncio.ensure_future(self._until_closed())

        # Subscribe, handing the room a capability to our inbox. Success is the
        # resolution; the room delivers the welcome and the roster as our first notify.
        await session.send(room_ref, SUBSCRIBE, [nick, inbox])
        return self

    async def say(self, text: str) -> None:
        """Say a line to everyone in the room."""
        await self._session.send(self._room, POST, [text])

    async def leave(self) -> None:
        """Leave the room and release the connection."""
        self._leaving = True
        await self._session.close()

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
        self._emit(sender, text, _read_presence(args))
        return None

    def _emit(self, sender: str, text: str, presence: "Presence | None" = None) -> None:
        self._lines.put_nowait(Message(sender, text, sender == "room", presence))

    async def _until_closed(self) -> None:
        try:
            await self._session.serve()
            if not self._leaving:
                print("rooms: the room closed the connection", file=sys.stderr)
        except Exception as err:  # noqa: BLE001
            if not self._leaving:
                print(f"rooms: lost the connection, {err}", file=sys.stderr)
        finally:
            self._lines.put_nowait(None)  # end the messages stream
