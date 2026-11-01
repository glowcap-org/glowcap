"""The branch rulesets and promote.yml, which moves main, for infrastructure-check.

The fast-forward step runs against a stub `gh` that answers the compare
call; nothing here reaches GitHub.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from workflows import jobs, on_path, selected, shell_step, stub, text

CHECK = ".github/workflows/check.yml"
PROMOTE = ".github/workflows/promote.yml"


def ruleset(name):
    return json.loads(text(f".github/rulesets/{name}.json"))


class ProtectionTest(unittest.TestCase):
    def test_protection_is_signed_linear_and_checked_on_push(self):
        # main moves only by fast-forward from dev, so the checks a candidate
        # needs come from full validation on that exact dev commit.
        push_to_dev = {"event_name": "push", "ref": "refs/heads/dev"}
        for branch in ("main", "dev"):
            policy = ruleset(branch)
            self.assertEqual(policy["target"], "branch")
            self.assertEqual(policy["enforcement"], "active")
            # An agent's branch commits are unsigned, so the administrator may
            # merge a pull request into dev: GitHub signs the squash commit it
            # creates. Nothing bypasses a push, and nothing bypasses main.
            self.assertEqual(
                policy["bypass_actors"],
                []
                if branch == "main"
                else [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
            )
            self.assertEqual(policy["conditions"]["ref_name"], {"include": [f"refs/heads/{branch}"], "exclude": []})
            rules = {rule["type"]: rule.get("parameters", {}) for rule in policy["rules"]}
            linear_signed = {"non_fast_forward", "deletion", "required_linear_history", "required_signatures"}
            if branch == "dev":
                self.assertEqual(set(rules), linear_signed)
                continue
            self.assertEqual(set(rules), linear_signed | {"required_status_checks"})
            checks = rules["required_status_checks"]
            self.assertTrue(checks["strict_required_status_checks_policy"])
            found = jobs(CHECK)
            for check in checks["required_status_checks"]:
                self.assertGreater(check["integration_id"], 0)
                self.assertIn(check["context"], found)
                self.assertTrue(selected(found[check["context"]].condition, push_to_dev))
            self.assertEqual(
                {check["context"] for check in checks["required_status_checks"]}, {"gates", "macos-runtime"}
            )
            self.assertIn(
                "name: ${{ needs.plan.outputs.full == 'true' && 'gates' || 'dev-gates' }}", found["gates"].body
            )
        # Only the repository's administrator creates a release tag, and once
        # pushed it names a signed commit that can neither move nor disappear,
        # for the administrator too: the immutability ruleset has no bypass.
        creation, immutability = ruleset("tags"), ruleset("tag-immutability")
        for policy in (creation, immutability):
            self.assertEqual(policy["target"], "tag")
            self.assertEqual(policy["enforcement"], "active")
            self.assertEqual(policy["conditions"]["ref_name"], {"include": ["refs/tags/v*"], "exclude": []})
        self.assertEqual({rule["type"] for rule in creation["rules"]}, {"creation"})
        self.assertEqual(
            creation["bypass_actors"], [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
        )
        self.assertEqual(
            {rule["type"] for rule in immutability["rules"]},
            {"deletion", "update", "non_fast_forward", "required_signatures"},
        )
        self.assertEqual(immutability["bypass_actors"], [])
        self.assertIn('tags: ["v*"]', text(".github/workflows/release.yml"))


class PromoteTest(unittest.TestCase):
    def test_promotion_configuration_refuses_missing_credentials_without_exposing_them(self):
        source = text(PROMOTE)
        command = shell_step(source, "Require promotion app configuration")
        self.assertLess(
            source.index("Require promotion app configuration"), source.index("Mint the promotion app's token")
        )
        for client, key in [
            ("", ""),
            ("test-client", ""),
            ("", "private-test-key"),
            ("test-client", "private-test-key"),
        ]:
            with self.subTest(client=bool(client), key=bool(key)):
                result = subprocess.run(
                    ["bash", "-e", "-c", command],
                    capture_output=True,
                    text=True,
                    env=dict(os.environ, CLIENT_ID=client, PRIVATE_KEY=key),
                )
                self.assertEqual(result.returncode == 0, bool(client and key))
                self.assertNotIn("private-test-key", result.stdout + result.stderr)
                if result.returncode:
                    self.assertIn("docs/maintaining.md#promotion-app", result.stdout)

    def promote(self, relation, status=0):
        script = shell_step(text(PROMOTE), "Fast-forward main")
        with tempfile.TemporaryDirectory() as temporary:
            stub(
                temporary,
                "gh",
                """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['PROMOTE_CALL'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if any('/compare/' in argument for argument in sys.argv):
    if int(os.environ['PROMOTE_STATUS']):
        sys.exit(int(os.environ['PROMOTE_STATUS']))
    print(os.environ['PROMOTE_RELATION'])
""",
            )
            call = Path(temporary) / "call.json"
            environment = on_path(
                temporary,
                GITHUB_REPOSITORY="owner/project",
                CANDIDATE="a" * 40,
                GH_TOKEN="test-token",
                PROMOTE_CALL=str(call),
                PROMOTE_RELATION=relation,
                PROMOTE_STATUS=str(status),
            )
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c", script],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
            )
            calls = [json.loads(line) for line in call.read_text().splitlines()] if call.exists() else []
            return result, calls

    def test_promotion_fast_forwards_main_to_a_checked_dev_push(self):
        workflow = text(PROMOTE)
        self.assertIn(
            "\non:\n  workflow_run:\n    workflows: [check]\n    types: [completed]\n"
            "    branches: [dev]\n\npermissions: {}\n",
            workflow,
        )
        self.assertNotIn("actions/checkout", workflow)
        condition, body = jobs(PROMOTE)["main"]
        # The workflow token holds nothing. The app token carries the two
        # permissions a fast-forward across workflow-file changes needs.
        self.assertNotIn("    permissions:", body)
        self.assertIn(
            "        with:\n          client-id: ${{ vars.PROMOTE_APP_CLIENT_ID }}\n"
            "          private-key: ${{ secrets.PROMOTE_APP_PRIVATE_KEY }}\n"
            "          permission-contents: write\n          permission-workflows: write\n",
            body,
        )
        self.assertIn("          GH_TOKEN: ${{ steps.app.outputs.token }}\n", body)
        self.assertNotIn("github.token", workflow)
        run = {"event": "push", "conclusion": "success", "head_repository": {"full_name": "owner/project"}}

        def context(**change):
            return {"repository": "owner/project", "event": {"workflow_run": dict(run, **change)}}

        self.assertTrue(selected(condition, context()))
        for change in (
            {"event": "pull_request"},
            {"event": "schedule"},
            {"event": "workflow_dispatch"},
            {"conclusion": "failure"},
            {"conclusion": "cancelled"},
            {"head_repository": {"full_name": "fork/project"}},
        ):
            with self.subTest(change=change):
                self.assertFalse(selected(condition, context(**change)))

        # pages.yml deploys on the push this move makes.
        self.assertIn("\non:\n  push:\n    branches: [main]\n", text(".github/workflows/pages.yml"))
        result, calls = self.promote("ahead")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls,
            [
                ["api", "repos/owner/project/compare/main..." + "a" * 40, "--jq", ".status"],
                [
                    "api",
                    "--method",
                    "PATCH",
                    "repos/owner/project/git/refs/heads/main",
                    "-f",
                    "sha=" + "a" * 40,
                    "-F",
                    "force=false",
                ],
            ],
        )
        # A rerun of an older run finds main past its commit and moves nothing.
        for relation in ("identical", "behind"):
            with self.subTest(relation=relation):
                result, calls = self.promote(relation)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 1)
        for relation, status in (("diverged", 0), ("", 0), ("ahead", 4)):
            with self.subTest(relation=relation, status=status):
                result, calls = self.promote(relation, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
