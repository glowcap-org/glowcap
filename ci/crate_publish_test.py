"""ci/crate_publish.py publishes the crate only when crates.io lacks the version.

The program runs against a stub curl that answers with a chosen status and a
stub cargo that records its call, so each answer's effect is held: 200 skips,
404 publishes, and anything else refuses. It never reaches crates.io.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from workflows import ROOT, jobs, run, stub

RECORDER = """#!/bin/sh
echo "$(basename "$0") $*" >> "$CALL_LOG"
if [ "$(basename "$0")" = curl ]; then printf "%s" "$CURL_STATUS"; fi
exit "${FAIL:-0}"
"""


class CratePublish(unittest.TestCase):
    def test_the_crate_step_calls_the_program(self):
        self.assertEqual(
            run(jobs(".github/workflows/publish.yml")["crates-io"], "Publish the crate"), "python3 ci/crate_publish.py"
        )

    def publish(self, status, manifest='[package]\nversion = "0.1.1"\n', **env):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "calls"
            log.write_text("")
            for tool in ("curl", "cargo"):
                stub(directory, tool, RECORDER)
            if manifest is not None:
                (directory / "bindings/rust").mkdir(parents=True)
                data = manifest if isinstance(manifest, bytes) else manifest.encode()
                (directory / "bindings/rust/Cargo.toml").write_bytes(data)
            result = subprocess.run(
                [sys.executable, str(ROOT / "ci/crate_publish.py")],
                cwd=directory,
                env={
                    **os.environ,
                    "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
                    "CALL_LOG": str(log),
                    "CURL_STATUS": status,
                    "VERSION": "0.1.1",
                    "GITHUB_REPOSITORY": "owner/project",
                    **env,
                },
                capture_output=True,
                text=True,
                timeout=20,
            )
            return result, log.read_text().splitlines()

    def test_each_registry_answer_decides_the_publish(self):
        lookup = (
            "curl -sS -o /dev/null -w %{http_code} -A glowcap-publish (owner/project) "
            "https://crates.io/api/v1/crates/glowcap/0.1.1"
        )
        for status, calls, accepted in (
            ("200", [lookup], True),
            ("404", [lookup, "cargo publish --manifest-path bindings/rust/Cargo.toml"], True),
            ("500", [lookup], False),
        ):
            with self.subTest(status=status):
                result, made = self.publish(status)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual(made, calls)
                if not accepted:
                    self.assertIn("answered 500, so nothing was published. Rerun this job", result.stderr)

    def test_a_failed_lookup_or_malformed_version_is_refused_before_publishing(self):
        result, made = self.publish("404", FAIL="6")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("crate-publish: curl"), result.stderr)
        self.assertNotIn("cargo", " ".join(made))
        for version in ("0.1", "1.0.0", "0.01.1"):
            with self.subTest(version=version):
                result, made = self.publish("404", VERSION=version)
                self.assertEqual(result.returncode, 1)
                self.assertIn("invalid VERSION", result.stderr)
                self.assertEqual(made, [])

    def test_a_version_the_manifest_does_not_state_is_refused_before_the_lookup(self):
        for manifest, said in (
            ('[package]\nversion = "0.1.0"\n', "states '0.1.0', not the release's 0.1.1"),
            ('[package]\nname = "glowcap"\n', "states None, not the release's 0.1.1"),
            ("[package\n", "crate-publish: bindings/rust/Cargo.toml: "),
            (b"\xff", "crate-publish: bindings/rust/Cargo.toml: "),
            (None, "crate-publish: bindings/rust/Cargo.toml: "),
        ):
            with self.subTest(manifest=manifest):
                result, made = self.publish("404", manifest=manifest)
                self.assertEqual(result.returncode, 1)
                self.assertIn(said, result.stderr)
                self.assertEqual(result.stderr.count("\n"), 1, result.stderr)
                self.assertEqual(made, [])


if __name__ == "__main__":
    unittest.main()
