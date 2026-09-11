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

The wire grammar this reads, the verbs, the publication record, the watch and
room notification shapes, and the subscribe answer, comes from
``_protocol_gen.py`` beside this file, generated from
``tools/gen/rooms_protocol.zig`` and shared with every sibling client. The
checks below are this language's own; what they check against is the table.
"""

from __future__ import annotations

import asyncio
import dataclasses
import pathlib
import sys
from dataclasses import dataclass

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path()

from glowcap import (  # noqa: E402
    tcp,
    Host,
    Ref,
    Session,
    Runtime,
    designator_host_port,
    parse_locator,
)
from glowcap._constants import HINT_DIRECT_ADDRESSES, TRANSPORT_IROH  # noqa: E402
from glowcap.iroh import IrohConfig, Reachability, provider as iroh_provider  # noqa: E402

from _protocol_gen import (  # noqa: E402
    DIRECTORY,
    DM,
    ENTER,
    INTRODUCE,
    LIST_PUBLICATIONS,
    MEMBER_REGISTRATION,
    MEMBERSHIP_ENDED,
    NOTIFY,
    OPEN,
    POST,
    PUBLICATION_FIELDS,
    REGISTER,
    REGISTRATION_EVENT_FIELDS,
    REGISTRATION_ID_PATTERN,
    REGISTRATION_ROW_FIELDS,
    ROOM_SENDER,
    ROOM_TAILS,
    SUBSCRIBE,
    SUBSCRIBE_ANSWER_FIELDS,
    WATCH_KINDS,
    WATCH_PUBLICATIONS,
    WATCH_SNAPSHOT_FIELDS,
)

# How long `register` waits for the directory's `notify("registered")` before it
# gives up. Matches the TypeScript client's `REGISTER_ACK_TIMEOUT_MS`: a
# registration whose ack never lands must surface as a failure the caller can
# retry, not a silent hang, and the window sits far above the round-trip a
# healthy directory answers within.
REGISTER_ACK_TIMEOUT_S = 10.0
MAX_UNREAD_LINES = 256


def _admits_type(kind: str, value) -> bool:
    """Whether one wire value is of the declared type, checked natively."""
    if kind == "string":
        return isinstance(value, str)
    if kind == "text":
        return isinstance(value, str) and len(value) > 0
    if kind == "natural":
        return isinstance(value, int) and not isinstance(value, bool) and value >= 0
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "reference":
        return isinstance(value, Ref)
    if kind == "registration-id":
        return isinstance(value, str) and REGISTRATION_ID_PATTERN.fullmatch(value) is not None
    if kind == "list":
        return isinstance(value, list)
    return kind == "any"


def _admits(field, value) -> bool:
    """Whether one wire value fits its declared field: a null where the field
    allows one, a member of the enumeration where it has one, and the type."""
    _name, kind, nullable, values = field
    if value is None:
        return nullable
    if values and value not in values:
        return False
    return _admits_type(kind, value)


def _fits(fields, values) -> bool:
    """Whether a wire list is exactly the declared fields, one value each."""
    return (
        isinstance(values, list)
        and len(values) == len(fields)
        and all(_admits(field, value) for field, value in zip(fields, values))
    )


def _registration_id(raw, context: str) -> str:
    if not _admits_type("registration-id", raw):
        raise ValueError(f"{context} did not name a valid registration ID")
    return raw


@dataclass(frozen=True)
class RoomInfo:
    """One exact directory publication. Foreign occupancy is unknown, not zero.

    The fields are the generated ``PUBLICATION_FIELDS`` in wire order, so a
    validated row constructs one positionally."""

    name: str
    count: int | None
    id: str
    kind: str
    origin: str
    proof: str
    offers: str | None


if tuple(field.name for field in dataclasses.fields(RoomInfo)) != tuple(name for name, *_ in PUBLICATION_FIELDS):
    raise RuntimeError("RoomInfo does not follow the generated publication record")


def _room(raw) -> RoomInfo | None:
    return RoomInfo(*raw) if _fits(PUBLICATION_FIELDS, raw) else None


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
    if not _fits(WATCH_SNAPSHOT_FIELDS, raw):
        raise ValueError("the directory answered a malformed watch snapshot")
    rooms, registrations, _omitted = raw
    if not all(_fits(REGISTRATION_ROW_FIELDS, row) for row in registrations):
        raise ValueError("the directory answered malformed registration rows")
    return _rooms(rooms)


def _watch_room_event(args) -> "tuple[str, RoomInfo | None]":
    """Decode one complete watcher callback without treating malformed rows as
    an event the terminal simply did not care to display."""
    if not isinstance(args, list) or not args or not isinstance(args[0], str):
        raise ValueError("the directory sent a malformed watch notification")
    kind = args[0]
    shape = WATCH_KINDS.get(kind)
    if shape is None:
        raise ValueError(f"the directory sent an unknown watch event {kind!r}")
    fields, room = shape
    if not _fits(fields, args[1:]):
        raise ValueError(f"the directory sent a malformed {'room' if room else kind} watch notification")
    return kind, _room(args[1:]) if room else None


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
        fields, _room = WATCH_KINDS["registered"]

        def inbox(verb: str, args: list):
            if verb == NOTIFY and args and args[0] == "registered" and not done.done():
                # The member's own register inbox hears the name and the id, the
                # watcher shape without its count.
                if not _fits([field for field in fields if field[0] != "count"], args[1:]) or args[1] != nick:
                    raise ValueError(f'register("{nick}") received a malformed acknowledgement')
                done.set_result(args[2])
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
    """A membership change a system line carries as structured wire args, not prose.
    ``kind`` is the generated tail's tag, ``names`` the members it is about (the
    whole roster, or the one member), and ``effect`` what it does to them:
    ``ARRIVE``, ``DEPART``, or ``STAY`` from ``_protocol_gen``."""

    kind: str
    names: "list[str]"
    effect: str


def _tail_fits(tail, sender: str, text: str, extra: list) -> bool:
    """Whether a room line's sender, text, and arguments after the tag are what
    the generated tail declares."""
    trailing, rest, who, rule, _effect = tail
    if who == "room" and sender != ROOM_SENDER:
        return False
    if who == "member" and sender == ROOM_SENDER:
        return False
    if rule == "empty" and text != "":
        return False
    if rule == "nonempty" and text == "":
        return False
    fixed, more = extra[: len(trailing)], extra[len(trailing):]
    if not _fits(trailing, fixed):
        return False
    if rest is None:
        return not more
    return all(_admits_type(rest, value) for value in more)


def _read_presence(sender: str, text: str, args: list) -> "Presence | None":
    """The structured presence after a room line's display text, when the tag
    names a presence tail and the arguments are its shape. Ordinary chat lines
    carry none, and a malformed tail reads as none, so the line still draws."""
    tag = args[2] if len(args) > 2 else None
    tail = ROOM_TAILS.get(tag)
    if tail is None or tail[4] is None or not _tail_fits(tail, sender, text, args[3:]):
        return None
    trailing, rest, _who, _rule, effect = tail
    fixed, more = args[3:3 + len(trailing)], args[3 + len(trailing):]
    names = [value for field, value in zip(trailing, fixed) if field[0] == "name"]
    if rest is not None:
        names.extend(more)
    return Presence(tag, names, effect)


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


def _membership_seat(answer) -> Ref:
    """The membership seat ``subscribe`` answers with, the first of the generated
    ``SUBSCRIBE_ANSWER_FIELDS``. Every later membership verb goes to the seat,
    never to the room it was answered for."""
    if not _fits(SUBSCRIBE_ANSWER_FIELDS, answer):
        raise ValueError("the room answered subscribe without one membership capability")
    return answer[[name for name, *_ in SUBSCRIBE_ANSWER_FIELDS].index("seat")]


class Room:
    """A membership in a chat room. Get one with :meth:`join`, iterate it for the
    lines the room sends, :meth:`say` to talk, and :meth:`leave` when done."""

    def __init__(self, session: Session) -> None:
        self._session = session
        # The seat the room answers subscribe with; posts go there.
        self._membership: Ref | None = None
        self._lines: asyncio.Queue = asyncio.Queue(maxsize=MAX_UNREAD_LINES)
        self._leaving = False
        self._ended = False
        self._failure: Exception | None = None

    @classmethod
    async def subscribe(cls, session: Session, room_ref, nick: str) -> "Room":
        self = cls(session)

        # The room calls this back with every line; surface it on the stream.
        inbox = session.spawn(self._inbox)

        # End the stream when the connection closes.
        asyncio.ensure_future(self._until_closed())

        # Subscribe, handing the room a capability to our inbox. The room answers
        # with the membership seat; the welcome and the roster arrive as our
        # first notify, not as part of that answer.
        self._membership = _membership_seat(await session.send(room_ref, SUBSCRIBE, [nick, inbox]))
        return self

    async def say(self, text: str) -> None:
        """Say a line to everyone in the room, on the membership seat."""
        membership = self._membership
        if membership is None:
            raise RuntimeError("the room has no membership seat")
        await self._session.send(membership, POST, [text])

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
        if len(args) > 2 and args[2] == MEMBERSHIP_ENDED:
            if not _tail_fits(ROOM_TAILS[MEMBERSHIP_ENDED], sender, text, args[3:]):
                raise ValueError("membership-ended notify takes one reason")
            self._end_membership(text)
            return None
        self._emit(sender, text, _read_presence(sender, text, args))
        return None

    def _end_membership(self, reason: str) -> None:
        """The room's last word to this inbox (a steward's kick, say): the reason
        is the last line, and once the retained lines are read the stream raises
        it, the way an overrun does, because no more lines will ever arrive."""
        self._emit(ROOM_SENDER, reason)
        self._failure = RuntimeError(f"the room ended this membership: {reason}")
        self._ended = True

    def _emit(self, sender: str, text: str, presence: "Presence | None" = None) -> None:
        if self._ended:
            raise RuntimeError("the room inbox is closed")
        try:
            self._lines.put_nowait(Message(sender, text, sender == ROOM_SENDER, presence))
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
