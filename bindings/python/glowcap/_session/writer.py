"""A session's one writer task.

FLUSH and CLOSE actions wake it, and nothing that reads waits on a write, so a
partner slow to read cannot stop this side reading. Passes are counted: a
caller that must know its frames left waits for the first pass that began
after its request, which takes every frame the core had queued by then.
"""

from __future__ import annotations

import asyncio
from typing import Optional, Protocol

from .. import _constants as _abi
from .._errors import GlowcapError


class WriterOwner(Protocol):
    """What the writer drives on its Session."""

    async def flush_outbound(self) -> bool:
        """Take and write every queued frame, returning whether any left the
        core. A raise has already retained its cause and retired the session."""
        ...

    def close_transport(self) -> None: ...

    def _finish_close(self, result: int) -> None:
        """Settle an explicit close with the CLOSE action's result."""
        ...

    def _writer_wrote(self) -> None:
        """Resume Host work that outbound backpressure parked."""
        ...

    def _own_writer(self, task: "asyncio.Task[None]") -> None:
        """Register the running writer so Host release waits for it."""
        ...


class Outbound:
    __slots__ = (
        "_owner",
        "_phase",
        "_wake",
        "_stopped",
        "_started",
        "_finished",
        "_progress",
        "_close_result",
        "_task",
    )

    def __init__(self, owner: WriterOwner) -> None:
        self._owner = owner
        # idle, running, closing, or exited.
        self._phase = "idle"
        self._wake = asyncio.Event()
        self._stopped = False
        self._started = 0
        self._finished = 0
        self._progress = asyncio.Event()
        self._close_result: Optional[int] = None
        self._task: Optional[asyncio.Task[None]] = None

    @property
    def close_delivered(self) -> bool:
        """The core already ended this session. Reading is over, and the writer
        closes the transport after its final drain."""
        return self._close_result is not None

    async def exited(self) -> None:
        """Return once no writer runs."""
        task = self._task
        if task is not None:
            await asyncio.wait((task,))

    def request(self) -> int:
        """Wake the writer to drain the core's outbound frames, starting it on
        first use. Returns before any byte is written, with the number of the
        pass that takes every frame queued so far, for :meth:`written`."""
        self._wake.set()
        covering = self._started + 1
        if self._phase == "idle":
            self._phase = "running"
            # A task starts on a later loop turn, so a CLOSE marks the phase
            # before the first pass reads it.
            task = asyncio.get_running_loop().create_task(self._run())
            self._task = task
            self._owner._own_writer(task)
        return covering

    async def written(self, covering: int) -> None:
        """Wait until pass ``covering`` has finished. A writer that exited
        first closed the transport, so frames it had not taken never leave."""
        while self._finished < covering:
            if self._phase == "exited":
                raise GlowcapError(
                    _abi.ERR_CLOSED,
                    "the connection closed before its queued frames were written",
                )
            self._progress.clear()
            await self._progress.wait()

    def close_after_flush(self, result: int) -> None:
        """Close the transport once the writer has drained every frame the core
        queued ahead of this CLOSE, so a final abort or finish still reaches
        the partner."""
        self._close_result = result
        self.request()
        if self._phase == "running":
            self._phase = "closing"
        elif self._phase == "exited":
            self._owner.close_transport()
            self._owner._finish_close(result)

    def stop(self) -> None:
        """The transport closed under the writer: exit after any pass in
        flight."""
        self._stopped = True
        self._wake.set()

    async def _run(self) -> None:
        # Each wake drains everything queued, so FLUSH actions coalesce. Taken
        # frames lower the queue the core's backpressure measures, so a pass
        # that wrote schedules a drain for the work that pressure parked.
        try:
            while not self._stopped:
                if not self._wake.is_set():
                    await self._wake.wait()
                    continue
                self._wake.clear()
                # Read before the pass: a CLOSE that lands during it also wakes
                # the writer, so the next pass drains its frames and then closes.
                closing = self._phase == "closing"
                self._started += 1
                try:
                    wrote = await self._owner.flush_outbound()
                except Exception:  # noqa: BLE001 - the session owns this failure
                    # flush_outbound retained the exact cause and retired the
                    # session.
                    break
                finally:
                    self._finished = self._started
                    self._progress.set()
                if closing:
                    self._owner.close_transport()
                    break
                if wrote:
                    self._owner._writer_wrote()
        finally:
            self._phase = "exited"
            if self._close_result is not None:
                self._owner._finish_close(self._close_result)
            self._progress.set()
