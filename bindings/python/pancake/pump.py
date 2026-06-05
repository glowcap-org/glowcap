"""Single-thread poll pump wiring a :class:`~pancake.host.Peer` to a
:class:`~pancake.netlayer.Connection`.

This is the faithful Python port of the Racket ``tcp-bridge.rkt`` pump:
the netlayer cdylib owns the socket + Syrup framing, so a :class:`Bridge`
is one poll loop that

1. reads one inbound frame with a short timeout (``read_timeout_ms``); on
   ``WOULD_BLOCK`` it proceeds without inbound,
2. ``step``s the peer and drains ``take_outbound`` to ``write_frame``,
3. repeats until close.

``ctypes`` releases the GIL during foreign calls, so a thread-per-connection
host is viable (:meth:`Bridge.run_in_thread`). The simplest faithful shape —
and the one the in-process loopback verification uses — is the single-thread
:func:`run_until`, which services several bridges round-robin in one thread.
"""

from __future__ import annotations

import threading
import time
from typing import Callable, List, Optional

from .constants import PANCAKE_SESSION_CLOSED, PANCAKE_SESSION_OPEN
from .host import Peer
from .netlayer import CLOSED, MALFORMED, WOULD_BLOCK, Connection

READ_TIMEOUT_MS = 50
POLL_SLEEP_S = 0.001


class Bridge:
    """One peer wired to one connection over a chosen transport."""

    def __init__(
        self,
        peer: Peer,
        conn: Connection,
        transport: str,
        designator: str,
        label: str = "bridge",
        read_timeout_ms: int = READ_TIMEOUT_MS,
    ):
        self.peer = peer
        self.conn = conn
        self.transport = transport
        self.designator = designator
        self.label = label
        self.conn.set_read_timeout_ms(read_timeout_ms)
        self._started = False

    def send_start_session(self) -> None:
        """Kick the handshake (idempotent — only fires once)."""
        if not self._started:
            self.peer.send_start_session(self.transport, self.designator)
            self._started = True

    def pump_once(self) -> Optional[str]:
        """Service one tick. Returns ``None``, ``'closed'`` or ``'malformed'``."""
        frame = self.conn.read_frame()
        if frame is WOULD_BLOCK:
            pass
        elif frame is CLOSED:
            return CLOSED
        elif frame is MALFORMED:
            return MALFORMED
        elif isinstance(frame, (bytes, bytearray)):
            self.peer.feed_inbound(frame)
        self.peer.step()
        while True:
            out = self.peer.take_outbound()
            if out is None:
                break
            self.conn.write_frame(out)
        if self.peer.session_state() == PANCAKE_SESSION_CLOSED:
            return CLOSED
        return None

    def run_in_thread(self, on_stop: Optional[Callable] = None) -> "threading.Thread":
        """Run the pump on a dedicated daemon thread (Racket-bridge style)."""
        self.send_start_session()
        stop = threading.Event()
        self._stop = stop

        def loop():
            while not stop.is_set():
                status = self.pump_once()
                if status in (CLOSED, MALFORMED):
                    break
                time.sleep(POLL_SLEEP_S)
            if on_stop:
                on_stop()

        t = threading.Thread(target=loop, name=f"pancake-bridge-{self.label}", daemon=True)
        t.start()
        self._thread = t
        return t

    def stop(self) -> None:
        ev = getattr(self, "_stop", None)
        if ev:
            ev.set()
        self.conn.close()


def run_until(
    bridges: List[Bridge],
    predicate: Callable[[], bool],
    *,
    timeout_s: float = 5.0,
    sleep_s: float = POLL_SLEEP_S,
    on_tick: Optional[Callable[[], None]] = None,
) -> bool:
    """Pump several bridges round-robin in this thread until ``predicate``.

    The dialer must enqueue its ``op:start-session`` first; callers send
    start-session in the desired order before calling this. Raises
    ``TimeoutError`` if ``predicate`` isn't satisfied within ``timeout_s``.
    """
    for b in bridges:
        b.send_start_session()
    deadline = time.monotonic() + timeout_s
    while True:
        for b in bridges:
            b.pump_once()
        if on_tick:
            on_tick()
        if predicate():
            return True
        if time.monotonic() > deadline:
            raise TimeoutError("pump predicate not satisfied within timeout")
        time.sleep(sleep_s)


def both_open(bridges: List[Bridge]) -> Callable[[], bool]:
    """Predicate: every bridge's peer reached ``SESSION_OPEN``."""

    def pred() -> bool:
        return all(b.peer.session_state() == PANCAKE_SESSION_OPEN for b in bridges)

    return pred
