#!/usr/bin/env python3
"""Hermetic smoke for rooms-bot scripts. No live rooms peer required.

Exit 0 on success. Prints one ok line per check. Gates the harness contracts
that have no compiler: the message schema, dedup, the backlog seed, and the
wake-token formula.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PY = sys.executable
sys.path.insert(0, str(SCRIPTS))

from lib import pending_fingerprint, poll_pending, seed_backlog_replied, wake_token  # noqa: E402

# The only keys a pending item may carry. A stray conv/convType/className here is
# the DOM-scraping folklore trying to creep back — fail if it does.
ALLOWED_ITEM_KEYS = {"id", "channel", "author", "text", "peer", "mention"}


def run(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, env=env, text=True, capture_output=True, check=False)


def check_peer_roundtrip() -> int:
    """Gate the one thing the hermetic checks can't reach: an outbound line
    round-tripping through peer.drain_outbox, and — the boundary that matters —
    a DM that fails to send staying private instead of leaking into the room.

    peer.py imports the pancake binding, so this needs zig-out/lib. Without it,
    the check is skipped loudly, never silently."""
    import asyncio
    import importlib.util

    try:
        spec = importlib.util.spec_from_file_location("peer", SCRIPTS / "peer.py")
        peer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(peer)
    except Exception as exc:  # noqa: BLE001 — most often: pancake .so not built
        print(f"skip peer round-trip (build zig-out/lib to gate it): {type(exc).__name__}")
        return 0

    class FakeRoom:
        def __init__(self):
            self.said: list[str] = []

        async def say(self, text):
            self.said.append(text)

    def install_dm(ok: bool):
        class _DM:
            @classmethod
            async def open(cls, directory, peer_nick):
                class _Live:
                    async def say(self, frm, text):
                        if not ok:
                            raise RuntimeError("unreachable peer")
                return _Live()

        peer.DirectMessage = _DM

    async def drive(ok_dm: bool):
        tmp = Path(tempfile.mkdtemp(prefix="rooms-bot-drain-"))
        env = {**os.environ, "NICK": "Alice", "BRIDGE_DIR": str(tmp), "ROOM": "general"}
        run([PY, str(SCRIPTS / "reply.py"), "--text", "hi room"], env)
        run([PY, str(SCRIPTS / "reply.py"), "--dm", "Carol", "--text", "secret"], env)
        room = FakeRoom()
        install_dm(ok_dm)
        await peer.drain_outbox(object(), room, tmp, "Alice", [0], {})
        inbox = [json.loads(x) for x in (tmp / "inbox.jsonl").read_text().splitlines() if x.strip()]
        state = json.loads((tmp / "state.json").read_text()) if (tmp / "state.json").exists() else {}
        return room.said, inbox, state

    failures = 0
    said, inbox, _ = asyncio.run(drive(ok_dm=True))
    sent = {(i["channel"], i.get("peer"), i["text"]) for i in inbox if i.get("kind") == "sent"}
    if said == ["hi room"] and ("room", None, "hi room") in sent and ("dm", "Carol", "secret") in sent:
        print("ok peer round-trip: room + dm delivered, echoes carry channel")
    else:
        print(f"FAIL peer round-trip: said={said!r} sent={sent!r}")
        failures += 1

    said, inbox, state = asyncio.run(drive(ok_dm=False))
    leaked = any("secret" in s for s in said) or any(i.get("text") == "secret" for i in inbox)
    if said == ["hi room"] and not leaked and "Carol" in state.get("lastDmError", ""):
        print("ok failed DM stays private (never reposted to the room)")
    else:
        print(f"FAIL privacy: said={said!r} state={state.get('lastDmError')!r}")
        failures += 1

    return failures


def msg(author: str, text: str, channel: str = "room", peer: str = "", ts: str = "") -> str:
    line = {"kind": "msg", "channel": channel, "author": author, "text": text}
    if peer:
        line["peer"] = peer
    if ts:
        line["ts"] = ts
    return json.dumps(line) + "\n"


def main() -> int:
    failures = 0

    # 1) Every script compiles — globbed, so a new script cannot be forgotten.
    for path in sorted(SCRIPTS.glob("*.py")):
        cp = run([PY, "-m", "py_compile", str(path)], os.environ.copy())
        if cp.returncode != 0:
            print(f"FAIL compile {path.name}: {cp.stderr.strip()}")
            failures += 1
        else:
            print(f"ok compile {path.name}")

    # 2) Missing env fails loud (not a hang, not a traceback-only mystery).
    env_clear = {k: v for k, v in os.environ.items()
                 if k not in ("BRIDGE_DIR", "ROOMS_DIR", "NICK", "ROOMS_NICK")}
    cp = run([PY, str(SCRIPTS / "poll_once.py")], env_clear)
    if cp.returncode != 0 and "BRIDGE_DIR" in (cp.stderr or ""):
        print("ok poll_once missing BRIDGE_DIR → non-zero")
    else:
        print(f"FAIL poll_once env: code={cp.returncode} stderr={cp.stderr!r}")
        failures += 1

    # 3) Poll → reply → mark → dedupe, plus schema + fingerprint gates.
    with tempfile.TemporaryDirectory(prefix="rooms-bot-check-") as tmp:
        bridge = Path(tmp)
        (bridge / "inbox.jsonl").write_text(msg("Bob", "hello Alice"), encoding="utf-8")
        env = {**os.environ, "BRIDGE_DIR": tmp, "NICK": "Alice", "ROOM": "general"}

        cp = run([PY, str(SCRIPTS / "poll_once.py")], env)
        if cp.returncode != 0:
            print(f"FAIL poll: {cp.stderr}")
            failures += 1
        else:
            data = json.loads(cp.stdout)
            (bridge / "pending.json").write_text(cp.stdout, encoding="utf-8")
            if len(data) == 1 and data[0].get("author") == "Bob" and data[0].get("channel") == "room":
                print("ok poll sees Bob in the room")
            else:
                print(f"FAIL poll payload: {data!r}")
                failures += 1
            stray = {k for item in data for k in item} - ALLOWED_ITEM_KEYS
            if stray:
                print(f"FAIL item schema carries folklore keys: {stray}")
                failures += 1
            else:
                print("ok item schema is clean (no conv/convType/className)")
            n, fp = pending_fingerprint(data)
            print("ok pending_fingerprint" if n == 1 and fp != "-" else f"FAIL fingerprint: {n} {fp!r}")
            failures += 0 if n == 1 and fp != "-" else 1

        cp = run([PY, str(SCRIPTS / "reply.py"), "--text", "@Bob hi"], env)
        outbox = bridge / "outbox.jsonl"
        room_line = json.loads(outbox.read_text().splitlines()[-1]) if outbox.exists() else {}
        if cp.returncode == 0 and room_line.get("channel") == "room" and "peer" not in room_line:
            print("ok reply room → {channel:room}")
        else:
            print(f"FAIL reply room: {cp.stderr} {room_line!r}")
            failures += 1

        cp = run([PY, str(SCRIPTS / "reply.py"), "--dm", "Carol", "--text", "psst"], env)
        dm_line = json.loads(outbox.read_text().splitlines()[-1])
        if cp.returncode == 0 and dm_line.get("channel") == "dm" and dm_line.get("peer") == "Carol":
            print("ok reply --dm → {channel:dm, peer}")
        else:
            print(f"FAIL reply dm: {cp.stderr} {dm_line!r}")
            failures += 1

        cp = run([PY, str(SCRIPTS / "mark_pending.py")], env)
        pending_now = (bridge / "pending.json").read_text().strip()
        if cp.returncode == 0 and pending_now == "[]" and (bridge / "replied.json").exists():
            print("ok mark_pending clears pending")
        else:
            print(f"FAIL mark: code={cp.returncode} pending={pending_now!r} {cp.stderr}")
            failures += 1

        cp = run([PY, str(SCRIPTS / "poll_once.py")], env)
        if cp.returncode == 0 and json.loads(cp.stdout) == []:
            print("ok poll dedupe after mark")
        else:
            print(f"FAIL dedupe: {cp.stdout!r}")
            failures += 1

    # 4) The same line said twice is two answerable lines, not one (ts in the id).
    with tempfile.TemporaryDirectory(prefix="rooms-bot-twice-") as tmp:
        bridge = Path(tmp)
        (bridge / "replied.json").write_text("[]\n", encoding="utf-8")
        (bridge / "inbox.jsonl").write_text(
            msg("Bob", "hi", ts="2026-07-13T00:00:01Z") + msg("Bob", "hi", ts="2026-07-13T00:00:09Z"),
            encoding="utf-8",
        )
        items = poll_pending(bridge, "Alice", "general")
        if len(items) == 2 and items[0]["id"] != items[1]["id"]:
            print("ok a repeated line is answerable twice")
        else:
            print(f"FAIL repeated line: {items!r}")
            failures += 1

    # 5) Backlog seed: scrollback is silenced on startup; a later line still pends.
    with tempfile.TemporaryDirectory(prefix="rooms-bot-seed-") as tmp:
        bridge = Path(tmp)
        (bridge / "replied.json").write_text("[]\n", encoding="utf-8")
        (bridge / "inbox.jsonl").write_text(msg("Bob", "old line", ts="t1"), encoding="utf-8")
        seeded = seed_backlog_replied(bridge, "Alice", "general")
        after_seed = poll_pending(bridge, "Alice", "general")
        with (bridge / "inbox.jsonl").open("a", encoding="utf-8") as f:
            f.write(msg("Bob", "new line", ts="t2"))
        after_new = poll_pending(bridge, "Alice", "general")
        if seeded == 1 and after_seed == [] and len(after_new) == 1 and after_new[0]["text"] == "new line":
            print("ok backlog seed silences scrollback, keeps new lines")
        else:
            print(f"FAIL seed: seeded={seeded} after_seed={after_seed!r} after_new={after_new!r}")
            failures += 1

    # 6) The wake-token formula is pinned — init and wake_loop derive it from here.
    if wake_token("Alice") == "AGENT_LOOP_TICK_rooms_alice":
        print("ok wake-token formula pinned")
    else:
        print(f"FAIL wake token: {wake_token('Alice')!r}")
        failures += 1

    # 7) The peer round-trip and the privacy boundary (needs the built libs).
    failures += check_peer_roundtrip()

    if failures:
        print(f"rooms-bot check: {failures} failure(s)")
        return 1
    print("rooms-bot check: all ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
