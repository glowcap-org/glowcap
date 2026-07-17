"""A small, friendly client for the tasks board, built on pancake actors.

On the connection API this is barely a layer: connect, fetch the board by
name, publish a watcher the board can call back, and surface its updates as a
stream.

    board = await TaskBoard.join("127.0.0.1", 9099)
    task_id = await board.add("buy groceries")
    await board.done(task_id)
    async for tasks in board:
        for t in tasks: print(t)
    await board.leave()
"""

from __future__ import annotations

import asyncio
import pathlib
import sys
from dataclasses import dataclass
from typing import List

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_demo"))
from python_path import add_bindings_path  # noqa: E402

add_bindings_path(from_file=__file__, depth=4)

from pancake import Session, connect, tcp_locator  # noqa: E402

BOARD = "board"
ADD, DONE, LIST, WATCH, UPDATE = "add", "done", "list", "watch", "update"


@dataclass
class Task:
    id: int
    text: str
    completed: bool


def _parse_snapshot(raw) -> List[Task]:
    if not isinstance(raw, list):
        return []
    tasks = []
    for entry in raw:
        if not isinstance(entry, list) or len(entry) < 3:
            continue
        tasks.append(Task(id=int(entry[0]), text=str(entry[1]), completed=bool(entry[2])))
    return tasks


class TaskBoard:
    """A membership in a task board. Get one with :meth:`join`, iterate it for the
    snapshots the board pushes, :meth:`add`/:meth:`done`/:meth:`list` to drive it,
    and :meth:`leave` when done."""

    def __init__(self, session: Session, board) -> None:
        self._session = session
        self._board = board
        self._snapshots: asyncio.Queue = asyncio.Queue()
        self._leaving = False

    @classmethod
    async def join(cls, host: str, port: int) -> "TaskBoard":
        session = await connect(tcp_locator(host, port))
        session.serve()
        board = await session.fetch(BOARD)
        self = cls(session, board)
        watcher = session.spawn(self._watcher)
        asyncio.ensure_future(self._until_closed())
        await session.send(board, WATCH, [watcher])
        return self

    async def add(self, text: str) -> int:
        result = await self._session.send(self._board, ADD, [text])
        return int(result) if isinstance(result, int) else 0

    async def done(self, task_id: int) -> None:
        await self._session.send(self._board, DONE, [task_id])

    async def list(self) -> List[Task]:
        return _parse_snapshot(await self._session.send(self._board, LIST, []))

    async def leave(self) -> None:
        self._leaving = True
        await self._session.close()

    def __aiter__(self):
        return self._updates()

    async def _updates(self):
        while True:
            snapshot = await self._snapshots.get()
            if snapshot is None:
                return
            yield snapshot

    def _watcher(self, verb: str, args: list):
        if verb != UPDATE:
            raise ValueError(f"watcher has no method {verb!r}")
        self._snapshots.put_nowait(_parse_snapshot(args[0] if args else []))
        return None

    async def _until_closed(self) -> None:
        try:
            await self._session.serve()
        except Exception as err:  # noqa: BLE001
            if not self._leaving:
                print(f"tasks: lost the connection, {err}", file=sys.stderr)
        finally:
            self._snapshots.put_nowait(None)
