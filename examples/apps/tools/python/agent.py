"""An agent, written on pancake actors in native Python. It connects to the tools
coordinator (which may be written in any language) and proves the three
capability properties — delegation, attenuation, revocation — over the wire.

    python3 agent.py 127.0.0.1 9099 py-agent
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[4] / "bindings" / "python"))

from pancake import VowBroken, connect, tcp_locator  # noqa: E402

TOOLS = "tools"
GRANT, GRANT_REVOCABLE, REVOKE_LAST = "grant", "grant-revocable", "revoke-last"
NOW, READ, WRITE = "now", "read", "write"


async def main() -> None:
    if len(sys.argv) < 4:
        print("usage: agent.py <host> <port> <nick>", file=sys.stderr)
        sys.exit(2)
    host, port, nick = sys.argv[1], int(sys.argv[2]), sys.argv[3]

    def check(label: str, ok: bool) -> None:
        print(f"{nick}: {'ok' if ok else 'FAIL'}, {label}")
        if not ok:
            sys.exit(1)

    async def broke(coro) -> bool:
        try:
            await coro
            return False
        except VowBroken:
            return True

    conn = await connect(tcp_locator(host, port))
    conn.serve()
    tools = await conn.fetch(TOOLS)

    # 1. Delegation: get a clock capability and call it.
    clock = await conn.send(tools, GRANT, ["clock"])
    now = await conn.send(clock, NOW)
    check("delegation: was handed a clock and called it", isinstance(now, int))

    # 2. Attenuation: a read-only file capability reads but refuses writes.
    files = await conn.send(tools, GRANT, ["files-readonly"])
    contents = await conn.send(files, READ, ["report.txt"])
    check("attenuation: read through the read-only view", isinstance(contents, str))
    check("attenuation: write is refused", await broke(conn.send(files, WRITE, ["report.txt", "tampered"])))

    # 3. Revocation: a revocable handle works, then breaks after revoke.
    revocable_clock = await conn.send(tools, GRANT_REVOCABLE, ["clock"])
    before = await conn.send(revocable_clock, NOW)
    check("revocation: the handle works before revoke", isinstance(before, int))
    await conn.send(tools, REVOKE_LAST)
    check("revocation: the handle breaks after revoke", await broke(conn.send(revocable_clock, NOW)))

    print(f"{nick}: all capability properties held")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
