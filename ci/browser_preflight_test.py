"""Managed browser proofs prepare their pinned tool once under a separate deadline."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from build_environment_test import copy_build_helpers


class BrowserPreflight(unittest.TestCase):
    def test_managed_browser_proofs_share_one_setup_before_either_runs(self):
        temporary = tempfile.TemporaryDirectory(prefix="glowcap-browser-env-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        copy_build_helpers(root)
        (root / "build.zig").write_text("""const std = @import("std");
const execution = @import("tools/build/execution.zig");
pub fn build(b: *std.Build) void {
    const probe = b.step("probe", "Exercise browser setup");
    for ([_][]const u8{ "first", "second" }) |label| {
        const run = execution.addSystemCommand(b, .{ .browser_proof = 45 }, &.{ "sh", "proof.sh" });
        run.addArg(label);
        probe.dependOn(&run.step);
    }
}
""")
        # Each child records the budget of the real supervisor that launched it.
        supervisor = root / "tools/run-with-timeout.py"
        supervisor.rename(supervisor.with_name("real-timeout.py"))
        supervisor.write_text("""import os, runpy, sys
from pathlib import Path
runner = runpy.run_path(str(Path(__file__).with_name("real-timeout.py")))
budget = sys.argv[sys.argv.index("--kill-after") + 2]
os.environ["PROOF_SECONDS"] = str(runner["duration"](budget))
sys.exit(runner["main"]())
""")
        preflight = root / "tools/check/playwright-preflight.sh"
        preflight.parent.mkdir()
        preflight.write_text('echo "setup ${PROOF_SECONDS:?}" >> events\n')
        front = root / ".devcontainer/bin/tools.sh"
        front.parent.mkdir(parents=True)
        front.write_text(
            "set -eu\n"
            "[[ $1 == exec && $2 == playwright && $3 == -- && -f events ]] || exit 1\n"
            "shift 3\n"
            "export PROOF_BROWSER=managed\n"
            'exec "$@"\n'
        )
        (root / "proof.sh").write_text('echo "$PROOF_BROWSER $1 ${PROOF_SECONDS:?}" >> events\n')
        events = root / "events"
        for marker in (str(front.parent.parent), None, ""):
            with self.subTest(devcontainer_dir=marker):
                events.unlink(missing_ok=True)
                env = dict(os.environ, PROOF_BROWSER="host", PROOF_SECONDS="")
                if marker is None:
                    env.pop("GLOWCAP_DEVCONTAINER_DIR", None)
                else:
                    env["GLOWCAP_DEVCONTAINER_DIR"] = marker
                result = subprocess.run(
                    ["zig", "build", "probe"], cwd=root, env=env, capture_output=True, text=True, timeout=20
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = events.read_text().splitlines()
                if marker:
                    setup, seconds = lines.pop(0).split()
                    self.assertEqual(setup, "setup")
                    self.assertGreater(float(seconds), 45)
                selection = "managed" if marker else "host"
                self.assertCountEqual(lines, [f"{selection} first 45.0", f"{selection} second 45.0"])


if __name__ == "__main__":
    unittest.main()
