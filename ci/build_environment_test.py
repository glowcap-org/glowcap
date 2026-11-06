"""Build commands inherit this invocation's environment after configuration reuse.

Infrastructure-check runs the real Zig build runner twice against the production
command helper. A changed PATH selects a newly installed tool, and GitHub's
per-step output file reaches it. Temporary files and configuration caches are
removed on exit. No compiler or browser downloads are needed.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildEnvironment(unittest.TestCase):
    def test_changed_path_and_step_output_reach_a_bounded_child(self):
        with tempfile.TemporaryDirectory(prefix="glowcap-build-env-") as temporary:
            root = Path(temporary)
            for relative in ("tools/build/execution.zig", "tools/build/shard.zig", "tools/run-with-timeout.py"):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            (root / "build.zig").write_text("""const std = @import("std");
const execution = @import("tools/build/execution.zig");
pub fn build(b: *std.Build) void {
    const run = execution.addSystemCommand(b, .{ .deterministic = 10 }, &.{"release-tool"});
    execution.showOutput(run);
    b.step("probe", "Exercise the current environment").dependOn(&run.step);
}
""")
            zig = shutil.which("zig")
            self.assertIsNotNone(zig, "the build environment proof requires the pinned Zig")
            for label in ("before", "after"):
                directory = root / label
                directory.mkdir()
                tool = directory / "release-tool"
                tool.write_text(f'#!/bin/sh\nprintf "%s\\n" "{label}" "$GITHUB_OUTPUT"\n')
                tool.chmod(0o755)
                result = subprocess.run(
                    [zig, "build", "probe"],
                    cwd=root,
                    env=dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"], GITHUB_OUTPUT=label),
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{label}\n{label}\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
