"""Black-box test for tools/run-with-timeout.py.

The wrapper bounds every CI gate, and ci/gates.py branches on the codes it
returns (ci/gates_test.py holds that half), so the contract is its observable
behaviour: the exit code a caller sees, the signal the child receives, the text
on stderr, and whether anything survives the wrapper. A source-string check
cannot see any of that.

Each test starts the wrapper as a separate process and runs small
`python -c` programs as the child. Deadlines are fractions of a second, and
every wait is bounded.

Run it with `python3 tools/run_with_timeout_test.py`. The build registers it as
the `timeout-runner-test` step in tools/build/infrastructure.zig under a 30
second process deadline. It needs python3 only and keeps to options that macOS
and Linux share.
"""

from __future__ import annotations

import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

WRAPPER = pathlib.Path(__file__).resolve().parent / "run-with-timeout.py"
WAIT = 20  # seconds a test waits for any one process before failing


def wrapper_command(*args: str) -> list[str]:
    return [sys.executable, str(WRAPPER), *args]


def child(code: str, *args: str) -> list[str]:
    """A child command: a Python program with optional arguments."""
    return [sys.executable, "-c", code, *args]


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_for_file(path: pathlib.Path, seconds: float = 5) -> None:
    end = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() >= end:
            raise AssertionError(f"{path.name} never appeared")
        time.sleep(0.01)


class RunWithTimeoutTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = pathlib.Path(scratch.name)
        self.started: list[subprocess.Popen[str]] = []
        self.addCleanup(self.stop_started)

    def stop_started(self) -> None:
        """Relay SIGTERM to any wrapper a failed test left running; the
        wrapper then stops its own child."""
        for process in self.started:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

    def start(self, *args: str, merge: bool = False) -> subprocess.Popen[str]:
        process = subprocess.Popen(
            wrapper_command(*args),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge else subprocess.PIPE,
            text=True,
        )
        self.started.append(process)
        return process

    def run_wrapper(self, *args: str, merge: bool = False) -> subprocess.CompletedProcess[str]:
        """Run the wrapper to completion. With `merge`, stderr arrives in
        stdout in the order it was written."""
        process = self.start(*args, merge=merge)
        stdout, stderr = process.communicate(timeout=WAIT)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def code(self, *args: str) -> int:
        return self.run_wrapper(*args).returncode

    def count_lines(self, path: pathlib.Path) -> int:
        return len(path.read_text().splitlines())

    # Exit codes.

    def test_a_clean_exit_reports_0(self) -> None:
        self.assertEqual(self.code("5s", *child("pass")), 0)

    def test_a_child_exit_code_passes_through(self) -> None:
        self.assertEqual(self.code("5s", *child("raise SystemExit(3)")), 3)

    def test_a_child_killed_by_a_signal_reports_128_plus_the_signal(self) -> None:
        kill_self = "import os, signal; os.kill(os.getpid(), signal.SIGKILL)"
        self.assertEqual(self.code("5s", *child(kill_self)), 137)

    def test_a_missing_command_reports_127(self) -> None:
        # An absolute path, not a bare name: a PATH search can report EACCES
        # from an unreadable PATH component and turn "no such command" into 126.
        missing = self.scratch / "definitely-not-a-command"
        self.assertEqual(self.code("5s", str(missing)), 127)

    def test_a_command_that_is_not_executable_reports_126(self) -> None:
        plain = self.scratch / "noexec"
        plain.write_text("x")
        plain.chmod(0o644)
        self.assertEqual(self.code("5s", str(plain)), 126)

    def test_an_infinite_deadline_is_invalid(self) -> None:
        self.assertEqual(self.code("inf", *child("pass")), 2)

    def test_a_not_a_number_deadline_is_invalid(self) -> None:
        self.assertEqual(self.code("nan", *child("pass")), 2)

    def test_automatic_deadline_retries_are_unavailable(self) -> None:
        self.assertEqual(self.code("--deadline-retries", "1", "5s", *child("pass")), 2)

    # Deadlines.

    def test_a_timed_out_child_reports_124(self) -> None:
        sleeper = child("import time; time.sleep(30)")
        self.assertEqual(self.code("--kill-after", "0.5s", "0.5s", *sleeper), 124)

    def test_a_child_ignoring_sigterm_is_still_bounded(self) -> None:
        stubborn = child("import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)")
        self.assertEqual(self.code("--kill-after", "0.5s", "0.8s", *stubborn), 124)

    def test_a_fired_deadline_names_itself_on_stderr(self) -> None:
        sleeper = child("import time; time.sleep(30)")
        result = self.run_wrapper("--kill-after", "0.5s", "0.5s", *sleeper)
        self.assertEqual(result.returncode, 124)
        self.assertIn("0.5s deadline", result.stderr)

    def test_a_heartbeat_reports_activity_without_extending_the_deadline(self) -> None:
        sleeper = child("import time; time.sleep(30)")
        result = self.run_wrapper("--heartbeat", "0.02s", "--kill-after", "0.1s", "0.15s", *sleeper, merge=True)
        self.assertEqual(result.returncode, 124)
        self.assertIn("still running", result.stdout)
        self.assertIn("deadline and was stopped", result.stdout)

    def test_a_heartbeat_preserves_the_child_failure(self) -> None:
        failing = child("import time; time.sleep(0.05); raise SystemExit(3)")
        self.assertEqual(self.code("--heartbeat", "0.01s", "5s", *failing), 3)

    # A failure is final.

    def test_a_deadline_failure_is_final(self) -> None:
        # A child that would pass on its next invocation must still fail this
        # check, and the marker proves nothing reran it.
        marker = self.scratch / "retry-count"
        counting = child(
            "import sys, time\n"
            "path = sys.argv[1]\n"
            "open(path, 'a').write('run\\n')\n"
            "if len(open(path).read().splitlines()) > 1:\n"
            "    raise SystemExit(0)\n"
            "time.sleep(30)\n",
            str(marker),
        )
        self.assertEqual(self.code("--kill-after", "0.5s", "0.8s", *counting), 124)
        self.assertEqual(self.count_lines(marker), 1)

    def test_an_ordinary_failure_is_final(self) -> None:
        marker = self.scratch / "retry-count"
        failing = child("import sys; open(sys.argv[1], 'a').write('run\\n'); raise SystemExit(3)", str(marker))
        self.assertEqual(self.code("5s", *failing), 3)
        self.assertEqual(self.count_lines(marker), 1)

    # Stderr reports.

    def test_a_pass_over_half_its_deadline_warns(self) -> None:
        slow = child("import time; time.sleep(0.9)")
        result = self.run_wrapper("--quiet-success", "1.5s", *slow, merge=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("of its 1.5s deadline", result.stdout)

    def test_a_pass_with_headroom_stays_quiet(self) -> None:
        result = self.run_wrapper("--quiet-success", "5s", *child("pass"), merge=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_quiet_success_suppresses_child_output(self) -> None:
        noisy = child("import sys; print('hidden-out'); print('hidden-error', file=sys.stderr)")
        result = self.run_wrapper("--quiet-success", "5s", *noisy, merge=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_quiet_failure_replays_combined_child_output(self) -> None:
        noisy = child(
            "import sys; print('replayed-out'); print('replayed-error', file=sys.stderr); raise SystemExit(9)"
        )
        result = self.run_wrapper("--quiet-success", "5s", *noisy, merge=True)
        self.assertEqual(result.returncode, 9)
        self.assertIn("replayed-out", result.stdout)
        self.assertIn("replayed-error", result.stdout)

    # Signals and survivors.

    def test_cancellation_unwinds_wait_lock_and_spawn_unmask_before_reaping(self) -> None:
        self.retirement_probe(("wait", "wait-repeat", "unmask", "dead-denied", "live-denied"))

    def test_deadline_reaps_exited_children_without_hiding_live_signal_denial(self) -> None:
        self.retirement_probe(("deadline-dead-denied", "deadline-live-denied"))

    def test_final_kill_reaps_exited_children_without_hiding_live_signal_denial(self) -> None:
        self.retirement_probe(("kill-dead-denied", "kill-live-denied"))

    def test_late_signal_denial_remains_owned_until_group_retirement(self) -> None:
        self.retirement_probe(("late-denied",))

    def retirement_probe(self, modes: tuple[str, ...]) -> None:
        # CPython can run a signal handler inside Popen.wait's non-reentrant
        # waitpid lock. Inject that interleaving without depending on timing.
        probe = self.scratch / "wait_lock.py"
        pidfile = self.scratch / "child.pid"
        probe.write_text(
            "import os, pathlib, runpy, signal, subprocess, sys, time\n"
            "wrapper, marker, mode = sys.argv[1:]\n"
            "original = subprocess.Popen.wait\n"
            "original_init = subprocess.Popen.__init__\n"
            "original_mask = signal.pthread_sigmask\n"
            "original_killpg = os.killpg\n"
            "owner = os.getpid()\n"
            "unmask_pending = True\n"
            "def started(self, *args, **kwargs):\n"
            "    original_init(self, *args, **kwargs)\n"
            "    pathlib.Path(marker).write_text(str(self.pid))\n"
            "def unmask(how, signals):\n"
            "    global unmask_pending\n"
            "    if mode == 'unmask' and os.getpid() == owner and how == signal.SIG_UNBLOCK and unmask_pending:\n"
            "        unmask_pending = False\n"
            "        os.kill(owner, signal.SIGTERM)\n"
            "    return original_mask(how, signals)\n"
            # Darwin discards default SIGCHLD before sigwait can observe it.
            # A handler preserves the notification without reaping the child.
            "def terminate_without_reaping(process):\n"
            "    signal.signal(signal.SIGCHLD, lambda *_: None)\n"
            "    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD})\n"
            "    print('waiting for unreaped child exit', flush=True)\n"
            "    original_killpg(process.pid, signal.SIGTERM)\n"
            "    signal.sigwait({signal.SIGCHLD})\n"
            "    print('observed unreaped child exit', flush=True)\n"
            "calls = 0\n"
            "def interrupted_wait(self, *args, **kwargs):\n"
            "    global calls\n"
            "    calls += 1\n"
            "    if mode.startswith('kill-') and calls <= 2:\n"
            "        if calls == 2 and mode == 'kill-dead-denied':\n"
            "            terminate_without_reaping(self)\n"
            "        raise subprocess.TimeoutExpired(self.args, 0)\n"
            "    if calls == 1 and mode.startswith('deadline-'):\n"
            "        if mode == 'deadline-dead-denied':\n"
            "            terminate_without_reaping(self)\n"
            "        raise subprocess.TimeoutExpired(self.args, 0)\n"
            "    if calls == 1 and mode != 'unmask':\n"
            "        if mode == 'late-denied':\n"
            "            while not pathlib.Path(marker + '.descendant').exists():\n"
            "                time.sleep(0.001)\n"
            "        with self._waitpid_lock:\n"
            "            os.kill(os.getpid(), signal.SIGTERM)\n"
            "    elif calls == 2 and mode in ('wait-repeat', 'dead-denied', 'late-denied'):\n"
            "        if mode == 'dead-denied':\n"
            "            original(self, timeout=1)\n"
            "        os.kill(os.getpid(), signal.SIGINT)\n"
            "    return original(self, *args, **kwargs)\n"
            "def killpg(pid, sig):\n"
            # Model a child that survives TERM, then a denied final KILL.
            "    if mode.startswith('kill-') and sig == signal.SIGTERM:\n"
            "        return\n"
            "    if mode.startswith('kill-') and sig == signal.SIGKILL:\n"
            "        raise PermissionError('injected final signal denial')\n"
            "    if (mode in ('dead-denied', 'late-denied') and sig == signal.SIGINT) or mode == 'live-denied' or (mode.startswith('deadline-') and sig == signal.SIGTERM):\n"
            "        raise PermissionError('injected signal denial')\n"
            "    return original_killpg(pid, sig)\n"
            "subprocess.Popen.wait = interrupted_wait\n"
            "subprocess.Popen.__init__ = started\n"
            "signal.pthread_sigmask = unmask\n"
            "os.killpg = killpg\n"
            "timeout = '0s' if mode.startswith(('deadline-', 'kill-')) else '10s'\n"
            "grace = '0s' if mode.startswith('kill-') else '0.1s'\n"
            "victim = 'import time; time.sleep(10)'\n"
            "if mode == 'late-denied':\n"
            "    descendant = 'import os, pathlib, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(10)'\n"
            "    victim = 'import subprocess, sys, time; subprocess.Popen([sys.executable, \"-c\", sys.argv[1], sys.argv[2]]); time.sleep(10)'\n"
            "    sys.argv = [wrapper, timeout, sys.executable, '-c', victim, descendant, marker + '.descendant']\n"
            "else:\n"
            "    sys.argv = [wrapper, '--kill-after', grace, timeout, sys.executable, '-c', victim]\n"
            "runpy.run_path(wrapper, run_name='__main__')\n"
        )
        for mode in modes:
            logfile = self.scratch / f"{mode}.log"
            with self.subTest(retirement=mode), logfile.open("w") as output:
                wrapper = subprocess.Popen(
                    [sys.executable, str(probe), str(WRAPPER), str(pidfile), mode],
                    stdout=output,
                    stderr=subprocess.STDOUT,
                )
                try:
                    if mode.endswith("live-denied") or mode == "late-denied":
                        expected = 1
                    elif mode.startswith(("deadline-", "kill-")):
                        expected = 124
                    else:
                        expected = 128 + signal.SIGTERM
                    try:
                        status = wrapper.wait(timeout=2)
                    except subprocess.TimeoutExpired as error:
                        error.add_note(f"{mode} probe output:\n{logfile.read_text()}")
                        raise
                    self.assertEqual(status, expected, logfile.read_text())
                    if mode in ("deadline-dead-denied", "kill-dead-denied"):
                        self.assertIn("observed unreaped child exit", logfile.read_text())
                    if mode.endswith("live-denied") or mode == "late-denied":
                        self.assertIn("PermissionError", logfile.read_text())
                    else:
                        self.assertFalse(process_exists(int(pidfile.read_text())), "retired child survived")
                    if mode == "late-denied":
                        descendant = int(pathlib.Path(str(pidfile) + ".descendant").read_text())
                        self.assertTrue(process_exists(descendant), "late denial did not leave a surviving group")
                finally:
                    if wrapper.poll() is None:
                        wrapper.kill()
                        wrapper.wait()
                    if pidfile.exists():
                        pid = int(pidfile.read_text())
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        pidfile.unlink()

    def test_the_child_receives_the_signal_that_arrived_not_a_substitute(self) -> None:
        # The victim records the signal number it actually received. It writes
        # a ready file once its handler is installed, so the signal cannot
        # arrive early.
        saw = self.scratch / "signal"
        ready = self.scratch / "ready"
        victim = child(
            "import pathlib, signal, sys, time\n"
            "saw, ready = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])\n"
            "def seen(sig, _frame):\n"
            "    saw.write_text(str(sig))\n"
            "    sys.exit(42)\n"
            "signal.signal(signal.SIGINT, seen)\n"
            "ready.write_text('ready')\n"
            "time.sleep(10)\n",
            str(saw),
            str(ready),
        )
        wrapper = self.start("20s", *victim)
        wait_for_file(ready)
        wrapper.send_signal(signal.SIGINT)
        wrapper.communicate(timeout=WAIT)
        self.assertEqual(saw.read_text(), str(int(signal.SIGINT)))

    def test_no_child_outlives_the_wrapper(self) -> None:
        # The child writes its pid, then sleeps past the deadline. After the
        # wrapper returns, that pid must be gone.
        pidfile = self.scratch / "pid"
        sleeper = child(
            "import os, pathlib, sys, time\npathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\ntime.sleep(30)\n",
            str(pidfile),
        )
        self.run_wrapper("--kill-after", "0.5s", "1s", *sleeper)
        self.assertTrue(pidfile.exists(), "child never recorded its pid")
        pid = int(pidfile.read_text())
        survived = process_exists(pid)
        if survived:
            os.kill(pid, signal.SIGKILL)
        self.assertFalse(survived, f"child {pid} outlived the wrapper")

    def test_deadline_and_cancellation_stop_descendants_after_their_leader_exits(self) -> None:
        # A leader exiting on TERM must not hide a descendant that ignores it.
        for mode, deadline, expected in (("deadline", "2s", 124), ("cancel", "20s", 143)):
            with self.subTest(mode=mode):
                self.stop_descendant_after_leader_exits(mode, deadline, expected)

    def stop_descendant_after_leader_exits(self, mode: str, deadline: str, expected: int) -> None:
        marker = self.scratch / ("descendant-" + mode)
        descendant_code = (
            "import os, pathlib, signal, sys, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "marker = pathlib.Path(sys.argv[1])\n"
            "staged = marker.with_suffix('.ready')\n"
            "staged.write_text(str(os.getpid()))\n"
            "staged.replace(marker)\n"
            "time.sleep(30)\n"
        )
        leader_code = (
            "import subprocess, sys, time\n"
            "subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]])\n"
            "time.sleep(30)\n"
        )
        wrapper = self.start("--kill-after", "0.2s", deadline, *child(leader_code, descendant_code, str(marker)))
        descendant = None
        try:
            wait_for_file(marker)
            descendant = int(marker.read_text())
            if mode == "cancel":
                wrapper.send_signal(signal.SIGTERM)
            wrapper.communicate(timeout=WAIT)
            self.assertEqual(wrapper.returncode, expected)
            # An orphan is reaped by init, so allow that observation to catch up.
            reaped = time.monotonic() + 2
            while process_exists(descendant):
                self.assertLess(time.monotonic(), reaped, f"descendant survived {mode}")
                time.sleep(0.01)
        finally:
            if descendant is not None and process_exists(descendant):
                os.kill(descendant, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
