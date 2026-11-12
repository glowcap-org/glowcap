"""Exercise overlapping application mutations against the real Tasks server."""

import asyncio
import sys

from task_client import TaskBoard
from watcher_test import watcher_startup


async def run() -> None:
    board = await TaskBoard.join(sys.argv[1], sys.argv[2])
    try:
        before = len((await board.lists())[0].tasks)
        await asyncio.gather(board.add("python same"), board.add("python same"))
        assert len((await board.lists())[0].tasks) == before + 2, "identical adds collapsed into one receipt"
        await asyncio.gather(board.add("python left"), board.add("python right"))
        assert len((await board.lists())[0].tasks) == before + 4
        refused, resumed = await asyncio.gather(
            board.add("x" * 4097), board.add("python after refusal"), return_exceptions=True
        )
        assert isinstance(refused, Exception), "oversized task was admitted"
        assert not isinstance(resumed, BaseException), "mutation lock stayed refused"
        leader = asyncio.create_task(board.add("python cancellation leader"))
        cancelled = asyncio.create_task(board.add("python cancelled waiter"))
        await asyncio.sleep(0)
        cancelled.cancel()
        try:
            await cancelled
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("queued caller did not cancel")
        await leader
        await asyncio.gather(board.add("python after cancellation"), board.lists())
        tasks = (await board.lists())[0].tasks
        assert len(tasks) == before + 7
        assert "python cancelled waiter" not in tasks
        # Delay only observation, after the real Session has synchronously
        # issued the selected verb. Cancellation never retracts that send.
        original_send = board._session.send
        for phase in ("mutation-sequence", "mutate"):
            issued = asyncio.Event()
            parked = asyncio.Event()

            def delayed_send(target, verb, args=None):
                reply = original_send(target, verb, args)
                if verb != phase:
                    return reply

                async def observe():
                    issued.set()
                    await parked.wait()
                    return await reply

                return observe()

            board._session.send = delayed_send
            operation = asyncio.create_task(board.add("python cancelled " + phase))
            await issued.wait()
            operation.cancel()
            try:
                await operation
            except asyncio.CancelledError:
                pass
            else:
                raise AssertionError("active caller did not cancel")
            finally:
                board._session.send = original_send
            await board.add("python cancelled " + phase)
        tasks = (await board.lists())[0].tasks
        assert tasks.count("python cancelled mutation-sequence") == 1
        assert tasks.count("python cancelled mutate") == 2, "next query reused an admitted mutation's sequence"
        assert len(tasks) == before + 10
        await watcher_startup(board)
        print("Python: identical/distinct actions, refusal/cancellation recovery, and parallel reads passed")
    finally:
        await board.leave()


asyncio.run(run())
