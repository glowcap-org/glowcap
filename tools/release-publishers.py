"""tools/release-publishers.py [--check] [STAGE ...]: the registry setup publish.yml needs.

The maintainer runs it from any directory, with gh authenticated for the
repository and network access to the registries. publish.yml cannot publish
until each registry trusts this repository, and some of that trust can only be
granted by a person in a browser. This command verifies each stage against
what the registries and GitHub say, and in guided mode walks the person through
the rest. Every name it uses comes from the tree: the repository from gh, the
JSR scope and packages from bindings/ts, the crate from bindings/rust, and the
PyPI project from bindings/python. The three environment names are the
contract with publish.yml.

Stages, in this order: github (the pypi, crates-io, and jsr environments with
the maintainer as reviewer and the v* tag policy), jsr (every workspace package
exists and is linked to this repository), pypi (the project exists, or its
pending trusted publisher is registered), crates-io (the first-publish token
secret until the crate exists, then a trusted publisher and no secret), and
racket (the catalog entry names the newest release tag). Each stage ends
complete, waiting (it cannot be verified until an outside event, such as the
first publish), or incomplete.

  --check   verifies only. It prints one `release-publishers: <stage>: <verdict>`
            line per finding, never prompts, never opens a browser, and never
            runs a gh command that writes. It works without a terminal.
  default   guided. It needs a terminal. For each stage that is not complete it
            prints the page and the values to enter, opens the page, performs
            gh effects only after a [y/N] confirmation, then verifies again.

STAGE names select a subset, still run in the order above. An unknown name is
refused before any effect. A registry or gh that cannot be reached reports
`cannot verify` for that stage and the rest still run. The command exits 1 when
any selected stage ends incomplete or unverifiable, 2 on a bad argument, and 0
otherwise. tools/release_publishers_test.py drives every stage against fake
registry answers and a fake gh.
"""

import argparse
import getpass
import json
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
import webbrowser
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = "publish.yml"
ENVIRONMENTS = ("pypi", "crates-io", "jsr")
TAG_POLICY = "v*"
# The crates-io environment secret publish.yml reads for the first publish, before
# the trusted publisher takes over. This is its name, which the messages print.
FIRST_PUBLISH_VARIABLE = "CARGO_REGISTRY_TOKEN"
RACKET_PACKAGE = "glowcap"
STAGES = ("github", "jsr", "pypi", "crates-io", "racket")
COMPLETE, WAITING, INCOMPLETE, CANNOT = "complete", "waiting", "incomplete", "cannot verify"
TIMEOUT = 20


class Unverifiable(Exception):
    """A registry answer that is neither success nor the normal absence of a project."""


ERRORS = (
    urllib.error.URLError,
    subprocess.SubprocessError,
    json.JSONDecodeError,
    OSError,
    KeyError,
    TypeError,
    AttributeError,
    Unverifiable,
)


@dataclass
class Verdict:
    state: str
    notes: list
    items: tuple = ()


def fetch(url, slug):
    """GET url and return (status, body). An HTTP error status is an answer, not a failure."""
    request = urllib.request.Request(url, headers={"User-Agent": f"glowcap-release-publishers ({slug})"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.read().decode(errors="replace")
        finally:
            error.close()


def gh(*args, input=None):
    """Run gh inside this checkout, so the repository is the one the script lives in whatever the caller's directory."""
    return subprocess.run(
        ["gh", *args], input=input, check=True, capture_output=True, text=True, timeout=60, cwd=ROOT
    ).stdout


def ask(prompt):
    return input(prompt)


def ask_secret(prompt):
    return getpass.getpass(prompt)


def open_page(url):
    try:
        webbrowser.open(url)
    except (webbrowser.Error, OSError):
        pass  # best-effort: every remedy prints the URL as well


def interactive():
    return sys.stdin.isatty()


def say(stage, text):
    print(f"release-publishers: {stage}: {text}")


def confirm(question):
    return ask(f"release-publishers: {question} [y/N] ").strip().lower() in ("y", "yes")


def present(status, url):
    if status == 200:
        return True
    if status == 404:
        return False
    raise Unverifiable(f"{url} answered HTTP {status}")


def describe(error):
    """One short line for a failure to reach a registry or gh."""
    if isinstance(error, subprocess.CalledProcessError):
        lines = (error.stderr or "").strip().splitlines()
        return f"gh {' '.join(map(str, error.cmd[1:3]))} failed: {lines[0] if lines else f'exit {error.returncode}'}"
    if isinstance(error, subprocess.TimeoutExpired):
        return f"gh {' '.join(map(str, error.cmd[1:3]))} timed out"
    if isinstance(error, urllib.error.URLError):
        return f"cannot reach the registry: {error.reason}"
    if isinstance(error, json.JSONDecodeError):
        return "an answer was not valid JSON"
    if isinstance(error, KeyError):
        return f"an answer lacks {error}"
    if isinstance(error, (TypeError, AttributeError)):
        return "an answer has an unexpected shape"
    return str(error).replace("\n", " ") or type(error).__name__


# What the tree states.


def read_jsonc(path):
    """A deno.json holds // comment lines. Drop them and read the rest as JSON."""
    if not path.is_file():
        raise ValueError(f"{path} is missing")
    text = "\n".join(line for line in path.read_text().splitlines() if not line.lstrip().startswith("//"))
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"{path} is not JSON once its // comment lines are removed: {error}") from error


def jsr_packages(root):
    base = root / "bindings/ts"
    members = read_jsonc(base / "deno.json").get("workspace")
    if not members:
        raise ValueError("bindings/ts/deno.json lists no workspace members")
    names = []
    for member in members:
        name = read_jsonc(base / member / "deno.json").get("name") or ""
        parts = re.fullmatch(r"@([a-z0-9-]+)/([a-z0-9-]+)", name)
        if not parts:
            raise ValueError(f'bindings/ts/{member}/deno.json has no "name" such as "@scope/package"')
        names.append(parts.groups())
    scopes = sorted({scope for scope, _ in names})
    if len(scopes) != 1:
        raise ValueError(f"bindings/ts members span several JSR scopes: {', '.join(scopes)}")
    return scopes[0], tuple(package for _, package in names)


def manifest_name(root, relative, table):
    path = root / relative
    if not path.is_file():
        raise ValueError(f"{relative} is missing")
    name = tomllib.loads(path.read_text()).get(table, {}).get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"{relative} has no [{table}] name")
    return name


def derive(root, stages):
    """The names the selected stages need, or a ValueError naming the missing fact."""
    facts = {}
    if "jsr" in stages:
        facts["scope"], facts["packages"] = jsr_packages(root)
    if "crates-io" in stages:
        facts["crate"] = manifest_name(root, "bindings/rust/Cargo.toml", "package")
    if "pypi" in stages:
        facts["project"] = manifest_name(root, "bindings/python/pyproject.toml", "project")
    return facts


def racket_source(slug, tag):
    return f"https://github.com/{slug}.git?path=bindings/racket#{tag}"


class Context:
    """The facts a run reads from gh once and the names derived from the tree."""

    def __init__(self, facts):
        self.facts = facts
        self.memo = {}

    def remember(self, key, compute):
        if key not in self.memo:
            self.memo[key] = compute()
        return self.memo[key]

    def slug(self):
        return self.remember(
            "slug", lambda: gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner").strip()
        )

    def owner_and_name(self):
        owner, _, name = self.slug().partition("/")
        return owner, name

    def user_id(self):
        return self.remember("user", lambda: json.loads(gh("api", "user", "--jq", ".id")))

    def tag(self):
        """The newest published release tag, or '' before the first release."""
        tag = self.remember(
            "tag",
            lambda: gh(
                "release", "list", "--exclude-drafts", "--limit", "1", "--json", "tagName", "--jq", ".[0].tagName"
            ).strip(),
        )
        return "" if tag == "null" else tag


# Stage 1: the GitHub environments.


def not_found(error):
    text = error.stderr or ""
    return "404" in text or "Not Found" in text


def tag_policies(slug, environment):
    data = json.loads(gh("api", f"repos/{slug}/environments/{environment}/deployment-branch-policies"))
    return {(policy["name"], policy["type"]) for policy in data["branch_policies"]}


def environment_findings(slug, environment, user):
    try:
        data = json.loads(gh("api", f"repos/{slug}/environments/{environment}"))
    except subprocess.CalledProcessError as error:
        if not_found(error):
            return [f"{environment}: the environment does not exist"]
        raise
    reviewers = {
        entry["reviewer"]["id"]
        for rule in data.get("protection_rules", [])
        if rule.get("type") == "required_reviewers"
        for entry in rule.get("reviewers", [])
    }
    findings = []
    if user not in reviewers:
        findings.append(f"{environment}: GitHub user {user} is not a required reviewer")
    policy = data.get("deployment_branch_policy") or {}
    if policy.get("protected_branches") or not policy.get("custom_branch_policies"):
        findings.append(f"{environment}: deployments are not limited to custom branch and tag policies")
    elif (TAG_POLICY, "tag") not in tag_policies(slug, environment):
        findings.append(f"{environment}: the {TAG_POLICY} tag policy is missing")
    return findings


def verify_github(context):
    slug, user = context.slug(), context.user_id()
    findings, broken = [], []
    for environment in ENVIRONMENTS:
        found = environment_findings(slug, environment, user)
        findings.extend(found)
        if found:
            broken.append(environment)
    return Verdict(INCOMPLETE if findings else COMPLETE, findings, tuple(broken))


def repair_github(context, verdict):
    slug, user = context.slug(), context.user_id()
    say(
        "github",
        f"this will set {', '.join(verdict.items)} on {slug} with GitHub user {user} as the required reviewer "
        f"and deployments limited to the {TAG_POLICY} tag policy",
    )
    if not confirm("Apply it?"):
        say("github", "nothing was written")
        return False
    body = {
        "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
        "reviewers": [{"type": "User", "id": user}],
    }
    for environment in verdict.items:
        gh("api", "-X", "PUT", f"repos/{slug}/environments/{environment}", "--input", "-", input=json.dumps(body))
        if (TAG_POLICY, "tag") not in tag_policies(slug, environment):
            gh(
                "api",
                "-X",
                "POST",
                f"repos/{slug}/environments/{environment}/deployment-branch-policies",
                "-f",
                f"name={TAG_POLICY}",
                "-f",
                "type=tag",
            )
    return True


# Stage 2: the JSR packages.


def verify_jsr(context):
    scope, packages, slug = context.facts["scope"], context.facts["packages"], context.slug()
    url = f"https://api.jsr.io/scopes/{scope}/packages?limit=100"
    status, body = fetch(url, slug)
    findings, items, linked, total = [], [], {}, 0
    if present(status, url):
        data = json.loads(body)
        linked, total = {entry["name"]: entry.get("githubRepository") for entry in data["items"]}, data["total"]
    else:
        findings.append(f"the scope @{scope} does not exist on jsr.io")
    for package in packages:
        name = f"@{scope}/{package}"
        if package not in linked:
            findings.append(f"{name} does not exist on jsr.io")
            items.append((package, "new"))
        elif not linked[package]:
            findings.append(f"{name} is not linked to a GitHub repository")
            items.append((package, "link"))
        elif f"{linked[package]['owner']}/{linked[package]['name']}".lower() != slug.lower():
            findings.append(f"{name} is linked to {linked[package]['owner']}/{linked[package]['name']} and not {slug}")
            items.append((package, "link"))
    if total > len(linked):
        findings.append(f"the listing holds {len(linked)} of {total} packages in @{scope}, so coverage is incomplete")
    return Verdict(INCOMPLETE if findings else COMPLETE, findings, tuple(items))


def link_jsr(context, verdict):
    scope, slug = context.facts["scope"], context.slug()
    if not verdict.items:
        return False
    steps = [
        f"open https://jsr.io/new, choose scope {scope} and package name {package}"
        for package, kind in verdict.items
        if kind == "new"
    ]
    steps += [
        f"open https://jsr.io/@{scope}/{package}/settings and link the GitHub repository {slug}"
        for package, _ in verdict.items
    ]
    for number, step in enumerate(steps, 1):
        say("jsr", f"step {number}: {step}")
    created = any(kind == "new" for _, kind in verdict.items)
    open_page("https://jsr.io/new" if created else f"https://jsr.io/@{scope}/{verdict.items[0][0]}/settings")
    return confirm("Are the packages created and linked?")


# Stage 3: PyPI.


def verify_pypi(context):
    url = f"https://pypi.org/pypi/{context.facts['project']}/json"
    if present(fetch(url, context.slug())[0], url):
        return Verdict(COMPLETE, [])
    return Verdict(WAITING, ["a pending trusted publisher is not visible before the first publish"])


def register_pypi(context, verdict):
    owner, name = context.owner_and_name()
    say("pypi", "add a pending publisher on GitHub with these values")
    for label, value in (
        ("PyPI project name", context.facts["project"]),
        ("Owner", owner),
        ("Repository name", name),
        ("Workflow name", WORKFLOW),
        ("Environment name", "pypi"),
    ):
        say("pypi", f"{label}: {value}")
    say("pypi", "page: https://pypi.org/manage/account/publishing/")
    open_page("https://pypi.org/manage/account/publishing/")
    return confirm("Is the pending publisher registered?")


# Stage 4: crates.io.


def verify_crates(context):
    crate, slug = context.facts["crate"], context.slug()
    url = f"https://crates.io/api/v1/crates/{crate}"
    exists = present(fetch(url, slug)[0], url)
    names = gh("api", f"repos/{slug}/environments/crates-io/secrets", "--jq", ".secrets[].name").split()
    secret = FIRST_PUBLISH_VARIABLE in names
    if not exists and secret:
        return Verdict(WAITING, [f"the first publish of {crate} will use the {FIRST_PUBLISH_VARIABLE} secret"])
    if not exists:
        return Verdict(
            INCOMPLETE,
            [
                f"{crate} is not on crates.io and the crates-io environment has no {FIRST_PUBLISH_VARIABLE} secret "
                "for the first publish"
            ],
            ("first",),
        )
    if secret:
        return Verdict(
            INCOMPLETE,
            [
                f"{crate} is on crates.io, so its trusted publisher must take over and the "
                f"{FIRST_PUBLISH_VARIABLE} secret must be deleted"
            ],
            ("handover",),
        )
    return Verdict(COMPLETE, [])


def hand_over_crates(context, verdict):
    slug, crate = context.slug(), context.facts["crate"]
    if verdict.items == ("first",):
        say("crates-io", f"create a token with the publish-new and publish-update scopes for crate {crate}")
        say("crates-io", "page: https://crates.io/settings/tokens/new")
        open_page("https://crates.io/settings/tokens/new")
        token = ask_secret("release-publishers: crates-io: paste the token (input is hidden): ").strip()
        if not token or not confirm(f"Store it as {FIRST_PUBLISH_VARIABLE} on the crates-io environment of {slug}?"):
            say("crates-io", "nothing was written")
            return False
        gh("secret", "set", FIRST_PUBLISH_VARIABLE, "--env", "crates-io", "-R", slug, input=token)
        return True
    owner, name = context.owner_and_name()
    page = f"https://crates.io/crates/{crate}/settings/new-trusted-publisher"
    say("crates-io", "add a trusted publisher with these values")
    for label, value in (
        ("Repository owner", owner),
        ("Repository name", name),
        ("Workflow filename", WORKFLOW),
        ("Environment", "crates-io"),
    ):
        say("crates-io", f"{label}: {value}")
    say("crates-io", f"page: {page}")
    open_page(page)
    if not confirm("Is the trusted publisher added?"):
        return False
    if not confirm(f"Delete the {FIRST_PUBLISH_VARIABLE} secret from the crates-io environment of {slug}?"):
        say("crates-io", f"the {FIRST_PUBLISH_VARIABLE} secret was kept")
        return False
    gh("secret", "delete", FIRST_PUBLISH_VARIABLE, "--env", "crates-io", "-R", slug)
    say("crates-io", "revoke the token at https://crates.io/settings/tokens")
    return True


# Stage 5: the Racket catalog.


def verify_racket(context):
    tag = context.tag()
    if not tag:
        return Verdict(
            WAITING, ["no release is published yet, so the catalog entry is created after the first release"]
        )
    url = f"https://pkgs.racket-lang.org/pkg/{RACKET_PACKAGE}.json"
    status, body = fetch(url, context.slug())
    expected = racket_source(context.slug(), tag)
    if not present(status, url):
        return Verdict(
            INCOMPLETE, [f"the catalog has no {RACKET_PACKAGE} entry, expected source {expected}"], ("missing",)
        )
    source = json.loads(body)["source"]
    if source != expected:
        return Verdict(INCOMPLETE, [f"the catalog source is {source} and the release expects {expected}"], ("stale",))
    return Verdict(COMPLETE, [])


def update_racket(context, verdict):
    if not verdict.items:
        return False
    expected = racket_source(context.slug(), context.tag())
    if verdict.items == ("missing",):
        page = "https://pkgs.racket-lang.org/"
        say("racket", f"sign in, then add the package {RACKET_PACKAGE} with the source {expected}")
    else:
        page = f"https://pkgs.racket-lang.org/package/{RACKET_PACKAGE}"
        say("racket", f"sign in, then change the source of {RACKET_PACKAGE} to {expected}")
    say("racket", f"page: {page}")
    open_page(page)
    return confirm("Is the catalog entry saved?")


VERIFY = {
    "github": verify_github,
    "jsr": verify_jsr,
    "pypi": verify_pypi,
    "crates-io": verify_crates,
    "racket": verify_racket,
}
REMEDY = {
    "github": repair_github,
    "jsr": link_jsr,
    "pypi": register_pypi,
    "crates-io": hand_over_crates,
    "racket": update_racket,
}


def guarded_verify(stage, context):
    try:
        return VERIFY[stage](context)
    except ERRORS as error:
        return Verdict(CANNOT, [describe(error)])


def report(stage, verdict):
    if verdict.state == COMPLETE:
        say(stage, COMPLETE)
    for note in verdict.notes:
        say(stage, f"{verdict.state}: {note}")


def settle(stage, context, guided):
    """Verify one stage and, in guided mode, walk the person through what is not complete."""
    verdict = guarded_verify(stage, context)
    report(stage, verdict)
    if guided and verdict.state in (WAITING, INCOMPLETE):
        try:
            acted = REMEDY[stage](context, verdict)
        except ERRORS as error:
            verdict = Verdict(CANNOT, [f"the step failed: {describe(error)}"])
            report(stage, verdict)
            return verdict
        if acted:
            verdict = guarded_verify(stage, context)
            report(stage, verdict)
    return verdict


def parse(argv):
    parser = argparse.ArgumentParser(
        prog="release-publishers",
        description="Verify, and walk a person through, the registry setup publish.yml needs.",
    )
    parser.add_argument("--check", action="store_true", help="verify only: no prompts, no browser, no gh writes")
    parser.add_argument("stages", nargs="*", metavar="STAGE", help=f"any of {', '.join(STAGES)} (default: all)")
    args = parser.parse_args(argv)
    unknown = [stage for stage in args.stages if stage not in STAGES]
    if unknown:
        parser.error(f"unknown stage {', '.join(unknown)}: choose from {', '.join(STAGES)}")
    return args


def main(argv=None, root=ROOT):
    args = parse(argv)
    if not args.check and not interactive():
        raise ValueError("guided mode needs a terminal, so run it with --check in a script")
    stages = [stage for stage in STAGES if not args.stages or stage in args.stages]
    context = Context(derive(root, stages))
    verdicts = [settle(stage, context, guided=not args.check) for stage in stages]
    return 1 if any(verdict.state in (INCOMPLETE, CANNOT) for verdict in verdicts) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as error:
        sys.exit(f"release-publishers: {error}")
    except (EOFError, KeyboardInterrupt):
        sys.exit("release-publishers: interrupted, nothing further was written")
