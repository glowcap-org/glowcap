"""Binding-owned lifetime for one native driver listener."""

from __future__ import annotations

from typing import TYPE_CHECKING, Optional, Union

from ._errors import PancakeError

if TYPE_CHECKING:
    from ._loop import DriverLoop


class ListenerOwner:
    """Ownership of exactly one native driver listener.

    The owner closes admission for its listener and releases only accepted
    handles that have not crossed into a public Session. It never owns the
    loop, Host, or sibling listeners.
    """

    __slots__ = ("_loop", "listener", "_closed", "_ready", "_failure")

    def __init__(self, loop: DriverLoop, listener: int) -> None:
        self._loop = loop
        self.listener = listener
        self._closed = False
        self._ready = False
        self._failure: Optional[PancakeError] = None

    @property
    def ready(self) -> bool:
        """Whether the provider has completed listener construction."""
        return self._ready

    @property
    def failure(self) -> Optional[PancakeError]:
        """The terminal setup failure, if construction was rejected."""
        return self._failure

    def _mark_ready(self) -> None:
        self._ready = True

    def _mark_failed(self, error: PancakeError) -> None:
        self._failure = error
        self._closed = True

    def close(self) -> None:
        if self._closed:
            return
        if self._loop._released:
            self._closed = True
            return
        self._loop.close_listener(self.listener)


ListenerLike = Union[int, ListenerOwner]
