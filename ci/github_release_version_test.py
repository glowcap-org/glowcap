"""One rule reads a release version, and every release workflow calls it.

`github_release.py version` reads the tree's version or the newest published
release's, and refuses anything but 0.x.y. These tests drive it against a
written contract and a stubbed gh, then read the release, publish, and
validate-release workflows for the step that calls it. They do not reach
GitHub.
"""

import json
import unittest
from unittest import mock

import github_release as RELEASE
from github_release_test import REPOSITORY, run_main, workdir
from workflows import ROOT, jobs, run


class Version(unittest.TestCase):
    """The one release-tag rule release.yml, publish.yml, and validate-release.yml call."""

    def stated(self, root, value):
        (root / "bindings").mkdir(exist_ok=True)
        (root / "bindings/c-abi-resolve.json").write_text(json.dumps({} if value is None else {"abi_version": value}))

    def test_the_tree_states_a_prerelease_version_its_tag_must_name(self):
        for value, tag, accepted in [
            ("0.1.0", None, True),
            ("0.2.3", "v0.2.3", True),
            ("0.2.3", "v0.2.4", False),
            ("1.0.0", None, False),
            ("1.0.0-alpha.1", None, False),
            ("10.0.0", None, False),
            ("garbage", None, False),
            (None, None, False),
            (7, None, False),
        ]:
            with self.subTest(value=value, tag=tag), workdir() as root:
                self.stated(root, value)
                output = root / "output"
                output.write_text("")
                argv = ("version",) if tag is None else ("version", tag)
                if accepted:
                    run_main(*argv, GITHUB_OUTPUT=str(output))
                    self.assertEqual(output.read_text(), f"version={value}\n")
                else:
                    with self.assertRaises(ValueError):
                        run_main(*argv, GITHUB_OUTPUT=str(output))
                    self.assertEqual(output.read_text(), "", "a refusal writes no version")

    def test_the_newest_release_names_a_prerelease_version(self):
        for listed, accepted in [
            ([{"tagName": "v0.1.6"}], True),
            ([{"tagName": "v1.0.0"}], False),
            ([{"tagName": None}], False),
            ([], False),
        ]:
            with self.subTest(listed=listed), workdir() as root:
                output = root / "output"
                output.write_text("")
                with mock.patch.object(RELEASE.subprocess, "check_output", return_value=json.dumps(listed)) as gh:
                    if accepted:
                        run_main("version", "--newest", GITHUB_OUTPUT=str(output))
                        self.assertEqual(output.read_text(), "version=0.1.6\n")
                    else:
                        with self.assertRaises(ValueError):
                            run_main("version", "--newest", GITHUB_OUTPUT=str(output))
                        self.assertEqual(output.read_text(), "")
                self.assertEqual(gh.call_args.args[0][:4], ["gh", "release", "list", "--repo"])
                self.assertIn(REPOSITORY, gh.call_args.args[0])

    def test_every_workflow_reads_versions_through_the_one_rule(self):
        cases = [
            (
                ".github/workflows/release.yml",
                "contract",
                "Read the product version",
                "python3 ci/github_release.py version",
            ),
            (
                ".github/workflows/release.yml",
                "contract",
                "Require the tag of this version",
                'python3 ci/github_release.py version "$GITHUB_REF_NAME"',
            ),
            (
                ".github/workflows/publish.yml",
                "contract",
                "Require the tag's version",
                'python3 ci/github_release.py version "$RELEASE_TAG"',
            ),
            (
                ".github/workflows/validate-release.yml",
                "newest",
                "Read the newest release",
                "python3 ci/github_release.py version --newest",
            ),
        ]
        for path, job, name, command in cases:
            with self.subTest(path=path, step=name):
                self.assertEqual(run(jobs(path)[job], name), command)
        for path in {path for path, *_ in cases}:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                self.assertFalse("c-abi-resolve.json" in source or "jq " in source, "versions are read in one place")


if __name__ == "__main__":
    unittest.main()
