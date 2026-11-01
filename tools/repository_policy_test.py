"""The repository policy command compares GitHub's settings and rulesets with the committed policy.

These tests drive tools/repository-policy.py against a fake gh that behaves
like the GitHub endpoints the command uses. The fake starts as a repository
that matches .github/repository-policy.json and every committed ruleset, then
each test drifts one thing. They prove that a matching repository reports ok
and writes nothing, that every subject names its drift, that --apply writes
only what differs and then reads the subject again, that an unmanaged ruleset
is reported and never deleted, and that one failed subject does not stop the
rest. A failure here means the maintainer could believe a protection holds when
it does not, or that --apply changed more than the policy asked. The tests do
not reach GitHub, so they say nothing about what the live endpoints accept.
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from repository_policy_fake import (
    ADMINISTRATOR_FIELDS,
    COMMAND,
    DRIFTS,
    ROOT,
    SUBJECTS,
    FakeGitHub,
    add_stray,
    committed_rulesets,
    drop_a_rule,
    first_ruleset,
    line,
    policy,
    read_as_the_promotion_app,
    remove_ruleset,
    run_command,
    text,
)


class PolicyFileTest(unittest.TestCase):
    def test_policy_file_names_every_subject(self):
        self.assertEqual(
            set(policy()),
            {
                "repository",
                "security_and_analysis",
                "vulnerability_alerts",
                "private_vulnerability_reporting",
                "immutable_releases",
                "actions",
                "code_scanning_default_setup",
                "rulesets",
            },
        )

    def test_rulesets_directory_holds_complete_rulesets(self):
        files = sorted((ROOT / policy()["rulesets"]).glob("*.json"))
        self.assertGreaterEqual(len(files), 3)
        for path in files:
            with self.subTest(path.name):
                self.assertGreaterEqual(set(json.loads(path.read_text())), {"name", "target", "conditions", "rules"})

    def test_every_subject_has_a_drift_case(self):
        self.assertEqual(set(DRIFTS), set(SUBJECTS))


class ReadOnlyTest(unittest.TestCase):
    def test_matching_repository_is_ok_and_writes_nothing(self):
        github = FakeGitHub()
        status, lines = run_command(github)
        self.assertEqual((status, lines), (0, [line(subject, "ok") for subject in SUBJECTS]))
        self.assertEqual(github.writes(), [])
        self.assertEqual(github.reads().count(""), 1, "repository and security share one read")

    def test_each_subject_names_its_drift(self):
        for subject, (drift, expected) in DRIFTS.items():
            with self.subTest(subject):
                github = FakeGitHub()
                drift(github)
                status, lines = run_command(github)
                self.assertEqual(status, 1)
                self.assertEqual(lines, [line(name, expected if name == subject else "ok") for name in SUBJECTS])
                self.assertEqual(github.writes(), [])

    def test_missing_and_unmanaged_rulesets_are_drift(self):
        name = first_ruleset()
        for subject, drift, expected in (
            ("missing", remove_ruleset, f"drift: {name} missing"),
            ("unmanaged", add_stray, "drift: unmanaged stray"),
        ):
            with self.subTest(subject):
                github = FakeGitHub()
                drift(github)
                self.assertEqual(run_command(github, "rulesets"), (1, [line("rulesets", expected)]))
                self.assertEqual(github.writes(), [])

    def test_read_only_mode_never_writes_even_with_everything_drifted(self):
        github = FakeGitHub()
        for drift, _ in DRIFTS.values():
            drift(github)
        add_stray(github)
        status, _ = run_command(github)
        self.assertEqual(status, 1)
        self.assertEqual(github.writes(), [])

    def test_subject_selection_reads_only_the_chosen_subjects(self):
        github = FakeGitHub()
        status, lines = run_command(github, "vulnerability-alerts", "actions")
        self.assertEqual((status, lines), (0, [line("vulnerability-alerts", "ok"), line("actions", "ok")]))
        self.assertEqual(
            sorted(github.reads()),
            sorted(
                [
                    "vulnerability-alerts",
                    "actions/permissions",
                    "actions/permissions/workflow",
                    "actions/permissions/fork-pr-contributor-approval",
                ]
            ),
        )
        github = FakeGitHub()
        _, lines = run_command(github, "actions", "repository")
        self.assertEqual(lines, [line("repository", "ok"), line("actions", "ok")])

    def test_unknown_subject_is_refused_before_any_gh_call(self):
        github = FakeGitHub()
        status, lines = run_command(github, "branches")
        self.assertEqual((status, lines, github.calls), (2, [], []))


class ApplyTest(unittest.TestCase):
    def apply(self, github, *subjects):
        return run_command(github, "--apply", *subjects)

    def test_repository_patch_holds_only_the_differing_key(self):
        github = FakeGitHub()
        github.repo.update(has_wiki=True)
        status, lines = self.apply(github, "repository")
        self.assertEqual(github.writes(), [("PATCH", "", {"has_wiki": False})])
        self.assertEqual((status, lines), (0, [line("repository", "applied has_wiki"), line("repository", "ok")]))
        self.assertEqual(github.reads(), ["", ""], "the subject is read again after the write")

    def test_security_patch_uses_the_nested_form(self):
        github = FakeGitHub()
        github.repo["security_and_analysis"]["secret_scanning_push_protection"]["status"] = "disabled"
        status, lines = self.apply(github, "security")
        self.assertEqual(
            github.writes(),
            [("PATCH", "", {"security_and_analysis": {"secret_scanning_push_protection": {"status": "enabled"}}})],
        )
        self.assertEqual((status, lines[-1]), (0, line("security", "ok")))

    def test_disabled_vulnerability_alerts_get_a_put(self):
        github = FakeGitHub()
        github.alerts = False
        status, lines = self.apply(github, "vulnerability-alerts")
        self.assertEqual(github.writes(), [("PUT", "vulnerability-alerts", None)])
        self.assertEqual((status, lines[-1]), (0, line("vulnerability-alerts", "ok")))

    def test_immutable_releases_follow_the_policy_in_both_directions(self):
        github = FakeGitHub()
        github.immutable["enabled"] = False
        status, lines = self.apply(github, "immutable-releases")
        self.assertEqual(github.writes(), [("PUT", "immutable-releases", None)])
        self.assertEqual((status, lines[-1]), (0, line("immutable-releases", "ok")))
        with tempfile.TemporaryDirectory() as temp:
            relaxed = Path(temp) / "repository-policy.json"
            relaxed.write_text(json.dumps({**policy(), "immutable_releases": False}))
            github = FakeGitHub()
            status, lines = run_command(github, "--apply", "immutable-releases", policy_file=relaxed)
            self.assertEqual(github.writes(), [("DELETE", "immutable-releases", None)])
            self.assertEqual((status, lines[-1]), (0, line("immutable-releases", "ok")))

    def test_fork_approval_policy_sends_exactly_one_put(self):
        github = FakeGitHub()
        github.fork["approval_policy"] = "first_time_contributors"
        status, lines = self.apply(github, "actions")
        self.assertEqual(
            github.writes(),
            [
                (
                    "PUT",
                    "actions/permissions/fork-pr-contributor-approval",
                    {"approval_policy": "all_external_contributors"},
                )
            ],
        )
        self.assertEqual((status, lines[-1]), (0, line("actions", "ok")))

    def test_workflow_permissions_put_holds_both_workflow_keys(self):
        github = FakeGitHub()
        github.workflow.update(can_approve_pull_request_reviews=True)
        github.permissions.update(sha_pinning_required=False)
        status, _ = self.apply(github, "actions")
        self.assertEqual(status, 0)
        self.assertEqual(
            github.writes(),
            [
                (
                    "PUT",
                    "actions/permissions",
                    {"enabled": True, "allowed_actions": "all", "sha_pinning_required": True},
                ),
                (
                    "PUT",
                    "actions/permissions/workflow",
                    {"default_workflow_permissions": "read", "can_approve_pull_request_reviews": False},
                ),
            ],
        )

    def test_code_scanning_patch_holds_the_policy_keys(self):
        github = FakeGitHub()
        github.scanning.update(state="not-configured")
        status, _ = self.apply(github, "code-scanning")
        self.assertEqual(status, 0)
        self.assertEqual(
            github.writes(), [("PATCH", "code-scanning/default-setup", policy()["code_scanning_default_setup"])]
        )

    def test_differing_ruleset_is_replaced_by_its_committed_body(self):
        github = FakeGitHub()
        name = first_ruleset()
        ruleset_id = github.ruleset_id(name)
        drop_a_rule(github)
        status, lines = self.apply(github, "rulesets")
        self.assertEqual(github.writes(), [("PUT", f"rulesets/{ruleset_id}", committed_rulesets()[name])])
        self.assertEqual((status, lines), (0, [line("rulesets", f"applied {name} updated"), line("rulesets", "ok")]))

    def test_missing_ruleset_is_created_from_its_committed_body(self):
        github = FakeGitHub()
        name = first_ruleset()
        remove_ruleset(github)
        status, lines = self.apply(github, "rulesets")
        self.assertEqual(github.writes(), [("POST", "rulesets", committed_rulesets()[name])])
        self.assertEqual((status, lines[-1]), (0, line("rulesets", "ok")))

    def test_unmanaged_ruleset_is_reported_and_never_deleted(self):
        github = FakeGitHub()
        add_stray(github)
        status, lines = self.apply(github, "rulesets")
        self.assertEqual((status, lines), (1, [line("rulesets", "drift: unmanaged stray")]))
        self.assertEqual(github.writes(), [])

    def test_apply_on_a_matching_repository_writes_nothing(self):
        github = FakeGitHub()
        status, lines = self.apply(github)
        self.assertEqual((status, lines), (0, [line(subject, "ok") for subject in SUBJECTS]))
        self.assertEqual(github.writes(), [])

    def test_failed_write_is_reported_and_the_next_subject_still_runs(self):
        github = FakeGitHub()
        github.repo.update(has_wiki=True)
        github.failures[("PATCH", "")] = "gh: Resource not accessible (HTTP 403)"
        status, lines = self.apply(github, "repository", "vulnerability-alerts")
        self.assertEqual(status, 1)
        self.assertEqual(
            lines,
            [
                line("repository", "cannot apply: gh: Resource not accessible (HTTP 403)"),
                line("vulnerability-alerts", "ok"),
            ],
        )


class FailureTest(unittest.TestCase):
    def test_failed_read_is_reported_and_later_subjects_still_report(self):
        github = FakeGitHub()
        github.failures[("GET", "vulnerability-alerts")] = "HTTP 403"
        status, lines = run_command(github, "security", "vulnerability-alerts", "private-vulnerability-reporting")
        self.assertEqual(status, 1)
        self.assertEqual(
            lines,
            [
                line("security", "ok"),
                line("vulnerability-alerts", "cannot read: HTTP 403"),
                line("private-vulnerability-reporting", "ok"),
            ],
        )

    def test_missing_policy_file_is_reported_for_every_selected_subject(self):
        github = FakeGitHub()
        with tempfile.TemporaryDirectory() as temp:
            status, lines = run_command(github, "repository", "rulesets", policy_file=Path(temp) / "absent.json")
        self.assertEqual(status, 1)
        self.assertEqual(
            [text.split(": cannot read: ")[0] for text in lines],
            [line("repository", "").rstrip(": "), line("rulesets", "").rstrip(": ")],
        )
        self.assertEqual(github.writes(), [])

    def test_missing_key_in_an_answer_is_cannot_read_not_a_traceback(self):
        github = FakeGitHub()
        del github.repo["has_wiki"]
        status, lines = run_command(github, "repository")
        self.assertEqual(
            (status, lines), (1, [line("repository", "cannot read: the policy or the answer has no has_wiki")])
        )

    def test_an_administrator_missing_an_administrator_field_is_a_failed_read(self):
        github = FakeGitHub()
        del github.repo["delete_branch_on_merge"]
        del github.rulesets[github.ruleset_id(first_ruleset())]["bypass_actors"]
        status, lines = run_command(github, "repository", "rulesets")
        self.assertEqual(status, 1)
        self.assertEqual(
            lines,
            [
                line("repository", "cannot read: the policy or the answer has no delete_branch_on_merge"),
                line("rulesets", "cannot read: the policy or the answer has no bypass_actors"),
            ],
        )


class ReaderTest(unittest.TestCase):
    """The weekly run reads with the promotion app's token, which administers nothing."""

    def test_hidden_fields_are_named_as_unchecked_and_the_rest_is_ok(self):
        github = FakeGitHub()
        read_as_the_promotion_app(github)
        status, lines = run_command(github)
        self.assertEqual(status, 0)
        self.assertEqual(github.writes(), [])
        expected = []
        for subject in SUBJECTS:
            expected.append(line(subject, "ok"))
            if subject == "repository":
                expected.append(
                    line(
                        subject,
                        f"unchecked: {', '.join(ADMINISTRATOR_FIELDS)}, which GitHub shows only to an administrator",
                    )
                )
            if subject == "rulesets":
                hidden = ", ".join(f"{name} bypass_actors" for name in committed_rulesets())
                expected.append(line(subject, f"unchecked: {hidden}, which GitHub shows only to an administrator"))
        self.assertEqual(lines, expected)

    def test_a_reader_still_sees_drift_in_what_it_can_read(self):
        github = FakeGitHub()
        read_as_the_promotion_app(github)
        github.repo.update(has_wiki=True)
        drop_a_rule(github)
        status, lines = run_command(github, "repository", "rulesets")
        self.assertEqual(status, 1)
        self.assertIn(line("repository", "drift: has_wiki is true and the policy says false"), lines)
        self.assertIn(line("rulesets", f"drift: {first_ruleset()} differs in rules"), lines)

    def test_an_answer_without_permissions_reads_as_no_administrator(self):
        github = FakeGitHub()
        read_as_the_promotion_app(github)
        del github.repo["permissions"]
        status, lines = run_command(github, "repository")
        self.assertEqual(status, 0)
        self.assertEqual(lines[0], line("repository", "ok"))
        self.assertTrue(lines[1].startswith(line("repository", "unchecked: ")))

    def test_unnamed_repository_is_reported_per_subject(self):
        def refuse(*args, input=None):
            raise subprocess.CalledProcessError(1, ["gh"], stderr="gh: not logged in")

        status, lines = run_command(refuse, "repository", "actions")
        self.assertEqual(status, 1)
        self.assertEqual(
            lines,
            [line("repository", "cannot read: gh: not logged in"), line("actions", "cannot read: gh: not logged in")],
        )

    def test_output_is_plain_sentences(self):
        github = FakeGitHub()
        for drift, _ in DRIFTS.values():
            drift(github)
        add_stray(github)
        _, lines = run_command(github)
        for printed in lines:
            with self.subTest(printed):
                self.assertFalse(set(printed) & {"—", ";"})


class GhTest(unittest.TestCase):
    def test_gh_runs_from_the_checkout_root_with_a_deadline(self):
        with mock.patch.object(COMMAND.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout="out")
            self.assertEqual(COMMAND.gh("api", "repos/x", input="{}"), "out")
        run.assert_called_once_with(
            ["gh", "api", "repos/x"],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=COMMAND.ROOT,
            input="{}",
        )
        self.assertEqual(COMMAND.ROOT, ROOT)

    def test_api_parses_json_and_treats_empty_output_as_none(self):
        with mock.patch.object(COMMAND, "gh", return_value='{"a": 1}'):
            self.assertEqual(COMMAND.api("GET", "repos/x"), {"a": 1})
        with mock.patch.object(COMMAND, "gh", return_value=""):
            self.assertIsNone(COMMAND.api("PUT", "repos/x", {"a": 1}))

    def test_api_sends_the_body_on_stdin(self):
        with mock.patch.object(COMMAND, "gh", return_value="") as gh:
            COMMAND.api("PATCH", "repos/x", {"a": 1})
        gh.assert_called_once_with("api", "-X", "PATCH", "repos/x", "--input", "-", input='{"a": 1}')

    def test_the_workflow_reads_weekly_and_only_reports(self):
        source = text(".github/workflows/repository-policy.yml")
        self.assertIn("\npermissions: {}\n", source)
        self.assertIn("  schedule:\n    - cron: ", source)
        self.assertIn("  push:\n    branches: [dev]\n    paths:\n", source)
        for path in (".github/repository-policy.json", ".github/rulesets/**", "tools/repository-policy.py"):
            self.assertIn(f"      - {path}\n", source)
        body = source.split("\njobs:\n  drift:\n", 1)[1]
        # The workflow token holds nothing, and the app token reads. GitHub
        # shows bypass actors and merge settings only to an administrator, so
        # the weekly reading reports those as unchecked, and a change on
        # GitHub is the maintainer's --apply.
        self.assertNotIn("    permissions:", body)
        self.assertIn("          permission-administration: read\n          permission-security-events: read\n", body)
        self.assertEqual(body.count("write"), 0)
        self.assertIn("persist-credentials: false", body)
        self.assertIn("run: python3 tools/repository-policy.py\n", body)
        self.assertNotIn("--apply", body)


if __name__ == "__main__":
    unittest.main()
