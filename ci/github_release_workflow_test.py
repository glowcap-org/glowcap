"""The release workflow uploads and verifies a draft before making it public.

Tests execute its shell steps with stub GitHub and verification commands.
Infrastructure-check discovers this suite separately from archive assembly.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from workflows import jobs, run, stub

TAG = "v0.1.0"
REPOSITORY = "owner/project"


@unittest.skipUnless(shutil.which("jq"), "the release steps parse state with jq")
class Workflow(unittest.TestCase):
    RELEASE = jobs(".github/workflows/release.yml")["release"]
    GH = """#!/usr/bin/env python3
import json, os, sys
with open('calls', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['release', 'upload']:
    sys.exit(int(os.environ['UPLOAD_STATUS']))
"""
    VERIFIER = """import os, sys
from pathlib import Path
if sys.argv[1] == 'draft-state':
    print(os.environ['DRAFT_STATE'])
else:
    Path('verification-attempted').touch()
    sys.exit(int(os.environ['VERIFY_STATUS']))
"""

    def fill(self, draft_exists, *, upload=0, verify=0):
        script = run(self.RELEASE, "Fill the draft release, then make it public")
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "artifacts").mkdir()
            stub(directory, "gh", self.GH)
            stub(directory, "ci/github_release.py", self.VERIFIER)
            state = json.dumps({"draft_exists": draft_exists, "missing_assets": ["a", "b"]})
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c", script],
                cwd=directory,
                env=dict(
                    os.environ,
                    PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                    RELEASE_TAG=TAG,
                    GITHUB_REPOSITORY=REPOSITORY,
                    DRAFT_STATE=state,
                    UPLOAD_STATUS=str(upload),
                    VERIFY_STATUS=str(verify),
                ),
                capture_output=True,
                text=True,
                timeout=20,
            )
            calls = (directory / "calls").read_text().splitlines() if (directory / "calls").exists() else []
            return result, [json.loads(line) for line in calls], (directory / "verification-attempted").exists()

    def test_a_new_draft_is_created_filled_in_order_and_then_made_public(self):
        result, calls, verified = self.fill(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[:2] for call in calls],
            [["release", "create"], ["release", "upload"], ["release", "upload"], ["release", "edit"]],
        )
        for flag in ("--draft", "--prerelease", "--latest=false", "--verify-tag"):
            self.assertIn(flag, calls[0])
        self.assertIn(f"glowcap {TAG} alpha", calls[0])
        self.assertEqual([call[3] for call in calls[1:3]], ["release-assets/a", "release-assets/b"])
        for flag in ("--draft=false", "--prerelease", "--latest=false"):
            self.assertIn(flag, calls[3])
        self.assertTrue(verified)

    def test_an_existing_draft_is_resumed_without_creating_another(self):
        result, calls, _ = self.fill(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[:2] for call in calls], [["release", "upload"], ["release", "upload"], ["release", "edit"]]
        )

    def test_a_failed_upload_or_verification_never_publishes_the_draft(self):
        for upload, verify in ((37, 0), (0, 41)):
            with self.subTest(upload=upload, verify=verify):
                result, calls, verified = self.fill(False, upload=upload, verify=verify)
                self.assertEqual(result.returncode, upload or verify, result.stderr)
                self.assertNotIn(["release", "edit"], [call[:2] for call in calls])
                self.assertEqual(verified, not upload)

    def test_the_release_job_and_publish_contract_call_the_script_modes(self):
        self.assertEqual(
            run(jobs(".github/workflows/publish.yml")["contract"], "Verify the public release behind the tag"),
            'python3 ci/github_release.py published "$RELEASE_TAG"',
        )
        for mode in (
            'assemble artifacts "$RELEASE_TAG"',
            'bundles "$RELEASE_TAG"',
            'draft-state "$RELEASE_TAG"',
            'verify-draft "$RELEASE_TAG"',
        ):
            self.assertTrue(
                any(f"python3 ci/github_release.py {mode}" in found.get("run", "") for found in self.RELEASE["steps"])
            )
        script = run(self.RELEASE, "Fill the draft release, then make it public")
        self.assertIn('gh release create "$RELEASE_TAG"', script)
        self.assertNotIn("GITHUB_REF_NAME", script)


if __name__ == "__main__":
    unittest.main()
