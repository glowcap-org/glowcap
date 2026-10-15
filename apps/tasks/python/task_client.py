"""A small client for the tasks board, built on glowcap actors.

The board is a secret-named capability with two lists, "To do" first and
"Done" second. Every change is a receipt-backed call: ask the target for a
fresh `mutation-sequence`, then `mutate` with that number, so a retried change
applies once. Adding a task returns the task, and `done` moves that task. A
watcher reports whether anything on the board changed since its last look, and `stop` frees the board's observation context.

    board = await TaskBoard.join("127.0.0.1", 9099, board_name)
    watcher = await board.watch()
    task = await board.add("buy groceries")
    await board.done(task)
    print(await board.lists(), await watcher.changed())
    await watcher.stop()
    await board.leave()
"""

from __future__ import annotations

import asyncio
import pathlib
import sys
from dataclasses import dataclass
from typing import Any, List

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path()

from glowcap import Ref, Runtime, Session, Tagged, tcp  # noqa: E402


@dataclass
class TaskList:
    name: str
    tasks: List[str]


class Task:
    """A task on the board, named by its capability."""

    def __init__(self, ref: Ref) -> None:
        self.ref = ref


class Watcher:
    """Reports whether the board changed since the last look."""

    def __init__(self, session: Session, receiver: Ref, canceller: Ref) -> None:
        self._session = session
        self._receiver = receiver
        self._canceller = canceller
        self._cursor = b""

    async def _poll(self) -> bool:
        args = [self._cursor] if self._cursor else []
        reply = await self._session.send(self._receiver, "poll", args)
        if not isinstance(reply, Tagged) or len(reply.value) != 5:
            raise RuntimeError("the watcher sent no observation")
        # Loam's `access:observation` record, see docs/loam/access-observation.md:
        # the cursor comes first and the fourth field is whether anything changed.
        cursor, changed = reply.value[0], reply.value[3]
        if not isinstance(cursor, bytes) or not isinstance(changed, bool):
            raise RuntimeError("the watcher sent no observation")
        self._cursor = cursor
        return changed

    async def changed(self) -> bool:
        """Whether anything on the board changed since the previous look."""
        return await self._poll()

    async def stop(self) -> None:
        """Close the board's observation context. Call it once when done watching."""
        closed = await self._session.send(self._canceller, "cancel", [])
        if not isinstance(closed, bool):
            raise RuntimeError("cancelling the watcher returned no boolean")


class TaskBoard:
    """A membership in a task board. Get one with :meth:`join`, drive it with
    :meth:`add`, :meth:`done`, :meth:`watch`, and :meth:`lists`, and :meth:`leave`
    when done."""

    def __init__(self, runtime: Runtime, session: Session, board: Any, todo: Any, done: Any) -> None:
        self._runtime = runtime
        self._session = session
        self._board = board
        self._todo = todo
        self._done = done

    @classmethod
    async def join(cls, host: str, port: int, name: str) -> "TaskBoard":
        runtime = await Runtime.open(provider=tcp.provider())
        try:
            session = await runtime.connect(tcp.locator(host, port))
            session.serve()
            board = await session.fetch(name)
            todo = await session.send(board, "list", [0])
            done = await session.send(board, "list", [1])
            return cls(runtime, session, board, todo, done)
        except BaseException:
            await runtime.close()
            raise

    async def _mutate(self, target: Any, *args: Any) -> Any:
        seq = await self._session.send(target, "mutation-sequence", [])
        return await self._session.send(target, "mutate", [seq, *args])

    @staticmethod
    def _task(value: Any, what: str) -> Task:
        if not isinstance(value, Ref):
            raise RuntimeError(f"{what} was not a task")
        return Task(value)

    async def add(self, text: str) -> Task:
        """Add a task to "To do" and return the new task."""
        return self._task(await self._mutate(self._todo, "add", text), "the added task")

    async def done(self, task: Task) -> None:
        """Move `task` from "To do" to the end of "Done"."""
        await self._mutate(self._todo, "move", task.ref, self._done)

    async def watch(self) -> Watcher:
        """Start watching the board for changes."""
        reply = await self._mutate(self._board, "observe")
        if not isinstance(reply, list) or len(reply) < 2 or not isinstance(reply[0], Ref):
            raise RuntimeError("watching returned no receiver")
        if not isinstance(reply[1], Ref):
            raise RuntimeError("watching returned no canceller")
        watcher = Watcher(self._session, reply[0], reply[1])
        await watcher._poll()
        return watcher

    async def lists(self) -> List[TaskList]:
        """Read both lists, "To do" first."""
        return [await self._read(self._todo), await self._read(self._done)]

    async def _read(self, lst: Any) -> TaskList:
        send = self._session.send
        name = await send(lst, "name", [])
        count = await send(lst, "count", [])
        tasks = []
        for i in range(count):
            task = await send(lst, "task", [i])
            tasks.append(await send(task, "text", []))
        return TaskList(name=name, tasks=tasks)

    async def leave(self) -> None:
        try:
            await self._session.close()
        finally:
            await self._runtime.close()
