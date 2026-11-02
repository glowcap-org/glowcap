"""The shape of the workflow files that zizmor does not audit.

zizmor (check.yml, the `workflows` job, configured in .github/zizmor.yml)
holds action pinning, credential persistence, template injection, release
cache poisoning, and the Dependabot cooldown. These tests hold what remains
this repository's own: no mapping repeats a key (GitHub refuses the file),
the audit's exception list names real files and is a required result, CI
logic is Python called by short steps, and the post-release validation keeps
its cost split between Linux and macOS.
"""

import re
import unittest

import yaml
from workflows import ROOT, WORKFLOWS, Loader, duplicate_mapping_keys, jobs, text, workflow

AUDITED = sorted(WORKFLOWS.glob("*.yml")) + sorted(ROOT.glob(".github/actions/*/action.yml"))
# An inline script is one command's flags or a few lines of glue. A longer
# one is a program, and a program lives in a file with its own test.
MAX_SCRIPT_LINES = 20


def scripts(path):
    """Every step script of a workflow or composite action."""
    document = workflow(path)
    owners = document["jobs"].values() if "jobs" in document else [document["runs"]]
    # A job that calls a reusable workflow has no steps.
    return [step["run"] for owner in owners for step in owner.get("steps", ()) if "run" in step]


class WorkflowAudit(unittest.TestCase):
    def test_the_audit_configuration_names_real_workflows(self):
        rules = workflow(".github/zizmor.yml")["rules"]
        # The reasons are comments, which only the text holds.
        blocks = dict(re.findall(r"(?m)^  ([\w-]+):\n((?:    [^\n]*\n)+)", text(".github/zizmor.yml")))
        self.assertTrue(rules)
        audited = {path.name for path in AUDITED}
        self.assertIn("action.yml", audited, "the composite actions zizmor audits beside the workflows")
        for rule, body in rules.items():
            with self.subTest(rule=rule):
                self.assertTrue({"ignore", "disable", "config"} & set(body))
                self.assertRegex(blocks[rule], r"(?m)^ +#", "each exception or policy states its reason")
                for name in body.get("ignore", ()):
                    self.assertIn(name, audited)
        self.assertIn("promote.yml", rules["dangerous-triggers"]["ignore"])

    def test_the_audit_is_a_required_check(self):
        found = jobs(".github/workflows/check.yml")
        audit = [step for step in found["workflows"]["steps"] if step.get("uses", "").startswith("zizmorcore/")]
        self.assertEqual(len(audit), 1)
        self.assertRegex(audit[0]["uses"], r"^zizmorcore/zizmor-action@[0-9a-f]{40}$")
        self.assertEqual(audit[0]["with"]["persona"], "regular")
        self.assertIn("workflows", found["gates"]["needs"])

    def test_workflows_repeat_no_mapping_key(self):
        self.assertEqual(
            duplicate_mapping_keys("a:\n  b: 1\n  b: 2\nc:\n  - d: 1\n    d: 2\n  - d: 3\n"), [(3, "b"), (6, "d")]
        )
        self.assertEqual(
            duplicate_mapping_keys("a:\n  b: 1\nc:\n  b: 2\n  run: |\n    x: 1\n    x: 2\n  run: 3\n"),
            [(8, "run")],
            "a block scalar holds text, and the key after it is still in its mapping",
        )
        self.assertEqual(
            duplicate_mapping_keys("a:\n  path: &p |\n    x: 1\n    x: 2\n  key: 1\n"),
            [],
            "an anchored block scalar holds text too",
        )
        with self.assertRaisesRegex(yaml.YAMLError, "repeated key 'b'"):
            yaml.load("a:\n  b: 1\n  b: 2\n", Loader)
        for path in AUDITED:
            with self.subTest(path=path.name):
                self.assertEqual(duplicate_mapping_keys(path.read_text()), [])
                workflow(path.relative_to(ROOT))

    def test_ci_logic_is_python_called_by_short_steps(self):
        self.assertEqual(list(ROOT.glob("ci/**/*.sh")), [])
        for path in AUDITED:
            with self.subTest(path=path.relative_to(ROOT)):
                longest = max(
                    (len(script.rstrip("\n").splitlines()) for script in scripts(path.relative_to(ROOT))), default=0
                )
                self.assertLessEqual(longest, MAX_SCRIPT_LINES)

    def test_release_validation_splits_hosts_by_cost(self):
        validation = workflow(".github/workflows/validate-release.yml")
        self.assertEqual(list(validation["on"]), ["schedule", "workflow_dispatch"])
        self.assertEqual(validation["permissions"], {"contents": "read"})
        found = validation["jobs"]
        self.assertEqual(list(found), ["newest", "installer-linux", "installer-macos", "registries"])
        self.assertEqual(found["installer-macos"]["if"], "github.event_name == 'workflow_dispatch'")
        self.assertNotIn("if", found["installer-linux"])
        for name in ("installer-linux", "installer-macos"):
            with self.subTest(job=name):
                self.assertEqual(found[name]["env"]["VERSION"], "${{ needs.newest.outputs.version }}")
                script = next(
                    step["run"] for step in found[name]["steps"] if step["name"] == "Run the installed product"
                )
                self.assertIn("glowcap version | tee version.txt", script)
                self.assertIn('grep -Fx "glowcap $VERSION" version.txt', script)
        checkout = found["registries"]["steps"][0]
        self.assertTrue(checkout["uses"].startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["ref"], "refs/tags/v${{ needs.newest.outputs.version }}")


if __name__ == "__main__":
    unittest.main()
