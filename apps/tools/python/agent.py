"""An agent, written on glowcap actors in native Python. It connects to the tools
coordinator (which may be written in any language) and proves the three
capability properties — delegation, attenuation, revocation — over the wire.

    python3 agent.py <locator> py-agent

The locator is the ``ocapn://`` URI the coordinator printed.
"""

from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_demo"))
from python_path import add_bindings_path
from tools_check import make_check

add_bindings_path()

from glowcap import Runtime, VowBroken, parse_locator, tcp  # noqa: E402

TOOLS = "tools"
GRANT, GRANT_REVOCABLE, REVOKE_LAST = "grant", "grant-revocable", "revoke-last"
NOW, READ, WRITE = "now", "read", "write"


async def main() -> None:
    if len(sys.argv) < 3:
        print("usage: agent.py <locator> <nick>", file=sys.stderr)
        sys.exit(2)
    locator, nick = sys.argv[1], sys.argv[2]

    check = make_check(nick)

    async def broke(coro) -> bool:
        try:
            await coro
            return False
        except VowBroken:
            return True

    async with Runtime.open(providers=[tcp.provider()]) as runtime:
        session = await runtime.connect(parse_locator(locator))
        session.serve()
        tools = await session.fetch(TOOLS)

        # 1. Delegation: get a clock capability and call it.
        clock = await session.send(tools, GRANT, ["clock"])
        now = await session.send(clock, NOW)
        check("delegation: was handed a clock and called it", isinstance(now, int))

        # 2. Attenuation: a read-only file capability reads but refuses writes.
        files = await session.send(tools, GRANT, ["files-readonly"])
        contents = await session.send(files, READ, ["report.txt"])
        check("attenuation: read through the read-only view", isinstance(contents, str))
        check("attenuation: write is refused", await broke(session.send(files, WRITE, ["report.txt", "tampered"])))

        # 3. Revocation: a revocable handle works, then breaks after revoke.
        revocable_clock = await session.send(tools, GRANT_REVOCABLE, ["clock"])
        before = await session.send(revocable_clock, NOW)
        check("revocation: the handle works before revoke", isinstance(before, int))
        await session.send(tools, REVOKE_LAST)
        check("revocation: the handle breaks after revoke", await broke(session.send(revocable_clock, NOW)))

        print(f"{nick}: all capability properties held")
        await session.close()


if __name__ == "__main__":
    asyncio.run(main())
