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
import tomllib
import unittest
from unittest import mock

from ci_runtime_test import RuntimeTest
from ci_image_test import ImageTest
from ci_plan_test import PLAN, PlanTest  # unittest collects the coverage-selection contracts.


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
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "always" and not node.args and not node.keywords:
            return True
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
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            left, right = evaluate(node.left), evaluate(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                left, right = left.casefold(), right.casefold()
            equal = left == right
            return equal if isinstance(node.ops[0], ast.Eq) else not equal
        raise AssertionError(f"unsupported CI predicate: {ast.dump(node)}")

    return bool(evaluate(ast.parse(expression, mode="eval").body))


class PublicationWorkflow(unittest.TestCase):
    def test_package_metadata_matches_the_pre_one_release(self):
        version = json.loads((ROOT / "bindings/c-abi-resolve.json").read_text())["abi_version"]
        self.assertRegex(version, r"^0\.[0-9]+\.[0-9]+$")
        manifest = (ROOT / "build.zig.zon").read_text()
        self.assertIn(f'.version = "{version}"', manifest)
        paths = subprocess.check_output(
            ["git", "ls-files", "*Cargo.toml", "*deno.json", "bindings/python/pyproject.toml"],
            cwd=ROOT, text=True).splitlines()
        for path in paths:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                if path.endswith("deno.json"):
                    # These are JSONC. Read scalar metadata without interpreting comments.
                    declared = re.search(r'^\s*"version":\s*"([^"]+)"', source, re.M)
                    if declared:
                        self.assertEqual(declared[1], version)
                    self.assertRegex(source, r'"license":\s*"Apache-2\.0"')
                    continue
                data = tomllib.loads(source)
                package = data.get("package", data.get("project", data.get("workspace", {}).get("package")))
                self.assertIsNotNone(package)
                for field, expected in (("version", version), ("license", "Apache-2.0")):
                    actual = package[field]
                    self.assertTrue(actual == expected or actual == {"workspace": True}, (field, actual))
                urls = package.get("urls", package)
                for field, expected in (("repository", "https://github.com/glowcap-org/glowcap"),
                                        ("homepage", "https://glowcap.org"),
                                        ("documentation", "https://glowcap.org")):
                    actual = {key.lower(): value for key, value in urls.items()}[field]
                    self.assertTrue(actual == expected or actual == {"workspace": True}, (path, field, actual))
        for path, section in (("bindings/rust/Cargo.toml", "package"),
                              ("bindings/python/pyproject.toml", "project")):
            self.assertEqual(tomllib.loads((ROOT / path).read_text())[section]["name"], "glowcap")
        distribution = tomllib.loads((ROOT / "bindings/python/pyproject.toml").read_text())["project"]["name"]
        generated = f"bindings/python/{distribution.replace('-', '_')}.egg-info/PKG-INFO"
        ignored = subprocess.run(["git", "check-ignore", "--no-index", "-v", generated],
                                 cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(ignored.returncode, 0, f"generated packaging metadata must be ignored: {generated}")
        source, _, pattern = ignored.stdout.split("\t", 1)[0].split(":", 2)
        self.assertEqual(source, ".gitignore")
        self.assertFalse(pattern.startswith("!"))
        racket = (ROOT / "bindings/racket/info.rkt").read_text()
        self.assertIn(f'(define version "{version}")', racket)
        self.assertIn("(define license 'Apache-2.0)", racket)

    def test_dependency_acquisition_retries_without_running_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stub = directory / "zig"
            stub.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""\
                import os, pathlib, sys
                log = pathlib.Path(os.environ['FETCH_LOG'])
                attempts = log.read_text().splitlines() if log.exists() else []
                with log.open('a') as output:
                    output.write(' '.join(sys.argv[1:]) + '\\n')
                codes = os.environ['FETCH_CODES'].split(',')
                sys.exit(int(codes[min(len(attempts), len(codes) - 1)]))
                """))
            stub.chmod(0o755)
            log = directory / "attempts"
            environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                               FETCH_LOG=str(log), ZIG_FETCH_RETRY_DELAY="0")
            for codes, status, attempts in [("0", 0, 1), ("1,0", 0, 2),
                                            ("1,1,0", 0, 3), ("7", 7, 3),
                                            ("130", 130, 1), ("143", 143, 1)]:
                log.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(ROOT / 'ci/fetch-zig.sh')],
                                        cwd=directory, env=dict(environment, FETCH_CODES=codes),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(log.read_text().splitlines(), ['build --fetch=all'] * attempts)
            log.unlink()
            result = subprocess.run(['bash', str(ROOT / 'ci/fetch-zig.sh')],
                                    env=dict(environment, ZIG_FETCH_RETRY_DELAY='invalid'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(log.exists())
        for name, (_, body) in jobs('.github/workflows/check.yml').items():
            if name not in ('gates', 'plan'):
                self.assertIn('bash ci/fetch-zig.sh', body, name)

    def test_release_version_and_publication_stay_pre_one(self):
        source = (ROOT / ".github/workflows/release.yml").read_text()

        def command(name):
            step = re.search(rf"^      - name: {re.escape(name)}\n((?: {{8}}[^\n]*\n|\n)*)", source, re.M)
            self.assertIsNotNone(step, name)
            block = re.search(r"^        run: \|\n((?: {10}[^\n]*\n|\n)*)", step[1], re.M)
            self.assertIsNotNone(block, name)
            return textwrap.dedent(block[1])

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "bindings").mkdir()
            output = directory / "output"
            environment = dict(os.environ, GITHUB_OUTPUT=str(output))
            for version, accepted in [("0.1.0", True), ("0.2.3", True),
                                      ("1.0.0", False), ("1.0.0-alpha.1", False),
                                      ("10.0.0", False), ("garbage", False)]:
                with self.subTest(version=version):
                    (directory / "bindings/c-abi-resolve.json").write_text(
                        json.dumps({"abi_version": version}))
                    output.write_text("")
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                                             command("Read the product version")],
                                            cwd=directory, env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    self.assertEqual(output.read_text(), f"value={version}\n" if accepted else "")
            gh = directory / "gh"
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$GITHUB_OUTPUT"\n')
            gh.chmod(0o755)
            environment.update(PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               GITHUB_REF_NAME="v0.1.0", GITHUB_REPOSITORY="owner/project")
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                                     command("Create the release with archives")],
                                    cwd=directory, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = output.read_text().splitlines()
            self.assertIn("--prerelease", arguments)
            self.assertIn("--latest=false", arguments)
            self.assertIn("glowcap v0.1.0 alpha", arguments)

    def evidence(self, runs, commit="a" * 40, repository="owner/project", status=0, raw=None,
                 command=None, current="a" * 40, job_records=None):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            gh = directory / "gh"
            gh.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['EVIDENCE_CALL'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if int(os.environ['EVIDENCE_STATUS']):
    print('Actions API unavailable', file=sys.stderr)
    sys.exit(int(os.environ['EVIDENCE_STATUS']))
if any('/git/ref/heads/main' in argument for argument in sys.argv):
    print(os.environ['EVIDENCE_CURRENT'])
    sys.exit(0)
if any('/jobs?' in argument for argument in sys.argv):
    print(os.environ['EVIDENCE_JOBS'])
else:
    print(os.environ['EVIDENCE_RESPONSE'])
""")
            gh.chmod(0o755)
            call = directory / "call.json"
            environment = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               GITHUB_REPOSITORY=repository, EVIDENCE_CALL=str(call),
                               EVIDENCE_STATUS=str(status), EVIDENCE_CURRENT=current,
                               DEPLOY_SHA=commit, GITHUB_SHA=commit, GH_TOKEN="test-token",
                               EVIDENCE_RESPONSE=raw if raw is not None else json.dumps({"workflow_runs": runs}),
                               EVIDENCE_JOBS=json.dumps({"jobs": job_records if job_records is not None else [
                                   {"name": name, "status": "completed", "conclusion": "success"}
                                   for name in ("gates", "macos-runtime")]}))
            arguments = ([sys.executable, str(ROOT / "tools/check/require-main-check.py"), commit]
                         if command is None else ["bash", "-e", "-o", "pipefail", "-c", command])
            result = subprocess.run(arguments, cwd=directory if command is None else ROOT,
                                    env=environment, capture_output=True, text=True)
            self.api_calls = [json.loads(line) for line in call.read_text().splitlines()] if call.exists() else []
            return result, self.api_calls[0] if self.api_calls else None

    def test_publication_requires_main_push_evidence(self):
        run = {"id": 42, "run_attempt": 1, "head_sha": "a" * 40, "head_branch": "main", "event": "push",
               "status": "completed", "conclusion": "success",
               "head_repository": {"full_name": "owner/project"},
               "html_url": "https://example.invalid/main-run"}
        result, call = self.evidence([run])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), run["html_url"])
        for value in ("branch=main", "status=completed", "head_sha=" + "a" * 40):
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

    def test_manual_recovery_requires_both_successful_gate_jobs(self):
        run = {"id": 42, "run_attempt": 2, "head_sha": "a" * 40,
               "head_branch": "main", "event": "workflow_dispatch",
               "status": "completed", "conclusion": "success",
               "head_repository": {"full_name": "owner/project"},
               "html_url": "https://example.invalid/manual-run"}
        accepted, _ = self.evidence([run])
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("repos/owner/project/actions/runs/42/attempts/2/jobs?per_page=100", self.api_calls[1])
        for event in ("push", "workflow_dispatch"):
            for conclusion in ("skipped", "failure", "cancelled", None):
                records = [{"name": "gates", "status": "completed", "conclusion": "success"},
                           {"name": "macos-runtime", "status": "completed", "conclusion": conclusion}]
                refused, _ = self.evidence([dict(run, event=event)], job_records=records)
                self.assertEqual(refused.returncode, 1, refused.stderr)
            refused, _ = self.evidence([dict(run, event=event)], job_records=[
                {"name": "scheduled-fuzz", "status": "completed", "conclusion": "success"}])
            self.assertEqual(refused.returncode, 1, refused.stderr)
        for records in ([{"name": "dev-gates", "status": "completed", "conclusion": "success"},
                         {"name": "macos-runtime", "status": "completed", "conclusion": "success"}],
                        [], [None, {"name": {}}, {"name": "gates", "status": "in_progress", "conclusion": "success"}]):
            refused, _ = self.evidence([run], job_records=records)
            self.assertEqual(refused.returncode, 1, refused.stderr)
        refused, _ = self.evidence([dict(run, event="schedule")])
        self.assertEqual(refused.returncode, 1)

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
        run = {"id": 42, "run_attempt": 1, "head_sha": "a" * 40, "head_branch": "main", "event": "push",
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
            ("push", "", (True, True, True, False)),
            ("pull_request", "dev", (True, True, True, False)),
            ("pull_request", "main", (True, True, True, False)),
            ("schedule", "", (True, True, True, True)),
            ("workflow_dispatch", "", (True, True, True, False)),
        ]:
            context = {"event_name": event, "base_ref": base, "event": {"inputs": {"suite": "check"}}}
            names = ("plan", "gates", "macos-runtime", "scheduled-fuzz")
            with self.subTest(event=event, base=base):
                self.assertEqual(tuple(selected(conditions[name][0], context) for name in names), expected)

    def test_manual_fuzz_keeps_its_separate_selection(self):
        source = (ROOT / ".github/workflows/check.yml").read_text()
        group = re.search(r"(?m)^  group: (.+)$", source)[1]
        self.assertIn("${{ github.event.inputs.suite || 'check' }}", group)
        conditions = jobs(".github/workflows/check.yml")
        context = {"event_name": "workflow_dispatch", "event": {"inputs": {"suite": "fuzz"}}}
        names = ("plan", "gates", "macos-runtime", "scheduled-fuzz")
        self.assertEqual(tuple(selected(conditions[name][0], context) for name in names),
                         (False, False, False, True))

    def test_pr_execution_is_unprivileged(self):
        source = (ROOT / ".github/workflows/check.yml").read_text()
        self.assertIn("\n  pull_request:\n", source)
        self.assertNotIn("pull_request_target:", source)
        self.assertIn("\npermissions:\n  contents: read\n", source)
        self.assertNotIn("secrets.", source)
        for name in ("plan", "linux", "gates", "macos-runtime"):
            body = jobs(".github/workflows/check.yml")[name][1]
            with self.subTest(job=name):
                self.assertNotIn("permissions:", body)
                self.assertNotIn("self-hosted", body)
                self.assertNotRegex(body, r"(?m)^\s+ref:")
                checkout = re.search(r"^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)", body, re.M)
                if name == "gates":
                    self.assertIsNone(checkout)
                    continue
                self.assertIsNotNone(checkout)
                self.assertRegex(checkout[1], r"(?m)^          persist-credentials: false$")

    def test_image_preparation_privileges_and_consumer_dependency(self):
        workflow = (ROOT / '.github/workflows/devcontainer-image.yml').read_text()
        self.assertIn('  workflow_call:', workflow)
        self.assertNotIn('  push:', workflow)
        conditions = jobs('.github/workflows/devcontainer-image.yml')
        for event, ref, trusted in [('push', 'refs/heads/dev', True),
                                    ('push', 'refs/heads/main', True),
                                    ('pull_request', 'refs/heads/dev', False),
                                    ('pull_request', 'refs/pull/7/merge', False),
                                    ('workflow_dispatch', 'refs/heads/topic', False)]:
            context = {'event_name': event, 'ref': ref}
            self.assertEqual(selected(conditions['trusted'][0], context), trusted)
            self.assertEqual(selected(conditions['readonly'][0], context), not trusted)
        self.assertIn('packages: write', conditions['trusted'][1])
        self.assertIn('packages: read', conditions['readonly'][1])
        self.assertNotIn('packages: write', conditions['readonly'][1])
        consumer = jobs('.github/workflows/check.yml')['linux'][1]
        self.assertIn('needs: [plan, image]', consumer)
        self.assertNotIn('devcontainers/ci@', consumer)
        self.assertNotIn('cacheFrom:', consumer)
        self.assertNotIn('--remote-env ZIG_LOCAL_PKG_DIR=', consumer)
        self.assertIn('needs.image.outputs.image', consumer)
        self.assertIn('needs.image.outputs.archive', consumer)

    def test_other_consumers_share_readonly_image_startup(self):
        for name in ('pages', 'agent-tools'):
            workflow = (ROOT / f'.github/workflows/{name}.yml').read_text()
            with self.subTest(workflow=name):
                self.assertNotIn('devcontainers/ci@', workflow)
                self.assertIn('packages: read', workflow)
                self.assertNotIn('packages: write', workflow)
                self.assertIn('run: python3 .devcontainer/ci/image.py prepare\n', workflow)
                self.assertNotIn('--publish', workflow)
                self.assertIn('IMAGE: ${{ steps.image.outputs.image }}', workflow)
                self.assertIn('run: python3 .devcontainer/ci/image.py start "$IMAGE"', workflow)
                self.assertIn('--config .devcontainer/.ci/devcontainer.json', workflow)

    def test_agent_download_failure_does_not_block_product_checks(self):
        workflow = (ROOT / ".github/workflows/agent-tools.yml").read_text()
        command = re.search(r"(?m)^        run: devcontainer exec --workspace-folder \. --config \.devcontainer/\.ci/devcontainer\.json (python3 .+)$", workflow)
        self.assertIsNotNone(command)
        self.assertIn("\npermissions:\n  contents: read\n", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("pull_request_target:", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("needs:", workflow)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            calls = directory / "calls.jsonl"
            recorder = directory / "python3"
            recorder.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""\
                import json, os, sys
                if sys.argv[1] == 'tools/evidence/record.py':
                    from pathlib import Path
                    rows = Path(sys.argv[sys.argv.index('--gates') + 1]).read_text()
                    Path(os.environ['GATE_RECORD']).write_text(json.dumps({'args': sys.argv[2:], 'rows': rows}))
                    sys.exit(int(os.environ.get('RECORD_FAILURE', '0')))
                command = sys.argv[7:] if '--heartbeat' in sys.argv else sys.argv[5:]
                with open(os.environ['GATE_CALLS'], 'a') as output:
                    output.write(json.dumps(command) + '\\n')
                sys.exit(37 if '.devcontainer/test/tool-install.sh' in command or os.environ.get('GATE_FAIL') in command else 0)
                """))
            recorder.chmod(0o755)
            environment = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               GATE_CALLS=str(calls), GATE_RECORD=str(directory / "record.json"))
            environment.pop("GATES_SOURCE_ONLY", None)
            agent = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command[1]],
                                   cwd=ROOT, env=environment, capture_output=True, text=True)
            self.assertEqual(agent.returncode, 37, agent.stderr)
            calls.unlink()
            product = subprocess.run(["bash", "ci/gates.sh"], cwd=ROOT, env=environment,
                                     capture_output=True, text=True)
            self.assertEqual(product.returncode, 0, product.stderr)
            invoked = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertFalse(any('.devcontainer/test/tool-install.sh' in call for call in invoked))
            for step in ("check", "runtime-check", "goblins-interop", "ocapn-conformance-next"):
                self.assertTrue(any(call[:2] == ["zig", "build"] and step in call for call in invoked), step)
            workflow = (ROOT / '.github/workflows/check.yml').read_text()
            lanes, full = PLAN.select('workflow_dispatch', 'refs/heads/dev', {}, [])
            self.assertTrue(full)
            phase_steps = re.findall(
                r"if: \$\{\{ !cancelled\(\) && steps.fetch.outcome == 'success' && matrix.lane == '([^']+)'( && needs.plan.outputs.full == 'true')? \}\}\n        run: devcontainer exec --workspace-folder \. --config \.devcontainer/\.ci/devcontainer\.json (?:--remote-env [A-Z_]+=[^ ]+ )+bash ci/gates.sh ([a-z]+)", workflow)
            phases = [phase for lane in lanes for condition, _, phase in phase_steps if condition == lane]
            self.assertEqual(len(phases), len(set(phases)))
            combined = []
            record_path = directory / 'record.json'
            for phase in phases:
                calls.unlink()
                result = subprocess.run(['bash', 'ci/gates.sh', phase], cwd=ROOT, env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertTrue(commands, phase)
                combined.extend(commands)
                record = json.loads(record_path.read_text())
                self.assertIn('zig-out/evidence/' + phase, record['args'])
                self.assertNotIn('--note', record['args'])
                self.assertEqual(len(record['rows'].splitlines()), len(commands))
            self.assertEqual(combined, invoked, 'CI phases must cover the full local sequence exactly once')
            reduced, full = PLAN.select('push', 'refs/heads/dev', {}, ['README.md'])
            self.assertFalse(full)
            reduced_phases = [phase for lane, full_only, phase in phase_steps
                              if lane in reduced and not full_only]
            self.assertEqual(reduced_phases, ['infrastructure', 'core', 'runtime', 'shipped', 'smoke'])
            for arguments in (['unknown'], ['core', 'browser']):
                calls.unlink(missing_ok=True)
                record_path.unlink()
                result = subprocess.run(['bash', 'ci/gates.sh', *arguments], cwd=ROOT, env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(calls.exists())
                self.assertFalse(record_path.exists())
                record_path.write_text('{}')
            # A failed gate does not stop its phase: every gate runs and records,
            # and the phase exits with the first failure. Recorder failure
            # must not hide a failed gate, or turn a successful phase green.
            for gate_failure, record_failure, expected in [('check', '0', 37), ('check', '9', 37), ('', '9', 70)]:
                result = subprocess.run(['bash', 'ci/gates.sh', 'core'], cwd=ROOT,
                                        env=dict(environment, GATE_FAIL=gate_failure, RECORD_FAILURE=record_failure),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                rows = json.loads(record_path.read_text())['rows'].splitlines()
                if gate_failure:
                    self.assertGreater(len(rows), 1)
                    failed = [row for row in rows if row.endswith(' ' + gate_failure)]
                    self.assertEqual(len(failed), 1, rows)
                    self.assertTrue(failed[0].startswith('37\t'))
                    self.assertTrue(all(row.startswith('0\t') for row in rows if row is not failed[0]))

    def test_shipped_mode_partitions_cover_every_layer_once(self):
        source = (ROOT / 'test/all_test.zig').read_text()
        declared = re.search(r'const Layer = enum \{([^}]+)\}', source)[1]
        layers = [name.strip() for name in declared.split(',') if name.strip()]
        gates = (ROOT / 'ci/gates.sh').read_text()
        shipped = re.search(r'^phase shipped\n(.*?)(?=^phase |\Z)', gates, re.M | re.S)[1]
        commands = re.findall(r'^(?:gate|build) zig build test -Doptimize=ReleaseSafe(.*)$', shipped, re.M)
        selected_layers = []
        for command in commands:
            selection = re.fullmatch(r' -Dtest-layer=([a-z_,]+)', command)
            self.assertIsNotNone(selection, 'ship-mode tests must bound compiler memory by layer')
            selected_layers.extend(selection[1].split(','))
        self.assertCountEqual(selected_layers, layers)

    def test_parallel_checks_cannot_pass_with_a_missing_lane(self):
        conditions = jobs('.github/workflows/check.yml')
        aggregate = conditions['gates'][1]
        self.assertIn('    needs: [plan, image, linux]\n', aggregate)
        self.assertIn('always()', conditions['gates'][0])
        self.assertIn('RESULT: ${{ needs.linux.result }}', aggregate)
        command = re.search(r'^        run: (.+)$', aggregate, re.M)[1]
        for result in ('success', 'failure', 'cancelled', 'skipped', ''):
            ran = subprocess.run(['bash', '-e', '-c', command], env=dict(os.environ, RESULT=result, PLAN='success', IMAGE='success'))
            self.assertEqual(ran.returncode == 0, result == 'success')
        for plan in ('failure', 'cancelled', 'skipped', ''):
            ran = subprocess.run(['bash', '-e', '-c', command],
                                 env=dict(os.environ, RESULT='success', PLAN=plan, IMAGE='success'))
            self.assertNotEqual(ran.returncode, 0)
        for result in ('failure', 'cancelled', 'skipped', ''):
            ran = subprocess.run(['bash', '-e', '-c', command],
                                 env=dict(os.environ, RESULT='success', PLAN='success', IMAGE=result))
            self.assertNotEqual(ran.returncode, 0)
        linux = conditions['linux'][1]
        self.assertIn('fail-fast: false', linux)
        self.assertIn('lane: ${{ fromJSON(needs.plan.outputs.lanes) }}', linux)
        self.assertIn('evidence-${{ github.sha }}-${{ matrix.lane }}', linux)
        self.assertEqual(conditions['linux'][0], conditions['gates'][0].removeprefix('always() && (').removesuffix(')').strip())

    def test_protection_is_signed_linear_and_checked_on_push(self):
        # main moves only by fast-forward from dev, so the checks a candidate
        # needs come from full validation on that exact dev commit.
        push_to_dev = {"event_name": "push", "ref": "refs/heads/dev"}
        for branch in ("main", "dev"):
            policy = json.loads((ROOT / f".github/rulesets/{branch}.json").read_text())
            self.assertEqual(policy["target"], "branch")
            self.assertEqual(policy["enforcement"], "active")
            self.assertEqual(policy["bypass_actors"], [])
            self.assertEqual(policy["conditions"]["ref_name"], {"include": [f"refs/heads/{branch}"], "exclude": []})
            rules = {rule["type"]: rule.get("parameters", {}) for rule in policy["rules"]}
            linear_signed = {"non_fast_forward", "deletion", "required_linear_history", "required_signatures"}
            if branch == "dev":
                self.assertEqual(set(rules), linear_signed)
                continue
            self.assertEqual(set(rules), linear_signed | {"required_status_checks"})
            checks = rules["required_status_checks"]
            self.assertTrue(checks["strict_required_status_checks_policy"])
            conditions = jobs(".github/workflows/check.yml")
            for check in checks["required_status_checks"]:
                self.assertGreater(check["integration_id"], 0)
                self.assertIn(check["context"], conditions)
                self.assertTrue(selected(conditions[check["context"]][0], push_to_dev))
            self.assertEqual({check["context"] for check in checks["required_status_checks"]},
                             {"gates", "macos-runtime"})
            self.assertIn("name: ${{ needs.plan.outputs.full == 'true' && 'gates' || 'dev-gates' }}",
                          conditions["gates"][1])
        # A release tag names the commit release.yml publishes, so once pushed
        # it can neither move nor disappear, and it carries a signature.
        tags = json.loads((ROOT / ".github/rulesets/tags.json").read_text())
        self.assertEqual(tags["target"], "tag")
        self.assertEqual(tags["enforcement"], "active")
        self.assertEqual(tags["bypass_actors"], [])
        self.assertEqual(tags["conditions"]["ref_name"], {"include": ["refs/tags/v*"], "exclude": []})
        self.assertEqual({rule["type"] for rule in tags["rules"]}, {"deletion", "update", "required_signatures"})
        self.assertIn('tags: ["v*"]', (ROOT / ".github/workflows/release.yml").read_text())

    def test_pages_requires_trusted_push_or_manual_main(self):
        condition = jobs(".github/workflows/pages.yml")["build"][0]
        for event, origin, conclusion, expected in [
            ("push", "owner/project", "success", True),
            ("workflow_dispatch", "owner/project", "success", True),
            ("schedule", "owner/project", "success", False),
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
        unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    if not result.wasSuccessful():
        sys.stderr.write(output.getvalue())
    sys.exit(0 if result.wasSuccessful() else 1)
