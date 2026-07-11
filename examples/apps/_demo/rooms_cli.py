"""Shared rooms CLI helpers mirrored from ``deno/lib/errors.ts``."""

from __future__ import annotations

NO_SUCH_ROOM = "no-such-room"
ROOM_EXISTS = "room-exists"


def error_code(err: Exception) -> str:
    """The typed code at the front of a room error reason, ``<code>: <detail>``."""
    head, sep, _ = str(err).partition(": ")
    return head if sep else ""


async def enter_or_open(directory, name: str):
    """Enter ``name``, opening the room when it does not exist yet."""
    try:
        return await directory.enter(name)
    except Exception as err:  # noqa: BLE001
        if error_code(err) != NO_SUCH_ROOM:
            raise
    try:
        return await directory.open(name)
    except Exception as err:  # noqa: BLE001
        if error_code(err) != ROOM_EXISTS:
            raise
        return await directory.enter(name)
