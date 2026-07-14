#!/usr/bin/env python3
"""Headless CapTP rooms bot peer (Python binding).

Joins one room, registers for CapTP DMs over iroh Discovery, and maintains
inbox.jsonl / outbox.jsonl for the wake loop.

Env (required):
  NICK / ROOMS_NICK
  BRIDGE_DIR / ROOMS_DIR
  ROOMS_LOCATOR          ocapn://…, host:port, or http(s)://…/locator bootstrap

Env (optional):
  ROOM / ROOMS_ROOM      default general — stay in this channel
  OUTBOX_POLL_SEC        default 0.25
  RECONNECT_SEC          default 2
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import os
import signal
import sys
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
_REPO = _SCRIPTS.parents[3]
sys.path.insert(0, str(_REPO / "examples" / "apps" / "_demo"))
sys.path.insert(0, str(_REPO / "examples" / "apps" / "rooms" / "python"))
sys.path.insert(0, str(_SCRIPTS))

from lib import (  # noqa: E402
    append_jsonl,
    atomic_write_json,
    atomic_write_text,
    env,
    require_bridge_dir,
    require_nick,
    resolve_locator,
    room_name,
    seed_backlog_replied,
    utc_now,
)
from room_client import DM, DirectMessage, Directory, Room  # noqa: E402
from rooms_cli import enter_or_open  # noqa: E402

from pancake import Host, format_peer_uri  # noqa: E402
from pancake._constants import TRANSPORT_IROH  # noqa: E402
from pancake.iroh import Reachability, listen_iroh  # noqa: E402


def append_inbox(bridge: Path, payload: dict) -> None:
    # fsync: the wake loop must never miss a heard line.
    append_jsonl(bridge / "inbox.jsonl", payload, fsync=True)


def write_state(bridge: Path, patch: dict) -> None:
    path = bridge / "state.json"
    try:
        cur = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(cur, dict):
            cur = {}
    except Exception:
        cur = {}
    cur.update(patch)
    cur["updatedAt"] = utc_now()
    atomic_write_json(path, cur)


def log(bridge: Path, *parts: object) -> None:
    line = f"[{utc_now()}] " + " ".join(str(p) for p in parts)
    print(line, flush=True)
    with (bridge / "bridge.log").open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def load_outbox_offset(bridge: Path) -> int:
    path = bridge / "outbox.offset"
    try:
        return max(0, int(path.read_text(encoding="utf-8").strip()))
    except Exception:
        outbox = bridge / "outbox.jsonl"
        if outbox.exists():
            size = outbox.stat().st_size
            atomic_write_text(path, f"{size}\n")
            return size
        atomic_write_text(path, "0\n")
        return 0


async def drain_outbox(
    directory: Directory,
    room: Room,
    bridge: Path,
    nick: str,
    offset: list[int],
    dm_cache: dict[str, DirectMessage],
) -> None:
    outbox = bridge / "outbox.jsonl"
    if not outbox.exists():
        return
    size = outbox.stat().st_size
    if size <= offset[0]:
        if size < offset[0]:
            offset[0] = 0
            atomic_write_text(bridge / "outbox.offset", "0\n")
        return
    with outbox.open("rb") as f:
        f.seek(offset[0])
        chunk = f.read()
    offset[0] = size
    atomic_write_text(bridge / "outbox.offset", f"{size}\n")

    for raw in chunk.decode("utf-8", "replace").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            j = json.loads(line)
        except Exception:
            # A bare, non-JSON line is a room say — the plain convenience form.
            await room.say(line)
            append_inbox(bridge, {"kind": "sent", "channel": "room", "author": nick, "text": line})
            continue
        if not isinstance(j, dict):
            continue
        text = j.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        text = text.strip()
        channel = (j.get("channel") or "room").lower()

        if channel == "dm":
            peer = (j.get("peer") or "").strip()
            if not peer:
                continue
            key = peer.lower()
            try:
                dm = dm_cache.get(key)
                if dm is None:
                    dm = await DirectMessage.open(directory, peer)
                    dm_cache[key] = dm
                await dm.say(nick, text)
            except Exception as exc:  # noqa: BLE001
                # A failed DM stays private — never downgrade it to a room post.
                log(bridge, "dm-send-failed", peer, exc)
                write_state(bridge, {"lastDmError": f"{peer}: {str(exc)[:180]}"})
                continue
            append_inbox(
                bridge,
                {"kind": "sent", "channel": "dm", "author": nick, "text": text, "peer": peer},
            )
            continue

        await room.say(text)
        append_inbox(bridge, {"kind": "sent", "channel": "room", "author": nick, "text": text})


async def run_dm_endpoint(
    bridge: Path,
    nick: str,
    directory: Directory,
) -> tuple[object, asyncio.Task]:
    """Listen for CapTP DMs (iroh Discovery) and register with the directory."""
    seed = os.urandom(32)
    host = Host(seed=seed)

    def dm_behavior(verb: str, args: list):
        if verb != DM:
            raise ValueError(f"dm has no method {verb!r}")
        frm = args[0] if args and isinstance(args[0], str) else "?"
        text = args[1] if len(args) > 1 and isinstance(args[1], str) else ""
        if not text:
            return None
        append_inbox(
            bridge,
            {"kind": "msg", "channel": "dm", "author": frm, "text": text, "peer": frm},
        )
        log(bridge, "dm", frm, text[:160])
        return None

    host.publish_giftable("dm", dm_behavior)
    server = listen_iroh(Reachability.DISCOVERY, seed, host)
    # Id-only URI so partners resolve via Discovery (matches rooms deploy).
    locator = format_peer_uri(TRANSPORT_IROH, server.node_id)

    async def accept_loop() -> None:
        try:
            async for conn in server:
                asyncio.create_task(_serve_conn(conn))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log(bridge, "dm-accept-error", exc)

    async def _serve_conn(conn) -> None:
        try:
            await conn.serve()
        except Exception:
            pass

    task = asyncio.create_task(accept_loop())
    await directory.register(nick, locator)
    log(bridge, "dm-registered", locator)
    write_state(bridge, {"dm": locator, "dmStatus": "registered"})
    return server, task


async def session(
    nick: str,
    bridge: Path,
    room_label: str,
    locator: str,
    locator_raw: str,
    poll_sec: float,
) -> None:
    directory = await Directory.connect(locator)
    room_ref = await enter_or_open(directory, room_label)
    room = await Room.subscribe(directory.conn, room_ref, nick)
    append_inbox(
        bridge,
        {
            "kind": "system",
            "text": f"Joined #{room_label} as {nick} via CapTP ({locator})",
        },
    )

    dm_server = None
    dm_task = None
    try:
        dm_server, dm_task = await run_dm_endpoint(bridge, nick, directory)
    except Exception as exc:  # noqa: BLE001
        log(bridge, "dm-register-failed", exc)
        write_state(bridge, {"dmStatus": "failed", "dmError": str(exc)[:240]})

    write_state(
        bridge,
        {
            "status": "joined",
            "nick": nick,
            "room": room_label,
            "bootstrap": locator_raw,
            "locator": locator,
            "error": None,
        },
    )
    log(bridge, "joined", f"#{room_label}", "as", nick)

    out_offset = [load_outbox_offset(bridge)]
    dm_cache: dict[str, DirectMessage] = {}

    async def outbox_loop() -> None:
        while True:
            try:
                await drain_outbox(directory, room, bridge, nick, out_offset, dm_cache)
            except Exception as exc:  # noqa: BLE001
                log(bridge, "outbox-error", exc)
                write_state(bridge, {"status": "outbox-error", "error": str(exc)[:240]})
                raise
            await asyncio.sleep(poll_sec)

    outbox_task = asyncio.create_task(outbox_loop())
    try:
        async for message in room:
            if message.system:
                payload: dict = {"kind": "system", "author": "room", "text": message.text}
                if message.presence is not None:
                    payload["presence"] = {
                        "kind": message.presence.kind,
                        "names": list(message.presence.names),
                    }
                append_inbox(bridge, payload)
                continue
            if message.sender.lower() == nick.lower():
                continue
            append_inbox(
                bridge,
                {"kind": "msg", "channel": "room", "author": message.sender, "text": message.text},
            )
            log(bridge, "inbox", "#" + room_label, message.sender, message.text[:160])
    finally:
        outbox_task.cancel()
        if dm_task is not None:
            dm_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await outbox_task
        if dm_task is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await dm_task
        if dm_server is not None:
            with contextlib.suppress(Exception):
                await dm_server.close()
        with contextlib.suppress(Exception):
            await room.leave()


async def run() -> None:
    nick = require_nick()
    bridge = require_bridge_dir()
    room_label = room_name()
    locator_raw = env("ROOMS_LOCATOR")
    if not locator_raw:
        print(
            "rooms-bot peer: set ROOMS_LOCATOR (ocapn://…, host:port, or http://…/locator)",
            file=sys.stderr,
        )
        sys.exit(2)
    poll_sec = float(env("OUTBOX_POLL_SEC") or "0.25")
    reconnect_sec = float(env("RECONNECT_SEC") or "2")

    os.environ.setdefault("ROOMS_DIR", str(bridge))
    os.environ.setdefault("BRIDGE_DIR", str(bridge))
    os.environ.setdefault("ROOMS_NICK", nick)
    os.environ.setdefault("NICK", nick)
    os.environ.setdefault("ROOMS_ROOM", room_label)
    os.environ.setdefault("ROOM", room_label)

    for name in ("inbox.jsonl", "outbox.jsonl", "bridge.log"):
        path = bridge / name
        if not path.exists():
            atomic_write_text(path, "")
    if not (bridge / "replied.json").exists():
        atomic_write_json(bridge / "replied.json", [])
    if not (bridge / "pending.json").exists():
        atomic_write_json(bridge / "pending.json", [])

    # Once at process start; reconnects inside this process do not re-seed.
    seeded = seed_backlog_replied(bridge, nick, room_label)
    if seeded:
        log(bridge, "seeded backlog", seeded, "line(s) as already-handled")

    atomic_write_text(bridge / "bridge.pid", f"{os.getpid()}\n")

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _request_stop() -> None:
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _request_stop)
        except NotImplementedError:
            pass

    backoff = reconnect_sec
    while not stop.is_set():
        try:
            locator = resolve_locator(locator_raw)
            os.environ["ROOMS_LOCATOR"] = locator
            write_state(
                bridge,
                {
                    "status": "starting",
                    "nick": nick,
                    "room": room_label,
                    "bootstrap": locator_raw,
                    "locator": locator,
                },
            )
            log(bridge, "peer starting", nick, room_label, locator_raw, "→", locator)
            session_task = asyncio.create_task(
                session(nick, bridge, room_label, locator, locator_raw, poll_sec)
            )
            stop_task = asyncio.create_task(stop.wait())
            done, pending = await asyncio.wait(
                {session_task, stop_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for t in pending:
                t.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await t
            if stop.is_set():
                break
            if session_task in done:
                exc = session_task.exception()
                if exc is not None:
                    raise exc
            write_state(bridge, {"status": "reconnecting"})
            log(bridge, "session ended; reconnecting in", backoff, "s")
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            write_state(bridge, {"status": "reconnecting", "error": msg[:240]})
            if "nick-taken" in msg.lower() or "already claimed" in msg.lower():
                backoff = max(backoff, 8.0)
            log(bridge, "session error; reconnecting in", backoff, "s:", exc)
        try:
            await asyncio.wait_for(stop.wait(), timeout=backoff)
            break
        except asyncio.TimeoutError:
            pass
        backoff = min(30.0, backoff * 1.5)

    write_state(bridge, {"status": "closed"})
    log(bridge, "peer stopped")


def main() -> int:
    try:
        asyncio.run(run())
        return 0
    except KeyboardInterrupt:
        try:
            bridge = require_bridge_dir()
            write_state(bridge, {"status": "closed"})
            log(bridge, "peer stopped")
        except Exception:
            pass
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
