"""tools/check/ocapnviz-build-check.sh and ocapnviz-test.sh, for infrastructure-check.

The ocapnviz app's checks type-check before any timed execution, so a type
error fails the build check and a failing test fails the run, each against a
disposable checkout whose path holds a space.
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class OcapnvizChecks(unittest.TestCase):
    def test_types_are_checked_before_timed_execution(self):
        cases = [
            (
                "export const main = 1;\n",
                'const value: number = "invalid";\nDeno.test("runs", () => { console.log(value); });\n',
                False,
                True,
            ),
            (
                'export const main: number = "invalid";\n',
                'Deno.test("runs", () => { console.log("execution sentinel"); });\n',
                False,
                True,
            ),
            (
                "export const main = 1;\n",
                'Deno.test("fails", () => { throw new Error("execution sentinel"); });\n',
                True,
                False,
            ),
        ]
        for main, source, build_ok, run_ok in cases:
            with self.subTest(main=main, source=source), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "checkout with spaces"
                scripts = root / "tools/check"
                scripts.mkdir(parents=True)
                app = root / "apps/ocapnviz"
                (app / "dist").mkdir(parents=True)
                (app / "dist/glowcap_host.wasm").write_bytes(b"fixture")
                (app / "main.ts").write_text(main)
                (app / "phase_test.ts").write_text(source)
                (app / "deno.json").write_text(
                    json.dumps({"tasks": {"typecheck": "deno check main.ts", "fmt:check": "true", "build": "true"}})
                )
                for name in ("ocapnviz-build-check.sh", "ocapnviz-test.sh"):
                    shutil.copy2(ROOT / "tools/check" / name, scripts / name)
                for name, expected in (("ocapnviz-build-check.sh", build_ok), ("ocapnviz-test.sh", run_ok)):
                    result = subprocess.run(
                        ["bash", str(scripts / name)], cwd=temporary, capture_output=True, text=True, timeout=10
                    )
                    self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
                    if name == "ocapnviz-build-check.sh" and not expected:
                        self.assertIn("TS2322", result.stderr)
                    if name == "ocapnviz-test.sh" and not expected:
                        self.assertIn("execution sentinel", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
