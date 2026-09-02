"""A small, friendly client for the rooms chat, built on glowcap actors.

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
import re
import sys
from dataclasses import dataclass

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path()

from glowcap import (  # noqa: E402
    tcp,
    Host,
    Session,
    Runtime,
    designator_host_port,
    parse_locator,
)
from glowcap._constants import HINT_DIRECT_ADDRESSES, TRANSPORT_IROH  # noqa: E402
from glowcap.iroh import IrohConfig, Reachability, provider as iroh_provider  # noqa: E402

DIRECTORY = "directory"
OPEN, ENTER = "open", "enter"
LIST_PUBLICATIONS, WATCH_PUBLICATIONS = "listPublications", "watchPublications"
REGISTER, INTRODUCE, MEMBER_REGISTRATION = "register", "introduce", "memberRegistration"
SUBSCRIBE, POST, LEAVE, NOTIFY = "subscribe", "post", "leave", "notify"
DM = "dm"

# How long `register` waits for the directory's `notify("registered")` before it
# gives up. Matches the TypeScript client's `REGISTER_ACK_TIMEOUT_MS`: a
# registration whose ack never lands must surface as a failure the caller can
# retry, not a silent hang, and the window sits far above the round-trip a
# healthy directory answers within.
REGISTER_ACK_TIMEOUT_S = 10.0
MAX_UNREAD_LINES = 256
REGISTRATION_ID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def _registration_id(raw, context: str) -> str:
    if not isinstance(raw, str) or REGISTRATION_ID.fullmatch(raw) is None:
        raise ValueError(f"{context} did not name a valid registration ID")
    return raw


@dataclass(frozen=True)
class RoomInfo:
    """One exact directory publication. Foreign occupancy is unknown, not zero."""

    name: str
    count: int | None
    id: str
    kind: str
    origin: str
    proof: str
    offers: str | None


def _room(raw) -> RoomInfo | None:
    if not isinstance(raw, list) or len(raw) != 7:
        return None
    name, count_raw, entry_id, kind, origin, proof, offers = raw
    if not all(isinstance(value, str) for value in (name, entry_id, kind, origin, proof)):
        return None
    if count_raw is not None and (
        isinstance(count_raw, bool) or not isinstance(count_raw, int) or count_raw < 0
    ):
        return None
    if offers is not None and offers not in ("observer", "participant"):
        return None
    return RoomInfo(name, count_raw, entry_id, kind, origin, proof, offers)


def _rooms(raw) -> "list[RoomInfo]":
    """Decode one complete publication list without dropping malformed rows."""
    if not isinstance(raw, list):
        raise ValueError("the directory answered a room list that is not a list")
    out: list[RoomInfo] = []
    for item in raw:
        room = _room(item)
        if room is None:
            raise ValueError("the directory answered a malformed room publication")
        out.append(room)
    return out


def _watch_rooms(raw) -> "list[RoomInfo]":
    """Decode the atomic rooms, registrations, and omission-count baseline."""
    if not isinstance(raw, list) or len(raw) != 3:
        raise ValueError("the directory answered a malformed watch snapshot")
    rooms, registrations, omitted = raw
    if not isinstance(registrations, list) or not all(
        isinstance(row, list)
        and len(row) == 2
        and isinstance(row[0], str)
        and len(row[0]) > 0
        and isinstance(row[1], str)
        and len(row[1]) > 0
        for row in registrations
    ):
        raise ValueError("the directory answered malformed registration rows")
    if isinstance(omitted, bool) or not isinstance(omitted, int) or omitted < 0:
        raise ValueError("the directory answered an invalid watch omission count")
    return _rooms(rooms)


def _watch_room_event(args) -> "tuple[str, RoomInfo | None]":
    """Decode one complete watcher callback without treating malformed rows as
    an event the terminal simply did not care to display."""
    if not isinstance(args, list) or not args or not isinstance(args[0], str):
        raise ValueError("the directory sent a malformed watch notification")
    kind = args[0]
    if kind in ("opened", "closed", "count"):
        room = _room(args[1:])
        if room is None:
            raise ValueError("the directory sent a malformed room watch notification")
        return kind, room
    if kind in ("registered", "unregistered"):
        if (
            len(args) != 4
            or not isinstance(args[1], str)
            or not args[1]
            or isinstance(args[2], bool)
            or not isinstance(args[2], int)
            or args[2] < 0
        ):
            raise ValueError("the directory sent a malformed member watch notification")
        _registration_id(args[3], f'watch {kind} for "{args[1]}"')
        return kind, None
    if kind == "truncated":
        if (
            len(args) != 2
            or isinstance(args[1], bool)
            or not isinstance(args[1], int)
            or args[1] < 0
        ):
            raise ValueError("the directory sent a malformed watch truncation")
        return kind, None
    raise ValueError(f"the directory sent an unknown watch event {kind!r}")


def rooms_host() -> Host:
    """A Host wearing the core-authored native profile."""
    return Host(profile="native")


async def _dial(locator: str) -> "tuple[Runtime, Session]":
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
        runtime = await Runtime.open(
            provider=iroh_provider(IrohConfig(reach)), adopt_host=rooms_host()
        )
        return runtime, await runtime.connect(loc)
    host, port = designator_host_port(locator)
    runtime = await Runtime.open(provider=tcp.provider(), adopt_host=rooms_host())
    return runtime, await runtime.connect(tcp.locator(host, port))


class Directory:
    """The directory of rooms: the server's one published object. Connect to it,
    then :meth:`open` a new room or :meth:`enter` an existing one, each returns a
    reference to that room. Both mirror the wire: ``open`` raises if the name is
    taken, ``enter`` raises if there is no such room."""

    def __init__(self, session: Session, directory, runtime: Runtime) -> None:
        self.session = session
        self._directory = directory
        self._runtime = runtime

    @classmethod
    async def connect(cls, locator: str) -> "Directory":
        runtime, session = await _dial(locator)
        session.serve()  # start the inbound loop before fetching
        directory = await session.fetch(DIRECTORY)
        return cls(session, directory, runtime)

    async def close(self) -> None:
        """Close the session, ending every room's message stream, then release
        the runtime that carried it."""
        await self.session.close()
        await self._runtime.close()

    async def open(self, name: str):
        """Create a new room and return a reference to it. Raises if taken."""
        return await self.session.send(self._directory, OPEN, [name])

    async def enter(self, name: str):
        """Return a reference to an existing room. Raises if there is none."""
        return await self.session.send(self._directory, ENTER, [name])

    async def list(self) -> "list[RoomInfo]":
        """The directory's exact live local and foreign room publications."""
        return _rooms(await self.session.send(self._directory, LIST_PUBLICATIONS, []))

    async def watch(self, on_event) -> "list[RoomInfo]":
        """Follow the live room list: hand the directory an inbox it calls back
        with each change, and return the current snapshot as a baseline.
        ``on_event(kind, room)`` then fires with the exact publication record."""
        def observer(verb: str, args: list):
            if verb != NOTIFY:
                raise ValueError(f"watch inbox has no method {verb!r}")
            kind, room = _watch_room_event(args)
            if room is not None:
                on_event(kind, room)
            return None

        inbox = self.session.spawn(observer)
        return _watch_rooms(await self.session.send(self._directory, WATCH_PUBLICATIONS, [inbox]))

    async def register(self, nick: str, locator: str) -> str:
        """Announce a dialable DM member. Resolves once the directory acks
        ``registered``, and raises
        :class:`TimeoutError` if that ack never lands, so a caller can retry
        instead of waiting forever on a directory that failed the registration
        after accepting the message."""
        done = asyncio.get_running_loop().create_future()

        def inbox(verb: str, args: list):
            if verb == NOTIFY and args and args[0] == "registered" and not done.done():
                if len(args) != 3 or args[1] != nick:
                    raise ValueError(f'register("{nick}") received a malformed acknowledgement')
                done.set_result(_registration_id(args[2], f'register("{nick}")'))
            return None

        observer = self.session.spawn(inbox)
        await self.session.send(self._directory, REGISTER, [nick, locator, observer])
        return await asyncio.wait_for(done, REGISTER_ACK_TIMEOUT_S)

    async def member_registration(self, peer: str) -> str:
        """Return the exact live generation of ``peer``'s nickname."""
        return _registration_id(
            await self.session.send(self._directory, MEMBER_REGISTRATION, [peer]),
            f'memberRegistration("{peer}")',
        )

    async def introduce(self, nick: str, registration_id: str | None = None):
        """Ask the directory to introduce us to a registered member; returns a
        live capability to the inbox that member minted for us (redeemed by direct
        dial). Refused ``introduction-pending`` on genuine first contact; retry
        once the member has offered an inbox. This client answers no
        ``mintInboxFor`` request, so it can reach a member but cannot be reached.

        :meth:`register` first: the directory reads the asker's name off its own
        registration, so an unregistered caller is refused ``not-registered``."""
        expected = registration_id or await self.member_registration(nick)
        expected = _registration_id(expected, f'introduce("{nick}")')
        ref = await self.session.send(self._directory, INTRODUCE, [nick, expected])
        if ref is None:
            raise ValueError(f'introduce("{nick}") did not return a capability')
        return ref


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
        """Open a line to ``peer``. Call :meth:`Directory.register` on
        ``directory`` first, and expect ``introduction-pending`` on first contact:
        both preconditions are :meth:`Directory.introduce`'s."""
        return cls(directory.session, await directory.introduce(peer), peer)

    async def say(self, text: str) -> None:
        """Deliver one direct message. There is no sender argument; the inbox is
        the sender (see ``offerInbox`` in ``lib/protocol.ts``)."""
        await self._session.send(self._dm, DM, [text])


class Room:
    """A membership in a chat room. Get one with :meth:`join`, iterate it for the
    lines the room sends, :meth:`say` to talk, and :meth:`leave` when done."""

    def __init__(self, session: Session, room) -> None:
        self._session = session
        self._room = room
        self._lines: asyncio.Queue = asyncio.Queue(maxsize=MAX_UNREAD_LINES)
        self._leaving = False
        self._ended = False
        self._failure: Exception | None = None

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
            if self._ended and self._lines.empty():
                if self._failure is not None:
                    raise self._failure
                return
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
        if self._ended:
            raise RuntimeError("the room inbox is closed")
        try:
            self._lines.put_nowait(Message(sender, text, sender == "room", presence))
        except asyncio.QueueFull:
            self._failure = RuntimeError(
                f"the room retained its maximum {MAX_UNREAD_LINES} unread lines"
            )
            self._ended = True
            raise self._failure

    def _finish(self) -> None:
        if self._ended:
            return
        self._ended = True
        # If the queue is full, no wake is needed: its reader is not parked and
        # observes `_ended` after draining the last retained line. Otherwise the
        # sentinel wakes an empty reader and follows every already-admitted line.
        try:
            self._lines.put_nowait(None)
        except asyncio.QueueFull:
            pass

    async def _until_closed(self) -> None:
        try:
            await self._session.serve()
            if not self._leaving:
                print("rooms: the room closed the connection", file=sys.stderr)
        except Exception as err:  # noqa: BLE001
            if not self._leaving:
                print(f"rooms: lost the connection, {err}", file=sys.stderr)
        finally:
            self._finish()
