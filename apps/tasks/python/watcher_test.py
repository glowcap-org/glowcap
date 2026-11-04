"""Keep Tasks observe/cancel while refusing only the first public poll call."""

import asyncio

from glowcap import RemotePromise
from task_client import TaskBoard


async def watcher_startup(board: TaskBoard) -> None:
    for failure_type, refuse_cleanup in (
        (RuntimeError, False),
        (RuntimeError, True),
        (asyncio.CancelledError, False),
        (asyncio.CancelledError, True),
    ):
        primary = failure_type("injected first poll failure")
        cleanup = RuntimeError("injected cancellation failure")
        original = board._session.send
        first_poll = True
        attempts = 0
        cancelled = None
        server_cancels = []

        async def failed_poll():
            # Directly deliver the exception at the app's await boundary.
            # asyncio Future cancellation can replace CancelledError upstream.
            raise primary

        def send(target, verb, args=None):
            nonlocal first_poll, attempts, cancelled
            if verb == "poll" and first_poll:
                first_poll = False
                return failed_poll()
            if verb == "cancel":
                attempts += 1
                cancelled = target
                if refuse_cleanup:
                    return RemotePromise.failed(cleanup)
                reply = original(target, verb, args)
                server_cancels.append(reply)
                return reply
            return original(target, verb, args)

        board._session.send = send
        try:
            try:
                await board.watch()
            except BaseException as error:
                assert error is primary, "startup replaced its primary failure"
            else:
                raise AssertionError("injected poll refusal was ignored")
        finally:
            board._session.send = original
        assert attempts == 1, "startup did not attempt exactly one cancellation"
        if refuse_cleanup:
            assert primary.__context__ is cleanup, "cleanup refusal was lost"
            assert any("watcher cleanup failed" in note for note in primary.__notes__)
            assert cancelled is not None
            assert await original(cancelled, "cancel", []) is True
        else:
            assert len(server_cancels) == 1 and await server_cancels[0] is True, "the Tasks context was not cancelled"
        next_watcher = await board.watch()
        await next_watcher.stop()
    print("Python: failed watcher startup cancels once and preserves cleanup failures")
