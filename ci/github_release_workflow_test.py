"""The release job uploads and verifies a draft before making it public.

`github_release.py publish-draft` runs against a recording gh and a draft
state the test chooses, so these hold the order of its effects and that a
failed upload or verification never makes the draft public. The workflow
tests hold the release job to the one command per step that calls it.
Infrastructure-check discovers this suite separately from archive assembly.
"""

import subprocess
import unittest
from unittest import mock

import github_release as RELEASE
from github_release_test import REPOSITORY, TAG, run_main
from workflows import jobs, run


class PublishDraft(unittest.TestCase):
    RELEASE_JOB = jobs(".github/workflows/release.yml")["release"]

    def publish(self, draft_exists, *, upload=0, verify=False, published=False):
        """Run publish-draft and return its gh calls, whether it verified, and any refusal."""
        calls = []
        verified = []

        def gh(command, *, check, timeout):
            self.assertTrue(check)
            self.assertGreater(timeout, 0)
            calls.append(command[1:])
            if command[1:3] == ["release", "upload"] and upload:
                raise subprocess.CalledProcessError(upload, command)

        def state(repository, tag, run_id, *, complete=False, allow_published=False):
            self.assertEqual((repository, tag, run_id), (REPOSITORY, TAG, "123"))
            if complete:
                verified.append(True)
                if verify:
                    raise ValueError("release is incomplete")
                return {"draft_exists": True, "missing_assets": []}
            self.assertTrue(allow_published)
            missing = [] if published else ["a", "b"]
            return {"draft_exists": draft_exists, "missing_assets": missing, "published": published}

        refusal = None
        with (
            mock.patch.object(RELEASE.subprocess, "run", side_effect=gh),
            mock.patch.object(RELEASE, "draft_state", side_effect=state),
        ):
            try:
                run_main("publish-draft", TAG)
            except (ValueError, subprocess.CalledProcessError) as error:
                refusal = error
        return calls, bool(verified), refusal

    def test_a_new_draft_is_created_filled_in_order_and_then_made_public(self):
        calls, verified, refusal = self.publish(False)
        self.assertIsNone(refusal)
        self.assertEqual(
            calls,
            [
                [
                    "release",
                    "create",
                    TAG,
                    "--repo",
                    REPOSITORY,
                    "--title",
                    f"glowcap {TAG} alpha",
                    "--prerelease",
                    "--draft",
                    "--latest=false",
                    "--verify-tag",
                    "--notes-file",
                    "artifacts/release-notes.md",
                ],
                ["release", "upload", TAG, "release-assets/a", "--repo", REPOSITORY],
                ["release", "upload", TAG, "release-assets/b", "--repo", REPOSITORY],
                [
                    "release",
                    "edit",
                    TAG,
                    "--repo",
                    REPOSITORY,
                    "--draft=false",
                    "--prerelease",
                    "--latest=false",
                    "--notes-file",
                    "artifacts/release-notes.md",
                ],
            ],
        )
        self.assertTrue(verified)

    def test_an_existing_draft_is_resumed_without_creating_another(self):
        calls, _, refusal = self.publish(True)
        self.assertIsNone(refusal)
        self.assertEqual(
            [call[:2] for call in calls], [["release", "upload"], ["release", "upload"], ["release", "edit"]]
        )

    def test_a_failed_upload_or_verification_never_publishes_the_draft(self):
        for upload, verify in ((37, False), (0, True)):
            with self.subTest(upload=upload, verify=verify):
                calls, verified, refusal = self.publish(False, upload=upload, verify=verify)
                self.assertIsNotNone(refusal)
                self.assertNotIn(["release", "edit"], [call[:2] for call in calls])
                self.assertEqual(verified, not upload)

    def test_a_completed_public_release_is_left_alone(self):
        calls, verified, refusal = self.publish(False, published=True)
        self.assertIsNone(refusal)
        self.assertEqual(calls, [])
        self.assertFalse(verified)

    def test_the_release_job_and_publish_contract_call_the_script_modes(self):
        self.assertEqual(
            run(jobs(".github/workflows/publish.yml")["contract"], "Verify the public release behind the tag"),
            'python3 ci/github_release.py published "$RELEASE_TAG"',
        )
        for mode in ('assemble artifacts "$RELEASE_TAG"', 'bundles "$RELEASE_TAG"'):
            self.assertTrue(
                any(
                    f"python3 ci/github_release.py {mode}" in found.get("run", "")
                    for found in self.RELEASE_JOB["steps"]
                )
            )
        self.assertEqual(
            run(self.RELEASE_JOB, "Fill the draft release, then make it public"),
            'python3 ci/github_release.py publish-draft "$RELEASE_TAG"',
        )
        self.assertEqual(
            run(self.RELEASE_JOB, "Publish the language packages at the tag"),
            'gh workflow run publish.yml --repo "$GITHUB_REPOSITORY" --ref "refs/tags/$RELEASE_TAG" -f tag="$RELEASE_TAG"',
        )


if __name__ == "__main__":
    unittest.main()
