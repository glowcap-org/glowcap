"""The release page a stranger reads, rendered from the facts the assembly step records.

Builds a facts dictionary shaped like artifacts/release.json and renders it with
a fixture changelog. Checks every download link, the platform and runtime each
row names, the verification and install commands, the image digest line, the run
marker, and the refusal of facts that name a missing archive or a malformed
repository, tag, commit, run, or digest. The command line is exercised as a
subprocess. The workflow assertions read release.yml for the changelog contract
and the attestation of the published image. Nothing here reaches GitHub.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import release_notes as NOTES
from workflows import ROOT, jobs, run, step

SCRIPT = ROOT / "ci/release_notes.py"
TAG = "v0.1.0"
COMMIT = "a" * 40
IMAGE_DIGEST = "sha256:" + "b" * 64
REPOSITORY = "https://github.com/owner/project"
CHANGELOG = """# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-31

### Added

- The first tagged release.
- See the [guide](docs/x.md).

[Unreleased]: https://github.com/owner/project/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/owner/project/releases/tag/v0.1.0
"""


def facts(**changes):
    archives = [
        {
            "name": f"glowcap{'-c' if role == 'sdk' else ''}-{TAG}-{target}.tar.gz",
            "target": target,
            "role": role,
            "minimum_runtime": "macOS 15.0.0" if target.endswith("macos") else "glibc 2.39.0",
        }
        for target in NOTES.PLATFORMS
        for role in ("product", "sdk")
    ]
    return {
        "repository": REPOSITORY,
        "version": TAG[1:],
        "tag": TAG,
        "commit": COMMIT,
        "run": REPOSITORY + "/actions/runs/123",
        "archives": archives,
        **changes,
    }


class ReleaseNotes(unittest.TestCase):
    def render(self, directory, release=None, digest=IMAGE_DIGEST):
        changelog = Path(directory) / "CHANGELOG.md"
        changelog.write_text(CHANGELOG)
        return NOTES.render(release or facts(), digest, changelog)

    def test_every_download_has_a_role_platform_and_minimum_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            notes = self.render(temporary)
        base = f"{REPOSITORY}/releases/download/{TAG}"
        for archive in facts()["archives"]:
            self.assertIn(f"{base}/{archive['name']})", notes)
        for text in (
            "Apple Silicon",
            "macOS 15.0.0 or newer",
            "glibc 2.39.0 or newer",
            "The SDK does not contain the CLI or Rooms.",
            "curl -fsSL https://glowcap.org/install.sh | GLOWCAP_VERSION=0.1.0 sh",
            "archive=glowcap-v0.1.0-aarch64-macos.tar.gz",
            'gh attestation verify "$archive" --repo owner/project\n',
            'gh attestation verify "$archive" --repo owner/project --bundle "$archive.sigstore.json"',
            "./glowcap-unpacked/bin/glowcap install",
            "delete its directory under `~/.local/lib/glowcap/` and the\n`~/.local/bin/glowcap` link.",
            "ghcr.io/owner/project-rooms:v0.1.0 --http-bind=0.0.0.0",
            "127.0.0.1:8080:8080",
            f"The image's digest is `{IMAGE_DIGEST}`.",
            f"gh attestation verify oci://ghcr.io/owner/project-rooms@{IMAGE_DIGEST} --repo owner/project",
            f"[SPDX]({base}/glowcap-rooms-{TAG}.spdx.json)",
            "cargo add glowcap@=0.1.0",
            "pip install glowcap==0.1.0",
            "deno add jsr:@glowcap/runtime@0.1.0 jsr:@glowcap/tcp@0.1.0",
            "raco pkg install glowcap",
            f"[source package]({base}/glowcap-racket-{TAG}.zip)",
            f"[bindings guide]({REPOSITORY}/blob/{TAG}/bindings/README.md)",
            f"[project provenance]({REPOSITORY}/blob/{TAG}/PROVENANCE.md)",
            f"[changelog]({REPOSITORY}/blob/{TAG}/CHANGELOG.md)",
            "- The first tagged release.",
            f"Source commit: `{COMMIT}`. [Release run]({REPOSITORY}/actions/runs/123).",
            "<!-- glowcap-release-run: 123 -->",
        ):
            with self.subTest(text=text):
                self.assertIn(text, notes)
        self.assertLess(notes.index("# What changed in 0.1.0"), notes.index("# Choose a download"))
        self.assertNotIn("--predicate-type", notes)
        self.assertNotIn("--signer-workflow", notes)

    def test_the_page_reads_without_the_release_machinery(self):
        with tempfile.TemporaryDirectory() as temporary:
            notes = self.render(temporary).lower()
        for word in ("recheck", "recovery", "publish_run", "recheck_run", "publish_tag"):
            self.assertNotIn(word, notes)

    def test_changelog_links_name_the_tag_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            notes = self.render(temporary)
        self.assertIn(f"- See the [guide]({REPOSITORY}/blob/{TAG}/docs/x.md).", notes)
        links = NOTES.absolute_links("[guide](docs/x.md) [site](https://glowcap.org) [part](#anchor)", REPOSITORY, TAG)
        self.assertEqual(
            links, f"[guide]({REPOSITORY}/blob/{TAG}/docs/x.md) [site](https://glowcap.org) [part](#anchor)"
        )
        self.assertEqual(
            NOTES.absolute_links("[a](http://example.org/x)", REPOSITORY, TAG), "[a](http://example.org/x)"
        )

    def test_release_needs_its_changelog_entry_and_an_empty_unreleased_section(self):
        with tempfile.TemporaryDirectory() as temporary:
            changelog = Path(temporary) / "CHANGELOG.md"
            changelog.write_text(CHANGELOG)
            self.assertEqual(
                NOTES.changelog_section("0.1.0", changelog),
                "### Added\n\n- The first tagged release.\n- See the [guide](docs/x.md).\n",
            )
            with self.assertRaises(ValueError):
                NOTES.changelog_section("0.1.1", changelog)
            changelog.write_text(CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n- A pending change.\n"))
            with self.assertRaises(ValueError):
                NOTES.changelog_section("0.1.0", changelog)
            changelog.write_text(CHANGELOG.replace("## [0.1.0] - 2026-10-31", "## 0.1.0"))
            with self.assertRaises(ValueError):
                NOTES.changelog_section("0.1.0", changelog)
        self.assertTrue((ROOT / "CHANGELOG.md").is_file())
        workflow = jobs(".github/workflows/release.yml")
        self.assertLess(list(workflow).index("contract"), list(workflow).index("archives"))
        command = run(workflow["contract"], "Require the version's changelog entry")
        self.assertIn('release_notes.py --changelog "$VERSION"', command)

    def test_image_publication_is_attested_from_its_published_index(self):
        release = jobs(".github/workflows/release.yml")["release"]
        names = [found.get("name") for found in release["steps"]]
        publish = "Publish the versioned multi-platform Rooms image"
        attest = "Attest the image's build provenance"
        sbom = "Write the image's software bill of materials"
        sbom_attest = "Attest the image's software bill of materials"
        render = "Render the release page and download every provenance bundle"
        self.assertLess(names.index(publish), names.index(attest))
        self.assertLess(names.index(attest), names.index(sbom))
        self.assertLess(names.index(sbom), names.index(sbom_attest))
        self.assertLess(names.index(sbom_attest), names.index(render))
        digest = f"${{{{ steps.{step(release, publish)['id']}.outputs.digest }}}}"
        for name in (attest, sbom_attest):
            with self.subTest(step=name):
                self.assertEqual(step(release, name)["with"]["subject-digest"], digest, "the digest the publish output")
                self.assertIs(step(release, name)["with"]["push-to-registry"], True)

    def test_refuses_facts_that_would_mislead_a_reader(self):
        complete = facts()
        for label, release, digest in (
            (
                "missing sdk",
                facts(
                    archives=[a for a in complete["archives"] if (a["target"], a["role"]) != ("aarch64-macos", "sdk")]
                ),
                IMAGE_DIGEST,
            ),
            (
                "missing product",
                facts(
                    archives=[
                        a for a in complete["archives"] if (a["target"], a["role"]) != ("x86_64-linux", "product")
                    ]
                ),
                IMAGE_DIGEST,
            ),
            ("repository", facts(repository="https://example.org/owner/project"), IMAGE_DIGEST),
            ("tag differs from version", facts(version="0.1.1"), IMAGE_DIGEST),
            ("tag shape", facts(tag="0.1.0", version="0.1.0"), IMAGE_DIGEST),
            ("short commit", facts(commit="a" * 39), IMAGE_DIGEST),
            ("uppercase commit", facts(commit="A" * 40), IMAGE_DIGEST),
            ("run of another repository", facts(run="https://github.com/other/project/actions/runs/123"), IMAGE_DIGEST),
            ("run zero", facts(run=REPOSITORY + "/actions/runs/0"), IMAGE_DIGEST),
            ("run not a number", facts(run=REPOSITORY + "/actions/runs/abc"), IMAGE_DIGEST),
            ("short digest", complete, "sha256:" + "b" * 63),
            ("digest algorithm", complete, "sha512:" + "b" * 64),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(ValueError):
                    self.render(temporary, release, digest)

    def test_command_line_renders_or_refuses_without_partial_output(self):
        def run(*arguments):
            return subprocess.run(
                [sys.executable, str(script), *arguments], cwd=ROOT, capture_output=True, text=True, timeout=30
            )

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            # Keep the CLI's script-relative lookup, with a release-ready fixture.
            script = directory / "ci/release_notes.py"
            script.parent.mkdir()
            shutil.copyfile(SCRIPT, script)
            changelog = directory / "CHANGELOG.md"
            changelog.write_text(CHANGELOG)
            release = directory / "release.json"
            release.write_text(json.dumps(facts()))
            output = directory / "release-notes.md"
            version = TAG[1:]
            section = run("--changelog", version)
            self.assertEqual(section.returncode, 0, section.stderr)
            self.assertEqual(section.stdout, NOTES.changelog_section(version, changelog))
            for label, arguments in (
                ("changelog with facts", ("--changelog", version, "--facts", str(release))),
                ("facts without a digest", ("--facts", str(release), "--output", str(output))),
                ("facts without an output", ("--facts", str(release), "--image-digest", IMAGE_DIGEST)),
                ("no arguments", ()),
            ):
                with self.subTest(label):
                    result = run(*arguments)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertFalse(output.exists())
            result = run("--facts", str(release), "--image-digest", IMAGE_DIGEST, "--output", str(output))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"# What changed in {version}", output.read_text())
            self.assertIn("<!-- glowcap-release-run: 123 -->", output.read_text())
            output.unlink()
            changelog.write_text(CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n- Pending.\n"))
            for arguments in (
                ("--changelog", version),
                ("--facts", str(release), "--image-digest", IMAGE_DIGEST, "--output", str(output)),
            ):
                with self.subTest(arguments=arguments):
                    result = run(*arguments)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("still lists Unreleased changes", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(output.exists())
            changelog.write_text(CHANGELOG)
            release.write_text(json.dumps(facts(commit="nope")))
            result = run("--facts", str(release), "--image-digest", IMAGE_DIGEST, "--output", str(output))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release-notes: invalid source commit", result.stderr)
            self.assertFalse(output.exists())

    def test_workflow_renders_the_page_after_the_image_is_attested_and_before_the_draft(self):
        release = jobs(".github/workflows/release.yml")["release"]
        render = run(release, "Render the release page and download every provenance bundle")
        self.assertIn("--facts artifacts/release.json", render)
        self.assertIn('--image-digest "$IMAGE_DIGEST"', render)
        self.assertIn("--output artifacts/release-notes.md", render)
        names = [found.get("name") for found in release["steps"]]
        self.assertLess(
            names.index("Render the release page and download every provenance bundle"),
            names.index("Fill the draft release, then make it public"),
        )
        publish = run(release, "Fill the draft release, then make it public")
        self.assertIn("--notes-file artifacts/release-notes.md", publish)
        self.assertNotIn('--notes "', publish)
