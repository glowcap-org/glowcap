"""A release retry restores one complete generation before resuming its draft.

The release workflow owns the immutable same-run artifact. These fixtures hold
the bytes, identity, and refusal boundaries around its upload and restoration;
they do not contact Actions, the attestation service, or a package registry.
"""

import hashlib
import json
import shutil
import unittest
from unittest import mock

import github_release as RELEASE
from github_release_test import MARKER, REPOSITORY, TAG, build_artifacts, run_main, workdir
from workflows import jobs, selected, step


class Prepared(unittest.TestCase):
    def generation(self, root):
        build_artifacts(root / "artifacts")
        run_main("assemble", "artifacts", TAG)
        for name in RELEASE.inventory(TAG):
            path = RELEASE.ASSETS / name
            if not path.exists():
                path.write_text('{"evidence": "first attempt"}\n')
        RELEASE.NOTES.write_text(f"Release notes\n{MARKER}\n")
        run_main("seal-prepared", TAG)
        return {
            path: path.read_bytes()
            for path in (*RELEASE.ASSETS.iterdir(), RELEASE.FACTS, RELEASE.NOTES, RELEASE.PREPARED)
        }

    def test_partial_upload_resumes_with_saved_evidence_when_new_attestations_exist(self):
        with workdir() as root:
            saved = self.generation(root)
            uploaded = ["SHA256SUMS", "SHA256SUMS.sigstore.json", f"glowcap-rooms-{TAG}.spdx.json"]
            draft = {
                "draft": True,
                "body": MARKER,
                "assets": [
                    {
                        "name": name,
                        "state": "uploaded",
                        "digest": "sha256:" + hashlib.sha256(saved[RELEASE.ASSETS / name]).hexdigest(),
                    }
                    for name in uploaded
                ],
            }
            # Regeneration would change both provenance and the scanner's SBOM.
            for name in uploaded[1:]:
                (RELEASE.ASSETS / name).write_text('{"evidence": "second attempt"}\n')
            with self.assertRaisesRegex(ValueError, "bytes differ from its seal"):
                run_main("verify-prepared", TAG)
            with mock.patch.object(RELEASE, "release_for", return_value=draft):
                with self.assertRaisesRegex(ValueError, "existing draft asset differs"):
                    RELEASE.draft_state(REPOSITORY, TAG, "123")
                # download-artifact restores the saved generation into a fresh job.
                shutil.rmtree(RELEASE.ASSETS)
                for path, contents in saved.items():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(contents)
                run_main("verify-prepared", TAG)
                state = RELEASE.draft_state(REPOSITORY, TAG, "123")
            self.assertTrue(state["draft_exists"])
            self.assertEqual(state["missing_assets"], sorted(set(RELEASE.inventory(TAG)) - set(uploaded)))
            bundle = RELEASE.ASSETS / "SHA256SUMS.sigstore.json"
            self.assertEqual(bundle.read_bytes(), saved[bundle])

    def test_changed_product_bytes_are_refused_before_draft_effects(self):
        with workdir() as root:
            self.generation(root)
            product = RELEASE.ASSETS / RELEASE.archive_name(TAG, "aarch64-linux", "product")
            product.write_bytes(b"changed product")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                run_main("verify-prepared", TAG)

    def test_only_this_runs_complete_identical_public_release_can_resume_dispatch(self):
        with workdir() as root:
            self.generation(root)
            released = {
                "draft": False,
                "body": MARKER,
                "assets": [
                    {"name": name, "state": "uploaded", "digest": "sha256:" + RELEASE.digest_of(RELEASE.ASSETS / name)}
                    for name in RELEASE.inventory(TAG)
                ],
            }
            with mock.patch.object(RELEASE, "release_for", return_value=released):
                # The complete-draft check keeps refusing published releases.
                with self.assertRaisesRegex(ValueError, "existing release is published"):
                    RELEASE.draft_state(REPOSITORY, TAG, "123", complete=True)
                state = RELEASE.draft_state(REPOSITORY, TAG, "123", allow_published=True)
                self.assertEqual(state, {"draft_exists": False, "missing_assets": [], "published": True})
            for changed in (
                {**released, "body": RELEASE.run_marker("124")},
                {**released, "assets": released["assets"][:-1]},
                {**released, "assets": [{**asset, "digest": "sha256:" + "0" * 64} for asset in released["assets"]]},
            ):
                with self.subTest(changed), mock.patch.object(RELEASE, "release_for", return_value=changed):
                    with self.assertRaises(ValueError):
                        RELEASE.draft_state(REPOSITORY, TAG, "123", allow_published=True)

    def test_identity_inventory_and_saved_notes_are_required(self):
        for key, replacement in (
            ("repository", "https://github.com/other/repository"),
            ("tag", "v0.1.1"),
            ("version", "0.1.1"),
            ("commit", "b" * 40),
            ("run", f"https://github.com/{REPOSITORY}/actions/runs/124"),
        ):
            with self.subTest(key), workdir() as root:
                self.generation(root)
                facts = json.loads(RELEASE.FACTS.read_text())
                facts[key] = replacement
                RELEASE.FACTS.write_text(json.dumps(facts))
                with self.assertRaisesRegex(ValueError, f"prepared release {key} differs"):
                    run_main("verify-prepared", TAG)
        for path in (RELEASE.NOTES, RELEASE.ASSETS / "SHA256SUMS.sigstore.json", RELEASE.PREPARED):
            with self.subTest(path), workdir() as root:
                self.generation(root)
                path.unlink()
                with self.assertRaises(ValueError):
                    run_main("verify-prepared", TAG)

    def test_a_sealed_generation_cannot_be_overwritten(self):
        with workdir() as root:
            saved = self.generation(root)
            with self.assertRaises(FileExistsError):
                run_main("seal-prepared", TAG)
            self.assertEqual(RELEASE.PREPARED.read_bytes(), saved[RELEASE.PREPARED])

    def test_only_a_live_artifact_of_this_run_is_selected(self):
        artifact = {"name": RELEASE.PREPARED_ARTIFACT, "id": 42, "expired": False}
        with (
            workdir() as root,
            mock.patch.object(RELEASE, "api", return_value=[{"artifacts": []}, {"artifacts": [artifact]}]) as api,
            mock.patch.object(RELEASE, "release_for") as release,
        ):
            output = root / "output"
            run_main("prepared-state", TAG, GITHUB_OUTPUT=str(output))
            self.assertEqual(output.read_text(), "artifact_id=42\n")
            api.assert_called_once_with(REPOSITORY, "actions/runs/123/artifacts?per_page=100", pages=True)
            release.assert_not_called()
        for artifacts in ([{**artifact, "expired": True}], [artifact, artifact]):
            with self.subTest(artifacts), mock.patch.object(RELEASE, "api", return_value=[{"artifacts": artifacts}]):
                with self.assertRaises(ValueError):
                    RELEASE.prepared_state(REPOSITORY, TAG, "123")

    def test_missing_artifact_allows_only_a_release_without_prior_draft_effects(self):
        with mock.patch.object(RELEASE, "api", return_value=[{"artifacts": []}]):
            with mock.patch.object(RELEASE, "release_for", return_value=None):
                self.assertEqual(RELEASE.prepared_state(REPOSITORY, TAG, "123"), "")
            for existing in ({"draft": True}, {"draft": False}):
                with self.subTest(existing), mock.patch.object(RELEASE, "release_for", return_value=existing):
                    with self.assertRaisesRegex(ValueError, "prepared artifact is missing"):
                        RELEASE.prepared_state(REPOSITORY, TAG, "123")


class PreparedWorkflow(unittest.TestCase):
    def test_restore_bypasses_every_preparation_effect_and_verifies_before_resuming(self):
        release = jobs(".github/workflows/release.yml")["release"]
        steps = release["steps"]
        names = [entry.get("name", "") for entry in steps]
        start = names.index("Download the build artifacts for preparation")
        save = names.index("Save this run's prepared release")
        verify = names.index("Verify the saved release generation")
        fill = names.index("Fill the draft release, then make it public")
        self.assertLess(names.index("Find this run's prepared release"), start)
        self.assertLess(save, verify)
        self.assertLess(verify, fill)
        for artifact_id in ("", "42"):
            context = {"steps": {"prepared": {"outputs": {"artifact_id": artifact_id}}}}
            for entry in steps[start : save + 1]:
                with self.subTest(artifact_id=artifact_id, step=entry.get("name")):
                    self.assertEqual(selected(entry.get("if"), context=context), not artifact_id)
            restore = step(release, "Restore this run's prepared release")
            self.assertEqual(selected(restore["if"], context=context), bool(artifact_id))
            for name in ("Verify the saved release generation", "Fill the draft release, then make it public"):
                self.assertTrue(selected(step(release, name).get("if"), context=context))
        restore = step(release, "Restore this run's prepared release")
        self.assertEqual(
            restore["with"],
            {"artifact-ids": "${{ steps.prepared.outputs.artifact_id }}", "merge-multiple": True, "path": "."},
        )
        upload = step(release, "Save this run's prepared release")["with"]
        self.assertEqual(upload["name"], RELEASE.PREPARED_ARTIFACT)
        self.assertIs(upload["overwrite"], False)
        self.assertEqual(upload["if-no-files-found"], "error")
        self.assertEqual(
            upload["path"].splitlines(),
            ["release-assets/", str(RELEASE.FACTS), str(RELEASE.NOTES), str(RELEASE.PREPARED)],
        )


if __name__ == "__main__":
    unittest.main()
