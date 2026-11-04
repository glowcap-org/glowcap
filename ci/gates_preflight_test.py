"""A real undeclared-script refusal must stop CI before later build/run work.

infrastructure-check runs this against the production graph checker in a tiny
temporary Zig project. Its expensive command leaves a file if CI reaches it.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import gates

BUILD = """
const std = @import("std");
const checker = @import("toolchain_check.zig");
pub fn build(b: *std.Build) void {
    const compile_only = b.option(bool, "compile-only", "omit noncompile checks") orelse false;
    _ = b.option([]const u8, "compile-shard", "accepted for the CI compile probe");
    const allowed = b.option(bool, "allow-script", "declare the fixture script") orelse false;
    const child = b.addSystemCommand(&.{ "python3", "unlisted.py" });
    child.setCwd(b.path("."));
    const expensive = b.step("expensive", "stand in for later compilation or runtime work");
    expensive.dependOn(&child.step);
    const verdict = checker.create(b, expensive, &.{.{
        .program = "python3",
        .scripts = if (allowed) &.{"unlisted.py"} else &.{"allowed.py"},
        .why = "fixture proves refusal before a child starts",
    }});
    const preflight = b.step("preflight", "check the fixture's runtime declaration");
    if (!compile_only) preflight.dependOn(verdict.declaration);
}
"""


class PreflightTest(unittest.TestCase):
    def test_undeclared_script_stops_compile_and_test_jobs_before_the_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build.zig").write_text(BUILD)
            shutil.copyfile(gates.ROOT / "tools/check/toolchain_check.zig", root / "toolchain_check.zig")
            marker = root / "expensive-ran"
            (root / "unlisted.py").write_text("from pathlib import Path\nPath('expensive-ran').touch()\n")
            for mode in ("phase", "compile"):
                for allowed in (False, True):
                    with self.subTest(mode=mode, allowed=allowed):
                        marker.unlink(missing_ok=True)
                        calls, output = [], []

                        def execute(argv, timeout):
                            calls.append(argv)
                            result = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=120)
                            output.append(result.stdout + result.stderr)
                            return result.returncode

                        rows = [
                            ("prerequisite", f"zig build preflight -Dallow-script={str(allowed).lower()}"),
                            ("build", "zig build expensive"),
                            ("long", "zig build expensive"),
                        ]
                        with (
                            mock.patch.dict(gates.groups.PHASES, {"fixture": rows}),
                            mock.patch.object(gates, "execute", execute),
                        ):
                            run = gates.Run()
                            status = run.phase("fixture") if mode == "phase" else run.compile("1/1", ["fixture"])
                        if allowed:
                            self.assertIn(status, (None, 0), "\n".join(output))
                            self.assertTrue(marker.exists(), "the same child must run when declared")
                        else:
                            self.assertNotIn(status, (None, 0), "\n".join(output))
                            self.assertIn("not among the scripts declared", output[0])
                            self.assertEqual(len(calls), 1, "no later compilation or runtime command may start")
                            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
