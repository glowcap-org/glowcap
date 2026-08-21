"""The native loop-backed Session transport lifetime."""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Optional

from .._errors import PancakeError

if TYPE_CHECKING:
    from .._loop import DriverLoop


class _LoopTransport:
    """The loop-backed :class:`pancake.Session` transport duck: no byte verbs
    (the native loop owns the wire), one closed event the serve task and
    ``wait_closed`` share, and the back-reference `Session`'s branched arms
    dispatch on. Constructed on the asyncio thread that drives the loop."""

    def __init__(self, driver_loop: DriverLoop, ptr: int) -> None:
        self._driver_loop = driver_loop
        self._ptr = ptr
        self._closed = asyncio.Event()
        self._failure: "Optional[PancakeError]" = None

    def mark_closed(self) -> None:
        self._closed.set()

    def close(self) -> None:
        self._closed.set()

    def mark_failed(self, error: PancakeError) -> None:
        self._failure = error
        self._closed.set()

    async def wait_closed(self) -> None:
        await self._closed.wait()
        if self._failure is not None:
            raise self._failure
