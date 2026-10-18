"""Exercise workflow selection and publication for infrastructure-check.

Read the actual job conditions, not a second event selector. The evaluator
accepts only the boolean/string subset these predicates use and refuses new
syntax. Run actual publication guard steps with a stub Actions API. This does
not exercise GitHub runners or remote branch rules.
"""

import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def jobs(path):
    """Read named job blocks and their scalar or folded `if` conditions."""
    source = (ROOT / path).read_text().split("\njobs:\n", 1)[1]
    found = {}
    for match in re.finditer(r"^  ([\w-]+):\n((?: {4}[^\n]*\n|\n)*)", source, re.M):
        name, body = match.groups()
        condition = re.search(r"^    if: (.+)\n", body, re.M)
        if condition is None:
            continue
        expression = condition.group(1)
        if expression == ">-":
            following = body[condition.end():]
            lines = re.match(r"(?: {6}[^\n]*\n)+", following)
            if lines is None:
                raise AssertionError(f"{path}: {name} has no folded predicate")
            expression = " ".join(line.strip() for line in lines.group().splitlines())
        found[name] = (expression, body)
    return found


def selected(expression, github):
    expression = expression.replace("&&", " and ").replace("||", " or ")

    def evaluate(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool)):
            return node.value
        if isinstance(node, ast.Name) and node.id == "github":
            return github
        if isinstance(node, ast.Attribute):
            return evaluate(node.value).get(node.attr, {})
        if isinstance(node, ast.BoolOp):
            values = (evaluate(value) for value in node.values)
            if isinstance(node.op, ast.And):
                return all(values)
            if isinstance(node.op, ast.Or):
                return any(values)
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
            left, right = evaluate(node.left), evaluate(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                return left.casefold() == right.casefold()
            return left == right
        raise AssertionError(f"unsupported CI predicate: {ast.dump(node)}")

    return bool(evaluate(ast.parse(expression, mode="eval").body))


class PublicationWorkflow(unittest.TestCase):
    def evidence(self, runs, commit="a" * 40, repository="owner/project", status=0, raw=None,
                 command=None, current="a" * 40):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            gh = directory / "gh"
            gh.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['EVIDENCE_CALL'], 'w') as output:
    json.dump(sys.argv[1:], output)
if int(os.environ['EVIDENCE_STATUS']):
    print('Actions API unavailable', file=sys.stderr)
    sys.exit(int(os.environ['EVIDENCE_STATUS']))
if any('/git/ref/heads/main' in argument for argument in sys.argv):
    print(os.environ['EVIDENCE_CURRENT'])
    sys.exit(0)
print(os.environ['EVIDENCE_RESPONSE'])
""")
            gh.chmod(0o755)
            call = directory / "call.json"
            environment = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               GITHUB_REPOSITORY=repository, EVIDENCE_CALL=str(call),
                               EVIDENCE_STATUS=str(status), EVIDENCE_CURRENT=current,
                               DEPLOY_SHA=commit, GITHUB_SHA=commit, GH_TOKEN="test-token",
                               EVIDENCE_RESPONSE=raw if raw is not None else json.dumps({"workflow_runs": runs}))
            arguments = ([sys.executable, str(ROOT / "tools/check/require-main-check.py"), commit]
                         if command is None else ["bash", "-e", "-o", "pipefail", "-c", command])
            result = subprocess.run(arguments, cwd=directory if command is None else ROOT,
                                    env=environment, capture_output=True, text=True)
            return result, json.loads(call.read_text()) if call.exists() else None

    def test_publication_requires_main_push_evidence(self):
        run = {"head_sha": "a" * 40, "head_branch": "main", "event": "push",
               "status": "completed", "conclusion": "success",
               "head_repository": {"full_name": "owner/project"},
               "html_url": "https://example.invalid/main-run"}
        result, call = self.evidence([run])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), run["html_url"])
        for value in ("branch=main", "event=push", "status=completed", "head_sha=" + "a" * 40):
            self.assertIn(value, call)
        for key, value in [("head_sha", "b" * 40), ("head_branch", "dev"),
                           ("event", "pull_request"), ("status", "in_progress"),
                           ("conclusion", "failure"), ("head_repository", {"full_name": "fork/project"}),
                           ("html_url", "")]:
            with self.subTest(field=key):
                refused, _ = self.evidence([dict(run, **{key: value})])
                self.assertEqual(refused.returncode, 1, refused.stderr)
                self.assertEqual(refused.stdout, "")
        empty, _ = self.evidence([])
        self.assertEqual(empty.returncode, 1)

    def test_evidence_errors_remain_failures(self):
        failed, _ = self.evidence([], status=7)
        self.assertEqual(failed.returncode, 7)
        self.assertIn("Actions API unavailable", failed.stderr)
        for raw in ("{", "{}", '{"workflow_runs": null}'):
            malformed, _ = self.evidence([], raw=raw)
            self.assertEqual(malformed.returncode, 1, malformed.stderr)
            self.assertIn("invalid Actions response", malformed.stderr)
        for arguments in ({"commit": "main"}, {"repository": ""}):
            invalid, call = self.evidence([], **arguments)
            self.assertEqual(invalid.returncode, 2)
            self.assertIsNone(call)

    def test_evidence_lookup_has_a_deadline_and_setup_diagnostic(self):
        spec = importlib.util.spec_from_file_location("main_check", ROOT / "tools/check/require-main-check.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        for error, status, diagnostic in [
            (subprocess.TimeoutExpired("gh", 30), 124, "exceeded 30 seconds"),
            (FileNotFoundError("gh unavailable"), 1, "cannot run gh"),
        ]:
            output = io.StringIO()
            with mock.patch.object(sys, "argv", ["require-main-check.py", "a" * 40]), \
                    mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/project"}), \
                    mock.patch.object(helper.subprocess, "run", side_effect=error) as lookup, \
                    contextlib.redirect_stderr(output):
                self.assertEqual(helper.main(), status)
            self.assertIn(diagnostic, output.getvalue())
            self.assertIn("timeout", lookup.call_args.kwargs)
            self.assertGreater(lookup.call_args.kwargs["timeout"], 0)
            self.assertLessEqual(lookup.call_args.kwargs["timeout"], 30)

    def test_workflow_steps_enforce_publication_evidence(self):
        run = {"head_sha": "a" * 40, "head_branch": "main", "event": "push",
               "status": "completed", "conclusion": "success",
               "head_repository": {"full_name": "owner/project"},
               "html_url": "https://example.invalid/main-run"}
        for path, name in [("pages", "Verify the exact commit passed check"),
                           ("release", "Require this commit's successful check workflow")]:
            source = (ROOT / f".github/workflows/{path}.yml").read_text()
            step = re.search(rf"^      - name: {re.escape(name)}\n((?: {{8}}[^\n]*\n|\n)*)", source, re.M)
            self.assertIsNotNone(step, path)
            block = re.search(r"^        run: \|\n((?: {10}[^\n]*\n|\n)*)", step[1], re.M)
            self.assertIsNotNone(block, path)
            command = textwrap.dedent(block[1])
            with self.subTest(workflow=path):
                accepted, _ = self.evidence([run], command=command)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                refused, _ = self.evidence([dict(run, head_branch="dev")], command=command)
                self.assertNotEqual(refused.returncode, 0, refused.stderr)
                if path == "pages":
                    stale, _ = self.evidence([run], command=command, current="b" * 40)
                    self.assertNotEqual(stale.returncode, 0)

    def test_publication_cannot_skip_its_evidence(self):
        def bodies(path):
            source = (ROOT / path).read_text()
            top, listed = source.split("\njobs:\n", 1)
            found = dict(re.findall(r"^  ([\w-]+):\n((?: {4}[^\n]*\n|\n)*)", listed, re.M))
            return top, found

        def step(body, name):
            found = re.search(rf"^      - name: {re.escape(name)}\n((?: {{8}}[^\n]*\n|\n)*)", body, re.M)
            self.assertIsNotNone(found, name)
            return found[1]

        top, release = bodies(".github/workflows/release.yml")
        self.assertRegex(release["release"], r"(?m)^    needs: \[contract, ")
        verifier = step(release["contract"], "Require this commit's successful check workflow")
        self.assertIn("if: github.event_name == 'push' && github.ref_type == 'tag'\n", verifier)
        top, pages = bodies(".github/workflows/pages.yml")
        self.assertRegex(pages["deploy"], r"(?m)^    needs: build$")
        step(pages["build"], "Verify the exact commit passed check")
        self.assertNotRegex(top, r"(?m)^  (pages|id-token): write$")
        self.assertNotRegex(pages["build"], r"(?m)^      (pages|id-token): write$")
        for path, found in ((".github/workflows/release.yml", release), (".github/workflows/pages.yml", pages)):
            for name, body in found.items():
                for checkout in re.finditer(r"^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)", body, re.M):
                    with self.subTest(workflow=path, job=name):
                        self.assertRegex(checkout[1], r"(?m)^          persist-credentials: false$")

    def test_check_events(self):
        conditions = jobs(".github/workflows/check.yml")
        for event, base, expected in [
            ("push", "", (False, True, True, False)),
            ("pull_request", "dev", (True, False, False, False)),
            ("pull_request", "main", (True, True, True, False)),
            ("schedule", "", (False, False, False, True)),
            ("workflow_dispatch", "", (False, False, False, True)),
        ]:
            context = {"event_name": event, "base_ref": base}
            names = ("pull-request", "gates", "macos-runtime", "scheduled-fuzz")
            with self.subTest(event=event, base=base):
                self.assertEqual(tuple(selected(conditions[name][0], context) for name in names), expected)

    def test_pr_execution_is_unprivileged(self):
        source = (ROOT / ".github/workflows/check.yml").read_text()
        self.assertIn("\n  pull_request:\n", source)
        self.assertNotIn("pull_request_target:", source)
        self.assertIn("\npermissions:\n  contents: read\n", source)
        self.assertNotIn("secrets.", source)
        for name in ("pull-request", "gates", "macos-runtime"):
            body = jobs(".github/workflows/check.yml")[name][1]
            with self.subTest(job=name):
                self.assertNotIn("permissions:", body)
                self.assertNotIn("self-hosted", body)
                self.assertNotRegex(body, r"(?m)^\s+ref:")
                checkout = re.search(r"^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)", body, re.M)
                self.assertIsNotNone(checkout)
                self.assertRegex(checkout[1], r"(?m)^          persist-credentials: false$")

    def test_protection_matches_premerge_checks(self):
        for branch in ("main", "dev"):
            policy = json.loads((ROOT / f".github/rulesets/{branch}.json").read_text())
            self.assertEqual(policy["target"], "branch")
            self.assertEqual(policy["enforcement"], "active")
            self.assertEqual(policy["bypass_actors"], [])
            self.assertEqual(policy["conditions"]["ref_name"], {"include": [f"refs/heads/{branch}"], "exclude": []})
            rules = {rule["type"]: rule.get("parameters", {}) for rule in policy["rules"]}
            self.assertIn("non_fast_forward", rules)
            self.assertIn("deletion", rules)
            if branch == "dev":
                self.assertEqual(set(rules), {"non_fast_forward", "deletion"})
                continue
            review = rules["pull_request"]
            self.assertEqual(review["allowed_merge_methods"], ["merge"])
            self.assertEqual(review["required_approving_review_count"], 0)
            self.assertFalse(review["require_code_owner_review"])
            self.assertFalse(review["require_last_push_approval"])
            self.assertTrue(review["required_review_thread_resolution"])
            checks = rules["required_status_checks"]
            self.assertTrue(checks["strict_required_status_checks_policy"])
            conditions = jobs(".github/workflows/check.yml")
            for check in checks["required_status_checks"]:
                self.assertGreater(check["integration_id"], 0)
                self.assertIn(check["context"], conditions)
                self.assertTrue(selected(conditions[check["context"]][0],
                                         {"event_name": "pull_request", "base_ref": "main"}))
            self.assertEqual({check["context"] for check in checks["required_status_checks"]},
                             {name for name, (condition, _) in conditions.items()
                              if selected(condition, {"event_name": "pull_request", "base_ref": "main"})})

    def test_pages_requires_trusted_push_or_manual_main(self):
        condition = jobs(".github/workflows/pages.yml")["build"][0]
        for event, origin, conclusion, expected in [
            ("push", "owner/project", "success", True),
            ("pull_request", "owner/project", "success", False),
            ("push", "fork/project", "success", False),
            ("push", "owner/project", "failure", False),
        ]:
            context = {"event_name": "workflow_run", "repository": "owner/project", "event": {
                "workflow_run": {"event": event, "conclusion": conclusion,
                                 "head_repository": {"full_name": origin}},
            }}
            with self.subTest(event=event, origin=origin, conclusion=conclusion):
                self.assertEqual(selected(condition, context), expected)
        for branch, expected in [("main", True), ("dev", False)]:
            self.assertEqual(selected(condition, {"event_name": "workflow_dispatch",
                                                 "ref": f"refs/heads/{branch}"}), expected)


if __name__ == "__main__":
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(PublicationWorkflow))
    if not result.wasSuccessful():
        sys.stderr.write(output.getvalue())
    sys.exit(0 if result.wasSuccessful() else 1)
