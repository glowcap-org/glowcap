#!/usr/bin/env python3
"""The Python WebRTC proofs through the C provider, in order.

Dial (ADR-0226): the binding installs ``webrtc.provider`` with its own
signaling, then an ordinary ``Runtime.connect`` dials the Zig WebRTC answerer by
locator, fetches its greeter, and calls it.

Listen (ADR-0232): the binding listens with ``webrtc.listen``, the Zig WebRTC
offerer dials the listener, and the accepted session names the offerer's key.

Each Zig peer is a separate process that speaks one JSON object per line on
stdio. This client's signaling authority writes to its stdin and reads its
stdout: the offer and each local candidate out, the far peer's offer or answer
and candidates in.

Needs the WebRTC ABI and both peers (``zig build webrtc-abi webrtc-answerer
webrtc-offerer``). Run via ``zig build python-webrtc-driver-provider``.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from typing import Awaitable, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from glowcap import Runtime, webrtc  # noqa: E402

GATE = "python-webrtc-driver-provider"
BIN = Path(__file__).resolve().parents[2] / "zig-out" / "bin"
ANSWERER = BIN / "glowcap-webrtc-answerer"
OFFERER = BIN / "glowcap-webrtc-offerer"
DEADLINE_S = 20.0

ignore_port_args(GATE)


class StdioSignaling:
    """Carries candidates to a Zig peer over its stdio. Candidates that arrive
    before ``on_candidate`` subscribes wait for its sink."""

    def __init__(self, proc: "asyncio.subprocess.Process | None" = None) -> None:
        self.proc = proc
        self._sinks: "list[Callable[[str], None]]" = []
        self._pending: "list[str]" = []

    def _write(self, message: dict) -> None:
        stdin = self.proc.stdin if self.proc is not None else None
        assert stdin is not None
        stdin.write((json.dumps(message) + "\n").encode())

    def candidate(self, exchange: int, ice: str) -> None:
        self._write({"type": "candidate", "candidate": json.loads(ice)})

    def on_candidate(self, exchange: int, target: webrtc.Target, sink: Callable[[str], None]):
        self._sinks.append(sink)
        for text in self._pending:
            sink(text)
        self._pending.clear()

        def dispose() -> None:
            if sink in self._sinks:
                self._sinks.remove(sink)

        return dispose

    def feed_candidate(self, line: dict) -> None:
        text = json.dumps(line["candidate"])
        if self._sinks:
            for sink in list(self._sinks):
                sink(text)
        else:
            self._pending.append(text)


class AnswererSignaling(StdioSignaling):
    """The dialing side: the offer goes out and the answer comes back."""

    def __init__(self, proc: asyncio.subprocess.Process) -> None:
        super().__init__(proc)
        self._answer: "asyncio.Future[str]" = asyncio.get_running_loop().create_future()

    async def offer(self, exchange: int, target: webrtc.Target, sdp: str) -> str:
        self._write({"type": "offer", "sdp": sdp})
        return await self._answer

    def answer(self, exchange: int, target: webrtc.Target, sdp: str) -> None:
        raise RuntimeError("this authority only dials")

    def feed(self, line: dict) -> None:
        """Route one stdout line from the answerer."""
        kind = line.get("type")
        if kind == "answer" and not self._answer.done():
            self._answer.set_result(line["sdp"])
        elif kind == "candidate":
            self.feed_candidate(line)
        else:
            raise RuntimeError(f"the answerer wrote a line outside the protocol: {line!r}")


class OffererSignaling(StdioSignaling):
    """The listening side: the answer goes out. It exists before the offerer
    does, because the listener's designator is the offerer's argument."""

    async def offer(self, exchange: int, target: webrtc.Target, sdp: str) -> str:
        raise RuntimeError("this authority only answers")

    def answer(self, exchange: int, target: webrtc.Target, sdp: str) -> None:
        self._write({"type": "answer", "sdp": sdp})


async def read_line(proc: asyncio.subprocess.Process) -> "dict | None":
    assert proc.stdout is not None
    raw = await proc.stdout.readline()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return {}


async def pump(proc: asyncio.subprocess.Process, route: Callable[[dict], None]) -> None:
    while (line := await read_line(proc)) is not None:
        route(line)


async def unless_pump_stops(step: Awaitable, pump_task: asyncio.Task):
    """Await ``step`` unless the pump stops first. Its exception names the line
    that broke the protocol, and a clean end means the peer left early."""
    task = asyncio.ensure_future(step)
    done, _ = await asyncio.wait(
        {task, pump_task}, timeout=DEADLINE_S, return_when=asyncio.FIRST_COMPLETED
    )
    if task in done:
        return task.result()
    task.cancel()
    if pump_task in done:
        pump_task.result()
        fail(GATE, "the Zig peer closed its stdout before the step finished")
    fail(GATE, f"the step did not finish within {DEADLINE_S} s")


async def dial_proof() -> None:
    if not ANSWERER.exists():
        fail(GATE, f"missing {ANSWERER}: run `zig build webrtc-answerer`")
    proc = await asyncio.create_subprocess_exec(
        str(ANSWERER),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
    )
    pump_task = None
    try:
        identity = await asyncio.wait_for(read_line(proc), timeout=DEADLINE_S)
        if not identity or identity.get("type") != "identity":
            fail(GATE, f"the answerer did not open with an identity line: {identity!r}")
        designator = identity["designator"]
        signaling = AnswererSignaling(proc)
        pump_task = asyncio.create_task(pump(proc, signaling.feed))

        async with Runtime.open(provider=webrtc.provider(signaling)) as runtime:
            session = await unless_pump_stops(
                runtime.connect(webrtc.locator(designator)), pump_task
            )
            async with session:
                greeter = await asyncio.wait_for(session.fetch("greeter"), timeout=DEADLINE_S)
                greeting = await asyncio.wait_for(
                    session.send(greeter, "greet", []), timeout=DEADLINE_S
                )
        if not isinstance(greeting, str) or not greeting:
            fail(GATE, f"greet returned {greeting!r}")
        print(f"{GATE}: OK the Python binding dialed the answerer and heard {greeting!r}")
    finally:
        if pump_task is not None:
            pump_task.cancel()
        if proc.returncode is None:
            proc.kill()
        await proc.wait()


def greeter(verb: str, args: list):
    if verb == "greet":
        return "hello over webrtc"
    return None


async def listen_proof() -> None:
    if not OFFERER.exists():
        fail(GATE, f"missing {OFFERER}: run `zig build webrtc-offerer`")
    signaling = OffererSignaling()
    server = await webrtc.listen(
        signaling, webrtc.WebrtcConfig(include_loopback_candidates=True)
    )
    proc = None
    pump_task = None
    try:
        server.host.publish("greeter", greeter)
        advertised = server.locator
        if advertised.transport != "webrtc" or advertised.designator != server.designator:
            fail(GATE, f"the listener advertised {advertised!r}")

        proc = await asyncio.create_subprocess_exec(
            str(OFFERER),
            server.designator,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
        )
        signaling.proc = proc
        identity = await asyncio.wait_for(read_line(proc), timeout=DEADLINE_S)
        if not identity or identity.get("type") != "identity":
            fail(GATE, f"the offerer did not open with an identity line: {identity!r}")
        offerer = identity["designator"]

        def route(line: dict) -> None:
            if line.get("type") == "offer":
                server.provide_offer(offerer, line["sdp"])
            elif line.get("type") == "candidate":
                signaling.feed_candidate(line)
            else:
                raise RuntimeError(f"the offerer wrote a line outside the protocol: {line!r}")

        pump_task = asyncio.create_task(pump(proc, route))
        session = await unless_pump_stops(anext(server), pump_task)
        # The channel is open, so signaling is over: close the carrier.
        assert proc.stdin is not None
        proc.stdin.close()
        partner = session.partner_identity()
        if partner.designator != offerer or not partner.durable_identity_authenticated():
            fail(GATE, f"the accepted session names {partner.designator!r}, not {offerer!r}")
        session.serve()
        if await asyncio.wait_for(proc.wait(), timeout=DEADLINE_S) != 0:
            fail(GATE, f"the offerer exited with {proc.returncode}")
        print(f"{GATE}: OK the Python binding accepted the offerer and named its key")
    finally:
        if pump_task is not None:
            pump_task.cancel()
        if proc is not None and proc.returncode is None:
            proc.kill()
            await proc.wait()
        await server.close()
        await server.host.close()


async def main() -> None:
    await dial_proof()
    await listen_proof()


if __name__ == "__main__":
    asyncio.run(main())
