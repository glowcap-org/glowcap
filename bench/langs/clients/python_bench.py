"""The Python bench client for the per-language consumer-cost bench.

It drives the taskboard unit against the fixed Zig host through pancake's Python
binding (the same connect/fetch/send the demos use) and prints one NDJSON metric
line in the shared schema (see bench/langs/contract.md).

    python3 python_bench.py <mode> <host> <port> <n>
"""

from __future__ import annotations

import asyncio
import gc
import json
import math
import pathlib
import platform
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "bindings" / "python"))

from pancake import Session, Ref, connect, listen, tcp_locator  # noqa: E402

CLIENT = "python"
RUNTIME = f"cpython/{platform.python_version()}"


def emit(obj) -> None:
    # Compact separators so the line matches the orchestrator's NDJSON regexes,
    # which assume no whitespace after `:` or `,` (the shape every other client
    # emits).
    print(json.dumps(obj, separators=(",", ":")))


def now() -> float:
    return time.perf_counter() * 1000.0


def percentile_ms(sorted_vals, p: float) -> float:
    if not sorted_vals:
        return 0.0
    rank = math.ceil(p * len(sorted_vals))
    return sorted_vals[min(len(sorted_vals) - 1, max(0, rank - 1))]


def status_text(v) -> str:
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("latin-1")
    return str(v)


async def run_unit(conn: Session, root) -> None:
    task = await conn.send(root, "create", ["benchmark"])
    await conn.send(task, "assign", ["alice"])
    await conn.send(task, "complete", [])
    status = await conn.send(task, "status", [])
    if status_text(status) != "done":
        raise RuntimeError(f"bad status: {status_text(status)!r}")


async def run_unit_pipelined(conn: Session, root) -> None:
    # The same four verbs as run_unit, but pipelined (ADR-0007, questioner half):
    # assign/complete/status are addressed at the answer `create` will resolve to
    # — the RemotePromise it returns, passed as the send target, without awaiting
    # it — so the unit costs one round trip instead of four. Only the final status
    # is awaited, which flushes the queued batch together. The throughput unit;
    # run_unit stays sequential so the latency row keeps measuring one round trip.
    create = conn.send(root, "create", ["benchmark"])
    conn.send(create, "assign", ["alice"])
    conn.send(create, "complete", [])
    status = await conn.send(create, "status", [])
    if status_text(status) != "done":
        raise RuntimeError(f"bad status: {status_text(status)!r}")


def warmup_count(n: int) -> int:
    return min(n, 500)


async def warm(conn: Session, root, n: int, unit=run_unit) -> None:
    for _ in range(warmup_count(n)):
        await unit(conn, root)
    gc.collect()


async def run_latency(host: str, port: int, n: int) -> None:
    conn = await connect(tcp_locator(host, port))
    root = await conn.fetch("root")
    await warm(conn, root, n)
    lats = []
    for _ in range(n):
        s = now()
        await run_unit(conn, root)
        lats.append(now() - s)
    await conn.close()
    lats.sort()
    mean = sum(lats) / max(1, n)
    emit({
        "v": 1, "metric": "latency", "client": CLIENT, "suite": "taskboard", "n": n,
        "p50_ms": round(percentile_ms(lats, 0.5), 4), "p99_ms": round(percentile_ms(lats, 0.99), 4),
        "p999_ms": round(percentile_ms(lats, 0.999), 4), "mean_ms": round(mean, 4),
        "runtime": RUNTIME, "warmup_n": warmup_count(n),
    })


async def run_throughput(host: str, port: int, n: int) -> None:
    conn = await connect(tcp_locator(host, port))
    root = await conn.fetch("root")
    await warm(conn, root, n, run_unit_pipelined)
    t0 = now()
    for _ in range(n):
        await run_unit_pipelined(conn, root)
    total = now() - t0
    await conn.close()
    emit({
        "v": 1, "metric": "throughput", "client": CLIENT, "suite": "taskboard", "n": n,
        "total_ms": round(total, 2), "rps": round(0 if total <= 0 else n / (total / 1000)),
        "runtime": RUNTIME, "warmup_n": warmup_count(n),
    })


async def run_connections(host: str, port: int, n: int) -> None:
    warm_conns = []
    for _ in range(min(n, 5)):
        c = await connect(tcp_locator(host, port))
        await c.fetch("root")
        warm_conns.append(c)
    gc.collect()
    emit({"v": 1, "event": "warmed"})
    sys.stdout.flush()
    await asyncio.sleep(0.6)
    handles = []
    t0 = now()
    for _ in range(n):
        c = await connect(tcp_locator(host, port))
        await c.fetch("root")
        handles.append(c)
    total = now() - t0
    emit({
        "v": 1, "metric": "connections", "client": CLIENT, "suite": "taskboard", "conns": n,
        "total_ms": round(total, 2), "per_conn_ms": round(total / max(1, n), 4), "runtime": RUNTIME,
    })
    sys.stdout.flush()
    await asyncio.sleep(2.5)
    for c in handles:
        await c.close()
    for c in warm_conns:
        await c.close()


async def run_cold(host: str, port: int) -> None:
    conn = await connect(tcp_locator(host, port))
    root = await conn.fetch("root")
    await run_unit(conn, root)
    await conn.close()
    emit({"v": 1, "event": "cold-done", "client": CLIENT})


def counter_behavior():
    # The local-turn counter: `hit` increments and returns the count, any other
    # verb raises. A fresh closure per use, so the two paths of run_local never
    # share a count.
    count = 0

    def counter(verb: str, args: list):
        nonlocal count
        if verb != "hit":
            raise RuntimeError(f"counter: no such method {verb}")
        count += 1
        return count

    return counter


async def measure_hits(conn: Session, target: Ref, n: int) -> list:
    # min(n, 500) warmup hits, a forced collection, then n measured sequential
    # send→settle units, asserting the final count equals warmup + n. Returns
    # the sorted per-turn latencies in nanoseconds.
    warmup = warmup_count(n)
    for _ in range(warmup):
        await conn.send(target, "hit", [])
    gc.collect()
    lats = []
    last = 0
    for _ in range(n):
        s = time.perf_counter_ns()
        last = await conn.send(target, "hit", [])
        lats.append(time.perf_counter_ns() - s)
    if last != warmup + n:
        raise RuntimeError(f"bad final count {last!r} (expected {warmup + n})")
    lats.sort()
    return lats


async def run_local(n: int) -> None:
    # The `local` mode (see contract.md): (a) in_lang — a counter spawned on
    # this connection, dispatched in process by the binding's own local path;
    # (b) via_host — the same behavior published across a loopback pair inside
    # this process (listen on 127.0.0.1:0 + connect to itself), so every turn
    # pays wire codec, feed, trampoline, and marshal both ways. The
    # orchestrator's host/port arguments are unused; the pair is
    # self-contained.
    server = await listen("127.0.0.1", 0)
    accepted: list = []

    async def accept_one() -> None:
        async for conn in server:
            conn.publish("counter", counter_behavior())
            conn.serve()
            accepted.append(conn)
            return

    accept_task = asyncio.ensure_future(accept_one())
    dial = await connect(tcp_locator("127.0.0.1", server.port))

    # (a) in_lang: the binding's in-process actor dispatch.
    local = dial.spawn(counter_behavior())
    in_lang = await measure_hits(dial, local, n)

    # (b) via_host: the published counter across the loopback pair.
    far = await dial.fetch("counter")
    via_host = await measure_hits(dial, far, n)

    await dial.close()
    server.close()
    accept_task.cancel()
    for conn in accepted:
        await conn.close()

    in_mean = sum(in_lang) / max(1, n)
    via_mean = sum(via_host) / max(1, n)
    emit({
        "v": 1, "metric": "local", "client": CLIENT, "suite": "local-turn", "n": n,
        "in_lang_ns": round(in_mean, 1), "in_lang_p99_ns": round(percentile_ms(in_lang, 0.99), 1),
        "via_host_ns": round(via_mean, 1), "via_host_p99_ns": round(percentile_ms(via_host, 0.99), 1),
        "ratio": round(via_mean / in_mean, 2) if in_mean > 0 else 0,
        "runtime": RUNTIME, "warmup_n": warmup_count(n),
    })


async def main() -> None:
    mode, host, port_str = sys.argv[1], sys.argv[2], sys.argv[3]
    port = int(port_str)
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    if mode == "latency":
        await run_latency(host, port, n)
    elif mode == "throughput":
        await run_throughput(host, port, n)
    elif mode == "connections":
        await run_connections(host, port, n)
    elif mode == "cold":
        await run_cold(host, port)
    elif mode == "local":
        await run_local(n)
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    asyncio.run(main())
