"""One-shot tasks client for the cross-language demo: connect, add a task,
list, mark it done, list again, and exit.

    python3 client.py 127.0.0.1 9099 py-grace "buy groceries"
"""

from __future__ import annotations

import asyncio
import sys

from task_client import TaskBoard


async def main() -> None:
    if len(sys.argv) < 5:
        print("usage: client.py <host> <port> <nick> <task-text>", file=sys.stderr)
        sys.exit(2)

    host, port_str, nick, task_text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    board = await TaskBoard.join(host, int(port_str))

    task_id = await board.add(f"[{nick}] {task_text}")
    print(f"{nick}: added task #{task_id}")

    before = await board.list()
    print(f"{nick}: {len(before)} task(s) on the board")
    for t in before:
        mark = "[x]" if t.completed else "[ ]"
        print(f"  {mark} #{t.id} {t.text}")

    await board.done(task_id)
    print(f"{nick}: completed task #{task_id}")

    after = await board.list()
    ours = next((t for t in after if t.id == task_id), None)
    if not ours or not ours.completed:
        print(f"{nick}: FAIL, task #{task_id} not marked completed", file=sys.stderr)
        await board.leave()
        sys.exit(1)

    print(f"{nick}: confirmed task #{task_id} is done")
    await board.leave()


if __name__ == "__main__":
    asyncio.run(main())
