"""Benchmark process ownership and honest failure reporting, under `zig build check`."""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RACKET = shutil.which("racket")
CHILD = r"""
import json, os, signal, sys
from pathlib import Path

with open(os.environ["CALLS"], "a") as calls:
    calls.write(json.dumps({"pid": os.getpid(), "args": sys.argv[1:]}) + "\n")
scenario = os.environ.get("SCENARIO", "failure")
server = Path(sys.argv[2]).name == "server.rkt"
if server:
    # Blocked, so an interrupt sent before sigwait stays pending. A handler
    # with signal.pause() loses one that lands between the two.
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})

    def serve_until_interrupted():
        signal.sigwait({signal.SIGINT})
        sys.exit(0)

    if scenario == "startup-exit":
        print("original startup failure", file=sys.stderr, flush=True)
        sys.exit(7)
    if scenario == "startup-hang":
        print("startup stalled", file=sys.stderr, flush=True)
        serve_until_interrupted()
    if scenario == "stderr-flood":
        print("x" * 131072, file=sys.stderr, flush=True)
    print('{"event":"ready"}', flush=True)
    if scenario == "server-runtime-exit":
        print("original server runtime failure", file=sys.stderr, flush=True)
        sys.exit(7)
    if scenario == "ignore-interrupt":
        # Nothing takes the blocked interrupt, so only a kill ends this.
        signal.pause()
    serve_until_interrupted()
else:
    mode = sys.argv[7]
    if scenario in ("stdout-hang", "connections-hang"):
        print("original stalled client", file=sys.stderr, flush=True)
        if scenario == "stdout-hang":
            os.close(1)
        signal.pause()
    if scenario == "success" or mode != os.environ["FAIL_MODE"] or os.environ["EMIT_METRIC"] == "yes":
        print(json.dumps({"metric": mode, "p50_ms": 1, "p99_ms": 1,
                          "p999_ms": 1, "rps": 1, "per_conn_ms": 1}, separators=(",", ":")))
    print("original client failure", file=sys.stderr, flush=True)
    sys.exit(0 if scenario == "success" else (7 if mode == os.environ["FAIL_MODE"] else 0))
"""


class BenchmarkFailureTest(unittest.TestCase):
    @contextmanager
    def children(self, **settings):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            child = directory / "racket"
            child.write_text(f"#!{sys.executable}\n" + CHILD)
            child.chmod(0o755)
            calls = directory / "calls"
            environment = dict(
                os.environ,
                PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                CALLS=str(calls),
                FAIL_MODE="latency",
                EMIT_METRIC="no",
                **settings,
            )
            try:
                yield calls, environment
            finally:
                # Failed supervision assertions must not leak their own fixtures.
                for call in self.calls(calls):
                    try:
                        os.kill(call["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    @staticmethod
    def calls(path):
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_children_gone(self, calls):
        entries = self.calls(calls)
        self.assertTrue(entries, "fixture did not launch")
        for call in entries:
            with self.assertRaises(ProcessLookupError, msg=f"child {call['pid']} survived"):
                os.kill(call["pid"], 0)

    def run_focused(self, expression, environment):
        program = (
            '(require (submod "bench/goblins/bench.rkt" test-support)) '
            "(parameterize ([child-timeout-seconds 2] [stop-grace-seconds 0.1]) "
            f"{expression})"
        )
        return subprocess.run(
            [RACKET, "-y", "-e", program], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=8
        )

    def test_failed_measurement_stops_without_retry_or_report(self):
        for mode in ("latency", "throughput", "connections"):
            for emit in ("yes", "no"):
                with self.subTest(mode=mode, metric=emit), self.children() as (calls, environment):
                    environment.update(FAIL_MODE=mode, EMIT_METRIC=emit)
                    result = subprocess.run(
                        [RACKET, "-y", "bench/goblins/bench.rkt", "--smoke", "--suite=echo"],
                        cwd=ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("exited with status 7", result.stderr)
                    self.assertIn("original client failure", result.stderr)
                    self.assertEqual(calls.read_text().count("server.rkt"), 1)
                    self.assertNotIn("cross-implementation benchmark", result.stdout)
                    self.assert_children_gone(calls)

    def test_startup_failure_and_timeout_reap_server_with_diagnostic(self):
        for scenario, message in (("startup-exit", "original startup failure"), ("startup-hang", "startup stalled")):
            with self.subTest(scenario=scenario), self.children(SCENARIO=scenario) as (calls, environment):
                result = self.run_focused('(start-server "fake" "echo" 19800)', environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("fake/echo/server", result.stderr)
                self.assert_children_gone(calls)

    def test_client_deadline_includes_connection_reads_and_exit_after_eof(self):
        cases = (
            ("connections-hang", '(run-connections "fake" "echo" 19800 1 1)', "stdout"),
            ("stdout-hang", '(run-client "fake" "echo" 19800 "latency" 1)', "process exit"),
            ("stdout-hang", '(run-connections "fake" "echo" 19800 1 1)', "process exit"),
        )
        for scenario, expression, phase in cases:
            with (
                self.subTest(scenario=scenario, expression=expression),
                self.children(SCENARIO=scenario) as (calls, environment),
            ):
                result = self.run_focused(expression, environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"timed out during {phase}", result.stderr)
                self.assertIn("original stalled client", result.stderr)
                self.assert_children_gone(calls)

    def test_server_diagnostic_survives_client_failure(self):
        with self.children(SCENARIO="server-runtime-exit") as (calls, environment):
            result = self.run_focused('(bench-one "echo" "fake")', environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("original server runtime failure", result.stderr)
            self.assertIn("original client failure", result.stderr)
            self.assert_children_gone(calls)

    def test_successful_clients_require_server_alive_until_sample_commit(self):
        for scenario, succeeds in (("server-runtime-exit", False), ("success", True)):
            with self.subTest(scenario=scenario), self.children(SCENARIO=scenario) as (calls, environment):
                environment["FAIL_MODE"] = "none"
                # Real RSS sampling takes 1.8 s; its budget includes scheduling.
                result = self.run_focused(
                    '(parameterize ([child-timeout-seconds 5]) (bench-one "echo" "fake"))', environment
                )
                if succeeds:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("fake/echo/server", result.stderr)
                    self.assertIn("exited with status 7", result.stderr)
                    self.assertIn("original server runtime failure", result.stderr)
                modes = [call["args"][6] for call in self.calls(calls) if "client.rkt" in call["args"][1]]
                self.assertEqual(modes, ["latency", "throughput", "connections"])
                self.assert_children_gone(calls)

    def test_server_ignoring_interrupt_is_killed(self):
        with self.children(SCENARIO="ignore-interrupt") as (calls, environment):
            result = self.run_focused('(stop-child! (start-server "fake" "echo" 19800) #t)', environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_children_gone(calls)

    def test_stderr_drains_before_readiness_and_success_stays_quiet(self):
        with self.children(SCENARIO="stderr-flood") as (calls, environment):
            result = self.run_focused('(stop-child! (start-server "fake" "echo" 19800) #t)', environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assert_children_gone(calls)
        with self.children(SCENARIO="success") as (calls, environment):
            result = self.run_focused('(void (run-client "fake" "echo" 19800 "latency" 1))', environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assert_children_gone(calls)


if __name__ == "__main__":
    unittest.main()
