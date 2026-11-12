"""publish.yml publishes registry packages only from a verified public release.

Read the workflow's own jobs: every registry job runs in its environment after
the contract job, with an OIDC token where the registry binds one and with the
catalog account's secrets for the Racket catalog, and the registry steps skip a
version the registry already holds, the crate's through ci/crate_publish.py.
This does not reach a registry or GitHub runners.
"""

import json
import unittest

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
        self.assertEqual(run(found["crates-io"], "Publish the crate"), "python3 ci/crate_publish.py")

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
        # github_release_test holds the rule itself; the step hands it the tag.
        self.assertEqual(run(found["contract"], named), 'python3 ci/github_release.py version "$RELEASE_TAG"')
        self.assertEqual(step(found["contract"], named)["env"]["RELEASE_TAG"], "${{ inputs.tag }}")

    def test_dispatches_at_one_tag_wait_for_each_other(self):
        self.assertEqual(
            workflow(PUBLISH)["concurrency"], {"group": "publish-${{ inputs.tag }}", "cancel-in-progress": False}
        )

    def test_release_dispatches_publication_after_the_release_is_public(self):
        release = jobs(RELEASE)["release"]
        self.assertEqual(release["permissions"]["actions"], "write")
        scripts = [item.get("run", "") for item in release["steps"]]
        publish = [index for index, script in enumerate(scripts) if "github_release.py publish-draft" in script]
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
