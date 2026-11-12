"""Shared Rooms CLI helpers. The codes come from ``rooms_codes.py``, which
``browser_metadata`` generates from the Rust ``FailureCode`` table."""

from __future__ import annotations

from glowcap import GlowcapError, VowBroken
from rooms_codes import NO_SUCH_ROOM, ROOM_EXISTS


def error_code(err: BaseException) -> str:
    """The Rooms code a room's refusal carries at the front of its reason,
    ``<code>: <detail>``. Empty for any other failure, so a transport or
    marshalling error is never mistaken for the room's answer."""
    reason = err.application_message() if isinstance(err, GlowcapError) else None
    head, sep, _ = (reason or "").partition(": ")
    return head if sep else ""


async def enter_or_open(directory, name: str):
    """Enter ``name``, opening the room when it does not exist yet."""
    try:
        return await directory.enter(name)
    except VowBroken as err:
        if error_code(err) != NO_SUCH_ROOM:
            raise
    try:
        return await directory.open(name)
    except VowBroken as err:
        if error_code(err) != ROOM_EXISTS:
            raise
        return await directory.enter(name)
