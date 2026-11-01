"""A fake gh for the repository policy tests.

FakeGitHub answers as the endpoints tools/repository-policy.py reads and
writes, starting as a repository that matches .github/repository-policy.json
and every committed ruleset. The helpers drift one thing at a time, run the
command as the maintainer would, and read as the promotion app's token does.
"""

import contextlib
import copy
import importlib.util
import io
import json
import subprocess
import sys
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text()


SCRIPT = ROOT / "tools/repository-policy.py"
SPEC = importlib.util.spec_from_file_location("repository_policy", SCRIPT)
COMMAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMAND)
POLICY_FILE = ROOT / ".github/repository-policy.json"
SLUG = "owner/project"
SUBJECTS = tuple(COMMAND.SUBJECTS)
WRITE_METHODS = ("PUT", "PATCH", "POST", "DELETE")


def policy():
    return json.loads(POLICY_FILE.read_text())


def committed_rulesets():
    return {
        body["name"]: body
        for body in (json.loads(path.read_text()) for path in sorted((ROOT / policy()["rulesets"]).glob("*.json")))
    }


def as_github_reports(body, ruleset_id):
    """A committed ruleset as the API answers it: ids, timestamps, and the defaults the file omits."""
    answer = copy.deepcopy(body)
    answer.update(id=ruleset_id, created_at="2026-01-01T00:00:00Z", source_type="Repository", source=SLUG)
    for rule in answer["rules"]:
        if rule["type"] == "required_status_checks":
            rule["parameters"]["do_not_enforce_on_create"] = False
    answer["rules"].reverse()
    return answer


def not_found():
    return subprocess.CalledProcessError(1, ["gh"], stderr="gh: Not Found (HTTP 404)")


class FakeGitHub:
    """A gh stand-in holding GitHub's answers for a repository that matches the policy."""

    def __init__(self):
        wanted = policy()
        self.repo = {
            "id": 1,
            "full_name": SLUG,
            **wanted["repository"],
            "permissions": {"admin": True, "push": True, "pull": True},
            "security_and_analysis": {
                key: {"status": status} for key, status in wanted["security_and_analysis"].items()
            },
        }
        self.alerts = wanted["vulnerability_alerts"]
        self.reporting = {"enabled": wanted["private_vulnerability_reporting"]}
        self.immutable = {"enabled": wanted["immutable_releases"], "enforced_by_owner": False}
        actions = wanted["actions"]
        self.permissions = {key: actions[key] for key in COMMAND.PERMISSION_KEYS}
        self.workflow = {key: actions[key] for key in COMMAND.WORKFLOW_KEYS}
        self.fork = {"approval_policy": actions["fork_pr_approval_policy"]}
        self.scanning = {**wanted["code_scanning_default_setup"], "languages": ["actions"], "updated_at": None}
        self.rulesets = {}
        self.next_id = 100
        for body in committed_rulesets().values():
            self.add_ruleset(body)
        self.calls = []
        self.failures = {}

    def add_ruleset(self, body):
        self.next_id += 1
        self.rulesets[self.next_id] = as_github_reports(body, self.next_id)
        return self.next_id

    def ruleset_id(self, name):
        return next(key for key, body in self.rulesets.items() if body["name"] == name)

    def reads(self):
        return [path for method, path, _ in self.calls if method == "GET"]

    def writes(self):
        return [call for call in self.calls if call[0] in WRITE_METHODS]

    def __call__(self, *args, input=None):
        if args[:2] == ("repo", "view"):
            self.calls.append(("VIEW", args[2:], None))
            return SLUG + "\n"
        assert args[:2] == ("api", "-X"), args
        method, path = args[2], args[3]
        assert path.startswith(f"repos/{SLUG}"), path
        relative = path[len(f"repos/{SLUG}") :].lstrip("/")
        body = json.loads(input) if input is not None else None
        assert (body is None) == (method in ("GET", "DELETE") or (method == "PUT" and input is None)), args
        self.calls.append((method, relative, body))
        if (method, relative) in self.failures:
            raise subprocess.CalledProcessError(1, ["gh"], stderr=self.failures[(method, relative)])
        answer = self.answer(method, relative, body)
        return "" if answer is None else json.dumps(answer)

    def answer(self, method, relative, body):
        if method == "GET":
            return self.read(relative)
        self.write(method, relative, body)
        return None

    def read(self, relative):
        if relative == "vulnerability-alerts":
            if not self.alerts:
                raise not_found()
            return None
        listing = [{"id": key, "name": item["name"], "target": item["target"]} for key, item in self.rulesets.items()]
        answers = {
            "": self.repo,
            "private-vulnerability-reporting": self.reporting,
            "immutable-releases": self.immutable,
            "actions/permissions": self.permissions,
            "actions/permissions/workflow": self.workflow,
            "actions/permissions/fork-pr-contributor-approval": self.fork,
            "code-scanning/default-setup": self.scanning,
            "rulesets?per_page=100": listing,
        }
        if relative.startswith("rulesets/"):
            return self.rulesets[int(relative.split("/")[1])]
        return answers[relative]

    def write(self, method, relative, body):
        if relative == "":
            for key, value in body.items():
                if key == "security_and_analysis":
                    for feature, state in value.items():
                        self.repo[key][feature]["status"] = state["status"]
                else:
                    self.repo[key] = value
        elif relative == "vulnerability-alerts":
            self.alerts = method == "PUT"
        elif relative in ("private-vulnerability-reporting", "immutable-releases"):
            (self.reporting if relative.startswith("private") else self.immutable)["enabled"] = method == "PUT"
        elif relative == "actions/permissions":
            self.permissions.update(body)
        elif relative == "actions/permissions/workflow":
            self.workflow.update(body)
        elif relative == "actions/permissions/fork-pr-contributor-approval":
            self.fork.update(body)
        elif relative == "code-scanning/default-setup":
            self.scanning.update(body)
        elif relative == "rulesets" and method == "POST":
            self.add_ruleset(body)
        elif relative.startswith("rulesets/") and method == "PUT":
            ruleset_id = int(relative.split("/")[1])
            self.rulesets[ruleset_id] = as_github_reports(body, ruleset_id)
        else:
            raise AssertionError((method, relative))


def run_command(github, *argv, policy_file=None):
    """Run main() as the maintainer would and return its exit status and the lines it printed."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(COMMAND, "gh", github))
        stack.enter_context(mock.patch.object(sys, "argv", ["repository-policy.py", *argv]))
        stack.enter_context(contextlib.redirect_stdout(out))
        stack.enter_context(contextlib.redirect_stderr(err))
        if policy_file is not None:
            stack.enter_context(mock.patch.object(COMMAND, "POLICY", policy_file))
        try:
            COMMAND.main()
        except SystemExit as stop:
            return stop.code, out.getvalue().splitlines()
    raise AssertionError("main returned without exiting")


def line(subject, text):
    return f"repository-policy: {subject}: {text}"


def first_ruleset():
    return sorted(committed_rulesets())[0]


def drop_a_rule(github):
    github.rulesets[github.ruleset_id(first_ruleset())]["rules"].pop()


def remove_ruleset(github):
    del github.rulesets[github.ruleset_id(first_ruleset())]


def add_stray(github):
    github.add_ruleset({**committed_rulesets()[first_ruleset()], "name": "stray"})


# The merge settings and a ruleset's bypass actors are the fields GitHub shows
# only to an administrator.
ADMINISTRATOR_FIELDS = (
    "delete_branch_on_merge",
    "allow_squash_merge",
    "allow_merge_commit",
    "allow_rebase_merge",
    "allow_auto_merge",
    "allow_update_branch",
    "squash_merge_commit_title",
    "squash_merge_commit_message",
)


def read_as_the_promotion_app(github):
    """GitHub's answers to a token that may read but not administer the repository."""
    github.repo["permissions"] = {"admin": False, "push": True, "pull": True}
    for field in ADMINISTRATOR_FIELDS:
        del github.repo[field]
    for body in github.rulesets.values():
        del body["bypass_actors"]


# subject: (drift, the line it must print)
DRIFTS = {
    "repository": (
        lambda github: github.repo.update(has_wiki=True),
        "drift: has_wiki is true and the policy says false",
    ),
    "security": (
        lambda github: github.repo["security_and_analysis"]["secret_scanning"].update(status="disabled"),
        'drift: secret_scanning is "disabled" and the policy says "enabled"',
    ),
    "vulnerability-alerts": (
        lambda github: setattr(github, "alerts", False),
        "drift: vulnerability_alerts is false and the policy says true",
    ),
    "private-vulnerability-reporting": (
        lambda github: github.reporting.update(enabled=False),
        "drift: private_vulnerability_reporting is false and the policy says true",
    ),
    "immutable-releases": (
        lambda github: github.immutable.update(enabled=False),
        "drift: immutable_releases is false and the policy says true",
    ),
    "actions": (
        lambda github: github.workflow.update(default_workflow_permissions="write"),
        'drift: default_workflow_permissions is "write" and the policy says "read"',
    ),
    "code-scanning": (
        lambda github: github.scanning.update(query_suite="extended"),
        'drift: query_suite is "extended" and the policy says "default"',
    ),
    "rulesets": (drop_a_rule, f"drift: {first_ruleset()} differs in rules"),
}
