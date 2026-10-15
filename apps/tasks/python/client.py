"""One-shot tasks client for the cross-language demo: join the board and watch
it, add a task, mark it done, print both lists, and exit 0 once the task shows
up under "Done" and the watcher saw the board change.

    python3 client.py 127.0.0.1 9099 <board-name> py-grace "buy groceries"
"""

from __future__ import annotations

import asyncio
import sys

from task_client import TaskBoard


async def main() -> None:
    if len(sys.argv) < 6:
        print("usage: client.py <host> <port> <board-name> <nick> <task-text>", file=sys.stderr)
        sys.exit(2)

    host, port_str, name, nick, task_text = sys.argv[1:6]
    board = await TaskBoard.join(host, int(port_str), name)
    text = f"[{nick}] {task_text}"

    watcher = await board.watch()
    task = await board.add(text)
    print(f"{nick}: added a task")
    await board.done(task)
    print(f"{nick}: marked it done")

    lists = await board.lists()
    for lst in lists:
        print(f"{nick}: {lst.name}: {len(lst.tasks)} task(s)")
        for task in lst.tasks:
            print(f"  {task}")
    watched = await watcher.changed()
    await watcher.stop()
    await board.leave()

    if text not in lists[1].tasks:
        print(f"{nick}: FAIL, the task is not in the done list", file=sys.stderr)
        sys.exit(1)
    print(f"{nick}: confirmed the task is done")
    if not watched:
        print(f"{nick}: FAIL, the watcher saw no change", file=sys.stderr)
        sys.exit(1)
    print(f"{nick}: the watcher saw the board change")


if __name__ == "__main__":
    asyncio.run(main())
