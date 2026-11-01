"""The maintainer's check that GitHub holds this repository to its committed protection policy.

Run by the maintainer from any directory, with gh signed in as a repository
administrator, and read-only by .github/workflows/repository-policy.yml weekly
and on each change to the policy, with the promotion app's read-only token:

  python3 tools/repository-policy.py [--apply] [SUBJECT ...]

.github/repository-policy.json holds the merge settings, security features,
Actions permissions, code scanning setup, and the directory of rulesets
(.github/rulesets/*.json). Without --apply the command only reads and prints
one line per subject, `ok` or one `drift:` line per difference. With --apply
it writes the committed value for every drifted subject, then reads that
subject again and prints what remains. A ruleset live on GitHub that no
committed file names is reported as unmanaged and never deleted.

GitHub shows a few settings only to an administrator: the merge settings of
the repository and the bypass actors of a ruleset. A reader without that right
gets an answer without them, and the command prints one `unchecked:` line
naming them instead of calling them drift, so the weekly run holds everything
it can see and the maintainer's own run holds the rest. For an administrator
an answer without a policy field is a failed read.

Subjects, in the order they run: repository, security, vulnerability-alerts,
private-vulnerability-reporting, immutable-releases, actions, code-scanning,
rulesets. Naming subjects runs only those. The repository comes from
`gh repo view`, and gh runs with the checkout root as its working directory.

Exit status is 0 when every selected subject ends `ok`, unchecked fields
included, and 1 otherwise, for drift, a failed read, or a failed write. A
subject that fails does not stop
the others. tools/repository_policy_test.py drives the command against a
fake gh with no network.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / ".github/repository-policy.json"
RULESET_KEYS = ("target", "enforcement", "bypass_actors", "conditions", "rules")
PERMISSION_KEYS = ("enabled", "allowed_actions", "sha_pinning_required")
WORKFLOW_KEYS = ("default_workflow_permissions", "can_approve_pull_request_reviews")
FORK_KEY = "fork_pr_approval_policy"


class Reading:
    """What one subject found: its drift lines, the fix that writes the policy, and the fields the answer hid."""

    def __init__(self, drifts, fix, hidden=()):
        self.drifts = drifts
        self.fix = fix
        self.hidden = list(hidden)


class Failure(Exception):
    """A gh call or an answer that could not be used, with a short reason."""


class Absent(Failure):
    """GitHub answered 404, which some endpoints use to say a feature is off."""


def gh(*args, input=None):
    """Run gh from the checkout root and return its output. The fake in the tests replaces this."""
    return subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True, timeout=60, cwd=ROOT, input=input
    ).stdout


def short(text):
    return " ".join(str(text).split())[:200]


def api(method, path, body=None):
    """One gh api call. A JSON answer is parsed, an empty answer is None, and a 404 raises Absent."""
    arguments = ["api", "-X", method, path]
    if body is not None:
        arguments += ["--input", "-"]
    try:
        output = gh(*arguments, input=None if body is None else json.dumps(body))
    except subprocess.CalledProcessError as error:
        reason = short(error.stderr or error)
        raise (Absent if "HTTP 404" in reason else Failure)(reason) from error
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(short(error)) from error
    try:
        return json.loads(output) if output.strip() else None
    except ValueError as error:
        raise Failure(f"GitHub answered with invalid JSON for {path}") from error


def show(value):
    return json.dumps(value)


def differences(live, wanted):
    """Every (field, live, wanted) where the live answer disagrees with the policy."""
    return [(field, live[field], value) for field, value in wanted.items() if live[field] != value]


def compare(session, live, wanted):
    """The differences, and the policy fields the answer leaves out.

    GitHub omits administrator-only fields from a reader's answer. For an
    administrator an omitted field is a failed read, raised as the KeyError
    `differences` would have raised."""
    hidden = [field for field in wanted if field not in live]
    if hidden and session.administrator():
        raise KeyError(hidden[0])
    return differences(live, {field: value for field, value in wanted.items() if field not in hidden}), hidden


def drift_lines(found):
    return [f"{field} is {show(live)} and the policy says {show(wanted)}" for field, live, wanted in found]


def names(found):
    return ", ".join(field for field, _, _ in found)


class Session:
    """The policy, the repository slug, and the one repository answer subjects share."""

    def __init__(self):
        self._policy = None
        self._slug = None
        self._repository = None

    @property
    def policy(self):
        if self._policy is None:
            try:
                self._policy = json.loads(POLICY.read_text())
            except (OSError, ValueError) as error:
                raise Failure(f"{POLICY.parent.name}/{POLICY.name} is unreadable: {short(error)}") from error
        return self._policy

    @property
    def slug(self):
        if self._slug is None:
            slug = short(self._gh_slug())
            if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", slug) is None:
                raise Failure(f"gh named the repository {show(slug)}")
            self._slug = slug
        return self._slug

    @staticmethod
    def _gh_slug():
        try:
            return gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
        except subprocess.CalledProcessError as error:
            raise Failure(short(error.stderr or error)) from error
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Failure(short(error)) from error

    def path(self, suffix=""):
        return f"repos/{self.slug}" + (f"/{suffix}" if suffix else "")

    def read(self, suffix=""):
        return api("GET", self.path(suffix))

    def repository(self):
        if self._repository is None:
            self._repository = self.read()
        return self._repository

    def administrator(self):
        """Whether the caller administers the repository, read from the answer's own `permissions`."""
        return self.repository().get("permissions", {}).get("admin") is True

    def write(self, method, suffix, body=None):
        self._repository = None
        return api(method, self.path(suffix), body)

    def forget(self):
        self._repository = None


def check_repository(session):
    found, hidden = compare(session, session.repository(), session.policy["repository"])

    def fix():
        session.write("PATCH", "", {field: wanted for field, _, wanted in found})
        return names(found)

    return Reading(drift_lines(found), fix, hidden)


def check_security(session):
    wanted = session.policy["security_and_analysis"]
    live = session.repository()["security_and_analysis"]
    found = differences({key: live[key]["status"] for key in wanted}, wanted)

    def fix():
        session.write("PATCH", "", {"security_and_analysis": {field: {"status": value} for field, _, value in found}})
        return names(found)

    return Reading(drift_lines(found), fix)


def toggle(key, endpoint, enabled_in):
    """A feature that is on or off, read from its endpoint and written with PUT or DELETE."""

    def check(session):
        wanted = session.policy[key]
        found = differences({key: enabled_in(session, endpoint)}, {key: wanted})

        def fix():
            session.write("PUT" if wanted else "DELETE", endpoint)
            return f"{key} {'enabled' if wanted else 'disabled'}"

        return Reading(drift_lines(found), fix)

    return check


def alerts_enabled(session, endpoint):
    try:
        session.read(endpoint)
    except Absent:
        return False
    return True


def reporting_enabled(session, endpoint):
    return session.read(endpoint)["enabled"]


def check_actions(session):
    permissions = session.read("actions/permissions")
    workflow = session.read("actions/permissions/workflow")
    fork = session.read("actions/permissions/fork-pr-contributor-approval")
    live = {key: permissions[key] for key in PERMISSION_KEYS}
    live.update({key: workflow[key] for key in WORKFLOW_KEYS})
    live[FORK_KEY] = fork["approval_policy"]
    wanted = session.policy["actions"]
    found = differences(live, wanted)
    changed = {field for field, _, _ in found}

    def fix():
        for suffix, keys in (("actions/permissions", PERMISSION_KEYS), ("actions/permissions/workflow", WORKFLOW_KEYS)):
            if changed.intersection(keys):
                session.write("PUT", suffix, {key: wanted[key] for key in keys})
        if FORK_KEY in changed:
            session.write(
                "PUT", "actions/permissions/fork-pr-contributor-approval", {"approval_policy": wanted[FORK_KEY]}
            )
        return names(found)

    return Reading(drift_lines(found), fix)


def check_code_scanning(session):
    wanted = session.policy["code_scanning_default_setup"]
    found = differences(session.read("code-scanning/default-setup"), wanted)

    def fix():
        session.write("PATCH", "code-scanning/default-setup", wanted)
        return names(found)

    return Reading(drift_lines(found), fix)


def form(value):
    return json.dumps(value, sort_keys=True)


def normalize_rule(rule):
    """A rule without the defaults GitHub reports, which the committed file omits."""
    parameters = {
        key: sorted(value, key=form) if isinstance(value, list) else value
        for key, value in rule.get("parameters", {}).items()
        if value is not False
    }
    return {"type": rule["type"], "parameters": parameters}


def normalize(body):
    """The parts of a ruleset the policy owns that the answer holds, in an order that does not depend on the answer."""
    forms = {
        "target": lambda value: value,
        "enforcement": lambda value: value,
        "conditions": lambda value: value,
        "bypass_actors": lambda actors: sorted(
            ([actor.get("actor_id"), actor["actor_type"], actor["bypass_mode"]] for actor in actors), key=form
        ),
        "rules": lambda rules: sorted(
            (normalize_rule(rule) for rule in rules), key=lambda rule: (rule["type"], form(rule))
        ),
    }
    return {key: forms[key](body[key]) for key in RULESET_KEYS if key in body}


def committed_rulesets(session):
    directory = ROOT / session.policy["rulesets"]
    try:
        files = sorted(directory.glob("*.json"))
        bodies = [json.loads(path.read_text()) for path in files]
    except (OSError, ValueError) as error:
        raise Failure(f"{session.policy['rulesets']} is unreadable: {short(error)}") from error
    committed = {}
    for body in bodies:
        if body["name"] in committed:
            raise Failure(f"two committed rulesets are named {body['name']}")
        committed[body["name"]] = body
    return committed


def check_rulesets(session):
    committed = committed_rulesets(session)
    # GitHub allows at most 75 rulesets, so one page of 100 lists them all.
    live = {entry["name"]: entry["id"] for entry in session.read("rulesets?per_page=100") or []}
    drifts = []
    hidden = []
    writes = []
    for name, body in committed.items():
        if name not in live:
            drifts.append(f"{name} missing")
            writes.append(("POST", "rulesets", body, f"{name} created"))
            continue
        wanted = normalize(body)
        found, unseen = compare(session, normalize(session.read(f"rulesets/{live[name]}")), wanted)
        hidden += [f"{name} {key}" for key in unseen]
        if found:
            drifts.append(f"{name} differs in {' and '.join(field for field, _, _ in found)}")
            writes.append(("PUT", f"rulesets/{live[name]}", body, f"{name} updated"))
    drifts += [f"unmanaged {name}" for name in live if name not in committed]

    def fix():
        for method, suffix, body, _ in writes:
            session.write(method, suffix, body)
        return ", ".join(done for *_, done in writes)

    return Reading(drifts, fix, hidden)


SUBJECTS = {
    "repository": check_repository,
    "security": check_security,
    "vulnerability-alerts": toggle("vulnerability_alerts", "vulnerability-alerts", alerts_enabled),
    "private-vulnerability-reporting": toggle(
        "private_vulnerability_reporting", "private-vulnerability-reporting", reporting_enabled
    ),
    "immutable-releases": toggle("immutable_releases", "immutable-releases", reporting_enabled),
    "actions": check_actions,
    "code-scanning": check_code_scanning,
    "rulesets": check_rulesets,
}
UNUSABLE = (Failure, KeyError, TypeError, ValueError)


def say(subject, text):
    print(f"repository-policy: {subject}: {text}")


def reason(error):
    if isinstance(error, KeyError):
        return f"the policy or the answer has no {error.args[0]}"
    if isinstance(error, TypeError):
        return "the answer has an unexpected shape"
    return short(error)


def inspect(subject, session):
    """The subject's (drifts, fix), or None after saying why it could not be read."""
    try:
        return SUBJECTS[subject](session)
    except UNUSABLE as error:
        say(subject, f"cannot read: {reason(error)}")
        return None


def report(subject, reading):
    if not reading.drifts:
        say(subject, "ok")
    for line in reading.drifts:
        say(subject, f"drift: {line}")
    if reading.hidden:
        say(subject, f"unchecked: {', '.join(reading.hidden)}, which GitHub shows only to an administrator")
    return not reading.drifts


def settle(subject, session, apply):
    """Report one subject, make it match first when asked, and return whether it ends ok."""
    reading = inspect(subject, session)
    if reading is None:
        return False
    if not apply or not reading.drifts:
        return report(subject, reading)
    try:
        done = reading.fix()
    except UNUSABLE as error:
        say(subject, f"cannot apply: {reason(error)}")
        return False
    if done:
        say(subject, f"applied {done}")
    session.forget()
    reading = inspect(subject, session)
    return reading is not None and report(subject, reading)


def run(subjects, apply):
    session = Session()
    results = [settle(subject, session, apply) for subject in subjects]
    return 0 if all(results) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="make GitHub match the policy for every drifted subject")
    parser.add_argument(
        "subjects", nargs="*", choices=list(SUBJECTS), metavar="SUBJECT", help="subjects to check, default all"
    )
    args = parser.parse_args()
    sys.exit(run([name for name in SUBJECTS if name in args.subjects or not args.subjects], args.apply))


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError) as error:
        sys.exit(f"repository-policy: {short(error)}")
