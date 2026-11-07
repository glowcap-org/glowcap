"""publish.yml publishes registry packages only from a verified public release.

Read the workflow's own jobs: every registry job runs in its environment after
the contract job, with an OIDC token where the registry binds one and with the
catalog account's secrets for the Racket catalog, and the registry steps skip a
version the registry already holds. The crate step runs with stub curl and
cargo. This does not reach a registry or GitHub runners.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from workflows import jobs, run, step, text, workflow

PUBLISH = ".github/workflows/publish.yml"
RELEASE = ".github/workflows/release.yml"
REGISTRY_JOBS = {"pypi": "pypi", "crates-io": "crates-io", "jsr": "jsr", "racket": "racket"}
OIDC = {"contents": "read", "id-token": "write"}
VALIDATE = ".github/workflows/validate-release.yml"


class PublishWorkflow(unittest.TestCase):
    def test_registry_jobs_follow_the_contract_in_their_environments(self):
        publish = workflow(PUBLISH)
        found = publish["jobs"]
        self.assertEqual(set(found), {"contract", *REGISTRY_JOBS})
        self.assertEqual(publish["permissions"], {"contents": "read"})
        self.assertIn("workflow_dispatch", publish["on"])
        for name, environment in REGISTRY_JOBS.items():
            job = found[name]
            with self.subTest(job=name):
                self.assertEqual(job["needs"], "contract")
                self.assertEqual(job["environment"], environment)
                self.assertEqual(job["permissions"], {"contents": "read"} if name == "racket" else OIDC)
                checkouts = [item for item in job["steps"] if item.get("uses", "").startswith("actions/checkout@")]
                refs = [item["with"]["ref"] for item in checkouts]
                self.assertEqual(refs, ["${{ needs.contract.outputs.commit }}"])
                scripts = [item.get("run", "") for item in job["steps"]]
                self.assertTrue([script for script in scripts if 'binding_packages.py --registry "$VERSION"' in script])
        contract = found["contract"]
        self.assertNotIn("id-token", json.dumps(contract))
        verify = run(contract, "Verify the public release behind the tag")
        self.assertEqual(verify, 'python3 ci/github_release.py published "$RELEASE_TAG"')
        self.assertEqual(contract["steps"][0]["with"]["ref"], "refs/tags/${{ inputs.tag }}")

    def test_registry_steps_skip_a_version_the_registry_holds(self):
        found = jobs(PUBLISH)
        self.assertIs(step(found["pypi"], "Publish to PyPI")["with"]["skip-existing"], True)
        self.assertEqual(run(found["jsr"], "Publish the workspace packages"), "deno publish")
        source = text(PUBLISH)
        self.assertNotIn("--allow-dirty", source)
        self.assertNotIn("--dry-run", source)
        script = run(found["crates-io"], "Publish the crate")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "calls"
            for tool in ("curl", "cargo"):
                stub = directory / tool
                stub.write_text(
                    f'#!/bin/sh\necho "{tool} $*" >> "$CALL_LOG"\n'
                    + ('printf "%s" "$CURL_STATUS"\n' if tool == "curl" else "")
                )
                stub.chmod(0o755)
            for status, published, accepted in (("200", False, True), ("404", True, True), ("500", False, False)):
                with self.subTest(status=status):
                    log.write_text("")
                    environment = dict(
                        os.environ,
                        PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                        CALL_LOG=str(log),
                        CURL_STATUS=status,
                        VERSION="0.1.1",
                        GITHUB_REPOSITORY="owner/project",
                    )
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", script],
                        cwd=directory,
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    calls = log.read_text()
                    self.assertIn("crates/glowcap/0.1.1", calls)
                    self.assertEqual("cargo publish" in calls, published)

    def test_the_racket_job_edits_the_catalog_with_its_environment_secrets_then_installs(self):
        job = jobs(PUBLISH)["racket"]
        self.assertNotIn("id-token", json.dumps(job))
        publish = step(job, "Point the catalog at the release's binding archive")
        self.assertEqual(publish["run"], 'python3 ci/racket_catalog.py publish "$RELEASE_TAG"')
        self.assertEqual(
            publish["env"],
            {
                "RELEASE_TAG": "${{ inputs.tag }}",
                "RACKET_CATALOG_EMAIL": "${{ secrets.RACKET_CATALOG_EMAIL }}",
                "RACKET_CATALOG_PASSWORD": "${{ secrets.RACKET_CATALOG_PASSWORD }}",
            },
        )
        names = [item.get("name") for item in job["steps"]]
        self.assertLess(names.index(publish["name"]), names.index("Install the published version in a fresh consumer"))
        self.assertEqual(
            run(job, "Install the published version in a fresh consumer"),
            'python3 tools/check/binding_packages.py --registry "$VERSION" racket',
        )
        # The consumer is a reader's Racket, pinned with the toolchain, in both
        # workflows that install from the catalog.
        for path, name in ((PUBLISH, "racket"), (VALIDATE, "registries")):
            with self.subTest(path):
                setups = [
                    item
                    for item in jobs(path)[name]["steps"]
                    if item.get("uses", "").startswith("Bogdanp/setup-racket@")
                ]
                self.assertEqual(len(setups), 1)
                self.assertRegex(setups[0]["uses"], r"@[0-9a-f]{40}$")
                self.assertEqual(setups[0]["with"]["version"], "${{ steps.pins.outputs.racket }}")
        pins = workflow(".github/actions/pins/action.yml")
        self.assertIn("racket", pins["outputs"])
        self.assertIn("RACKET_VERSION", pins["runs"]["steps"][0]["run"])

    def test_the_contract_job_alone_requires_the_tag_of_its_checkout(self):
        found = jobs(PUBLISH)
        named = "Require the tag's version"
        holders = [name for name, job in found.items() for item in job["steps"] if item.get("name") == named]
        self.assertEqual(holders, ["contract"])
        script = run(found["contract"], "Require the tag's version")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "bindings").mkdir()
            (directory / "bindings/c-abi-resolve.json").write_text(json.dumps({"abi_version": "0.1.1"}))
            for tag, accepted in (("v0.1.1", True), ("v0.1.0", False), ("0.1.1", False)):
                with self.subTest(tag=tag):
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", script],
                        cwd=directory,
                        env=dict(os.environ, RELEASE_TAG=tag),
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_release_dispatches_publication_after_the_release_is_public(self):
        release = jobs(RELEASE)["release"]
        self.assertEqual(release["permissions"]["actions"], "write")
        scripts = [item.get("run", "") for item in release["steps"]]
        publish = [index for index, script in enumerate(scripts) if "--draft=false" in script]
        dispatch = [index for index, script in enumerate(scripts) if "gh workflow run publish.yml" in script]
        self.assertEqual(len(publish), 1)
        self.assertEqual(len(dispatch), 1)
        self.assertLess(publish[0], dispatch[0])
        script = run(release, "Publish the language packages at the tag")
        self.assertEqual(script, scripts[dispatch[0]])
        self.assertTrue(script.startswith("gh workflow run publish.yml"))
        self.assertIn('--ref "refs/tags/$RELEASE_TAG" -f tag="$RELEASE_TAG"', script)


if __name__ == "__main__":
    unittest.main()
