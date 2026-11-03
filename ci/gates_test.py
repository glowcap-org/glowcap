"""ci/gates.py and the inventory in ci/groups.py, for infrastructure-check.

The runner's command launcher and evidence recorder are replaced in process,
so every gate the runner would start is recorded instead of run.
"""

import contextlib
import io
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import gates as GATES
import groups as GROUPS
from workflows import ROOT

DEFAULTS = ["--test-timeout", "30s", "--summary", "new"]
TIMEOUT_NAMES = ("GATE_TIMEOUT", "BUILD_TIMEOUT", "LONG_TIMEOUT")


def expected(command):
    """The argv the runner starts for an inventory row."""
    argv = command.split()
    return ["zig", "build", *DEFAULTS, *argv[2:]] if argv[:2] == ["zig", "build"] else argv


class Recorder:
    """Stands in for the runner's launcher and evidence writer.

    `failures` maps a gate's step name to the status its command exits with.
    After a run, `calls` holds every (argv, deadline) started, `record` the
    evidence body written and `out` its directory, and `noted` whether the
    record was attached as a git note. `record_failure` makes the writer
    refuse with that status.
    """

    def __init__(self, failures=None, record_failure=0, dirty=False):
        self.failures = failures or {}
        self.record_failure = record_failure
        self.dirty = dirty
        self.calls = []
        self.record = self.out = None
        self.noted = False

    def execute(self, argv, timeout):
        self.calls.append((argv, timeout))
        return next((status for name, status in self.failures.items() if name in argv), 0)

    def evidence(self):
        recorder = self

        class Module:
            @staticmethod
            def record(gates, started, outcome):
                return {
                    "gates": gates,
                    "started": started,
                    "outcome": outcome,
                    "dirty": recorder.dirty,
                    "commit": "c" * 40,
                }

            @staticmethod
            def write(out, body):
                if recorder.record_failure:
                    raise SystemExit(recorder.record_failure)
                recorder.record, recorder.out = body, out
                return out / "record.json"

            @staticmethod
            def attach_note(path, commit):
                recorder.noted = True

        return Module

    def run(self, *argv, **environment):
        self.calls, self.record, self.out, self.noted = [], None, None, False
        clean = {key: value for key, value in os.environ.items() if key not in TIMEOUT_NAMES}
        with (
            mock.patch.object(GATES, "execute", self.execute),
            mock.patch.object(GATES, "evidence", self.evidence()),
            mock.patch.dict(os.environ, dict(clean, **environment), clear=True),
            mock.patch("builtins.print"),
        ):
            return GATES.main(list(argv))


class InventoryTest(unittest.TestCase):
    def test_every_phase_belongs_to_one_group_and_names_a_product_check(self):
        phases = [phase for group in GROUPS.GROUPS for phase in group.phases]
        self.assertEqual(len(phases), len(set(phases)))
        self.assertEqual(list(GROUPS.PHASES), phases)
        for phase, gates in GROUPS.PHASES.items():
            with self.subTest(phase=phase):
                self.assertTrue(gates)
                for kind, command in gates:
                    self.assertIn(kind, ("gate", "build", "long"))
                    self.assertRegex(command, r"^(zig build|bash|python3) \S")
                    if not command.startswith("zig build"):
                        interpreter, path = command.split()[:2]
                        self.assertEqual(
                            path.rsplit(".", 1)[1],
                            {"bash": "sh", "python3": "py"}[interpreter],
                            "the interpreter matches the file it runs",
                        )
                        self.assertTrue((ROOT / path).is_file(), path)
        commands = " ".join(command for gates in GROUPS.PHASES.values() for _, command in gates)
        for step in ("check", "runtime-check", "goblins-interop", "ocapn-conformance-next", "bindings-package-check"):
            self.assertIn(f" {step}", commands + " ")
        self.assertNotIn("tool-install.sh", commands, "agent downloads have their own workflow")
        self.assertEqual(commands.count("bindings-package-check"), 1, "detached package consumers run in CI")

    def test_the_wrapper_is_proven_before_the_gates_it_bounds(self):
        infrastructure = [command for _, command in GROUPS.PHASES["infrastructure"]]
        self.assertLess(
            infrastructure.index("python3 tools/run_with_timeout_test.py"),
            infrastructure.index("zig build infrastructure-check"),
        )

    def test_groups_without_shards_compile_nothing_ahead(self):
        shards = {group.name: group.shards for group in GROUPS.GROUPS}
        self.assertEqual(shards["source"], 0)
        self.assertEqual(shards["fuzz"], 0)
        self.assertEqual(tuple(GROUPS.PHASES)[:2], ("source", "infrastructure"))

    def test_shipped_partitions_cover_every_layer_once(self):
        source = (ROOT / "test/all_test.zig").read_text()
        declared = re.search(r"const Layer = enum \{([^}]+)\}", source)[1]
        layers = [name.strip() for name in declared.split(",") if name.strip()]
        selected_layers = []
        for kind, command in GROUPS.PHASES["shipped"]:
            selection = re.fullmatch(r"zig build test -Doptimize=ReleaseSafe -Dtest-layer=([a-z_,]+)", command)
            self.assertIsNotNone(selection, "ship-mode tests bound compiler memory by layer")
            selected_layers.extend(selection[1].split(","))
        self.assertCountEqual(selected_layers, layers)


class RunnerTest(unittest.TestCase):
    def test_each_phase_runs_its_gates_once_and_records_them(self):
        recorder = Recorder()
        combined = []
        for phase, gates in GROUPS.PHASES.items():
            with self.subTest(phase=phase):
                self.assertEqual(recorder.run("run", phase), 0)
                self.assertEqual([argv for argv, _ in recorder.calls], [expected(command) for _, command in gates])
                combined.extend(recorder.calls)
                self.assertEqual(recorder.out, ROOT / "zig-out/evidence" / phase)
                self.assertEqual(recorder.record["outcome"], "passed")
                self.assertEqual(
                    [row["command"] for row in recorder.record["gates"]], [" ".join(argv) for argv, _ in recorder.calls]
                )
                self.assertFalse(recorder.noted)
        self.assertEqual(recorder.run("run"), 0)
        self.assertEqual(recorder.calls, combined, "a full run is every phase in order")
        self.assertEqual(recorder.out, ROOT / "zig-out/evidence")
        self.assertTrue(recorder.noted, "a clean full run attaches its record to HEAD")
        dirty = Recorder(dirty=True)
        self.assertEqual(dirty.run("run", "tls"), 0)
        self.assertEqual(dirty.run("run"), 0)
        self.assertFalse(dirty.noted)

    def test_zig_gates_get_the_ci_defaults_unless_they_set_them(self):
        self.assertEqual(GATES.with_defaults(["zig", "build", "test"]), ["zig", "build", *DEFAULTS, "test"])
        self.assertEqual(
            GATES.with_defaults(["zig", "build", "test", "--test-timeout", "7s"]),
            ["zig", "build", "--summary", "new", "test", "--test-timeout", "7s"],
        )
        self.assertEqual(
            GATES.with_defaults(["zig", "build", "--summary", "all", "test"]),
            ["zig", "build", "--test-timeout", "30s", "--summary", "all", "test"],
        )
        self.assertEqual(
            GATES.with_defaults(["zig", "build", "run", "--", "--summary"]),
            ["zig", "build", *DEFAULTS, "run", "--", "--summary"],
            "options after -- belong to the program",
        )
        self.assertEqual(GATES.with_defaults(["bash", "script.sh"]), ["bash", "script.sh"])

    def test_deadline_classes_and_their_overrides(self):
        cases = [
            ({}, ("60m", "20m", "40m")),
            ({"GATE_TIMEOUT": "7m"}, ("7m", "7m", "7m")),
            ({"BUILD_TIMEOUT": "9m"}, ("9m", "20m", "40m")),
            ({"LONG_TIMEOUT": "8m"}, ("60m", "20m", "8m")),
            ({"GATE_TIMEOUT": "7m", "BUILD_TIMEOUT": "9m", "LONG_TIMEOUT": "8m"}, ("9m", "7m", "8m")),
        ]
        clean = {key: value for key, value in os.environ.items() if key not in TIMEOUT_NAMES}
        for overrides, (build, gate, long) in cases:
            with self.subTest(overrides=overrides), mock.patch.dict(os.environ, dict(clean, **overrides), clear=True):
                self.assertEqual(
                    (GATES.deadline("build"), GATES.deadline("gate"), GATES.deadline("long")), (build, gate, long)
                )
        recorder = Recorder()
        recorder.run("run", "core", GATE_TIMEOUT="7m", BUILD_TIMEOUT="9m")
        self.assertEqual([timeout for _, timeout in recorder.calls], ["9m", "7m"])
        recorder.run("run", "memcheck", LONG_TIMEOUT="8m")
        self.assertEqual([timeout for _, timeout in recorder.calls], ["60m", "8m"])

    def test_a_build_job_compiles_its_shard_and_runs_nothing(self):
        recorder = Recorder()
        self.assertEqual(recorder.run("compile", "2/3", "core", "memcheck"), 0)
        self.assertEqual(
            [argv[6:] for argv, _ in recorder.calls],
            [["check-build"], ["check"], ["test-memcheck-build"], ["test-memcheck"]],
        )
        for argv, timeout in recorder.calls:
            self.assertEqual(argv[:6], ["zig", "build", "-Dcompile-only", "-Dcompile-shard=2/3", "--summary", "new"])
            self.assertEqual(timeout, "60m", "a compile gets the build allowance")
        self.assertIsNone(recorder.record, "a compile writes no evidence")
        # Phases that open with the same shared builds compile them once, and
        # the gates that are not zig builds have nothing to compile.
        self.assertEqual(recorder.run("compile", "1/1", "browser-proofs-1", "browser-proofs-2", "infrastructure"), 0)
        self.assertEqual(
            [argv[6:] for argv, _ in recorder.calls],
            [
                ["loam-browser-build", "rooms-web-build"],
                ["rooms-archive-build", "rooms-session-build", "iroh-abi"],
                ["rooms-web-proofs", "-Drooms-web-proof-shard=1/4"],
                ["rooms-web-proofs", "-Drooms-web-proof-shard=2/4"],
                ["infrastructure-check"],
            ],
        )

    def test_malformed_calls_run_and_record_nothing(self):
        recorder = Recorder()
        for arguments in (
            [],
            ["unknown"],
            ["run", "unknown"],
            ["run", "core", "browser"],
            ["compile", "core"],
            ["compile", "4/3", "core"],
            ["compile", "1/2", "unknown"],
            ["fetch", "extra"],
            ["summary", "extra"],
        ):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as refused:
                    recorder.run(*arguments)
                self.assertEqual(refused.exception.code, 2)
                self.assertEqual(recorder.calls, [])
                self.assertIsNone(recorder.record)

    def test_a_failed_gate_continues_its_phase_and_the_first_failure_is_the_status(self):
        for failures, record_failure, status in [
            ({"check": 37}, 0, 37),
            ({"check": 37}, 9, 37),
            ({"check-build": 5, "check": 37}, 0, 5),
            ({}, 9, 70),
        ]:
            with self.subTest(failures=failures, record_failure=record_failure):
                recorder = Recorder(failures, record_failure)
                self.assertEqual(recorder.run("run", "core"), status)
                self.assertEqual(len(recorder.calls), len(GROUPS.PHASES["core"]), "every gate ran")
                if not record_failure:
                    rows = recorder.record["gates"]
                    self.assertEqual(recorder.record["outcome"], "failed" if failures else "passed")
                    self.assertEqual(
                        [row["exit"] for row in rows],
                        [
                            next((code for name, code in failures.items() if name in row["command"].split()), 0)
                            for row in rows
                        ],
                    )

    def test_a_build_past_its_deadline_stops_the_phase(self):
        for code in (124, 137):
            self.assertTrue(GATES.wedged(code))
        for code in (0, 1, 3, 126, 127):
            self.assertFalse(GATES.wedged(code))
        recorder = Recorder({"check-build": 124})
        self.assertEqual(recorder.run("run", "core"), 124)
        self.assertEqual(len(recorder.calls), 1, "every later gate needs the build")
        self.assertEqual(recorder.record["outcome"], "failed")
        self.assertEqual(len(recorder.record["gates"]), 1)
        recorder = Recorder({"check-build": 124})
        self.assertEqual(recorder.run("run"), 124)
        self.assertEqual(recorder.calls[-1][0][-1], "check-build", "a full run stops there too")
        ordinary = Recorder({"check": 124})
        self.assertEqual(ordinary.run("run", "core"), 124)
        self.assertEqual(len(ordinary.calls), 2, "an ordinary gate past its deadline lets the phase go on")
        compile = Recorder({"check-build": 124})
        self.assertEqual(compile.run("compile", "1/1", "core"), 124)
        self.assertEqual(len(compile.calls), 1)

    def test_dependency_acquisition_retries_without_running_tests(self):
        for codes, status, attempts in [
            ([0], 0, 1),
            ([1, 0], 0, 2),
            ([1, 1, 0], 0, 3),
            ([7], 7, 3),
            ([130], 130, 1),
            ([143], 143, 1),
        ]:
            with self.subTest(codes=codes):
                calls = []

                def run(argv, cwd):
                    calls.append(argv)
                    return mock.Mock(returncode=codes[min(len(calls) - 1, len(codes) - 1)])

                with (
                    mock.patch.object(GATES.subprocess, "run", run),
                    mock.patch.object(GATES.time, "sleep") as sleep,
                    mock.patch("builtins.print"),
                    mock.patch.dict(os.environ, {"ZIG_FETCH_RETRY_DELAY": "3"}),
                ):
                    self.assertEqual(GATES.main(["fetch"]), status)
                self.assertEqual(len(calls), attempts)
                for argv in calls:
                    self.assertEqual(argv[-3:], ["zig", "build", "--fetch=all"])
                    self.assertIn("3m", argv)
                self.assertEqual(sleep.call_count, attempts - 1)
                if attempts > 1:
                    sleep.assert_called_with(3)
        with (
            mock.patch.object(GATES.subprocess, "run") as run,
            mock.patch("builtins.print"),
            mock.patch.dict(os.environ, {"ZIG_FETCH_RETRY_DELAY": "invalid"}),
        ):
            self.assertEqual(GATES.main(["fetch"]), 2)
            run.assert_not_called()

    def test_a_gate_runs_under_the_deadline_wrapper_with_rust_backtraces(self):
        with mock.patch.object(GATES.subprocess, "run") as run:
            run.return_value = mock.Mock(returncode=3)
            self.assertEqual(GATES.execute(["zig", "build", "test"], "5m"), 3)
        (argv,), kwargs = run.call_args
        self.assertEqual(argv[:3], ["python3", "tools/run-with-timeout.py", "--kill-after"])
        self.assertEqual(argv[-4:], ["5m", "zig", "build", "test"])
        self.assertEqual(kwargs["env"]["RUST_BACKTRACE"], "1")

    def test_the_step_summary_lists_every_recorded_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "zig-out/evidence/core").mkdir(parents=True)
            (root / "zig-out/evidence/core/record.json").write_text(
                json.dumps(
                    {
                        "gates": [
                            {"command": "zig build check", "exit": 0, "seconds": 12},
                            {"command": "zig build test", "exit": 3, "seconds": 4},
                        ]
                    }
                )
            )
            with (
                mock.patch.object(GATES, "ROOT", root),
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary")}),
            ):
                self.assertEqual(GATES.main(["summary"]), 0)
            self.assertEqual(
                (root / "summary").read_text().splitlines(),
                [
                    "| Gate | Result | Seconds |",
                    "| --- | --- | ---: |",
                    "| `zig build check` | passed | 12 |",
                    "| `zig build test` | failed (3) | 4 |",
                ],
            )


if __name__ == "__main__":
    unittest.main()
