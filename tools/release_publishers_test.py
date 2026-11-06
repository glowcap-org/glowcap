"""release-publishers verifies and walks through the registry setup publish.yml needs.

These tests drive every stage of tools/release-publishers.py against fake
registry answers and a fake gh that keeps GitHub's environment and secret state,
so a guided repair is verified by the same read that found the gap. They prove
that --check reads only, that each stage names what is missing, that guided mode
writes only after a yes and passes the crates.io token on stdin and never in
argv, and that an unreachable registry reports `cannot verify` while the other
stages still run. They do not reach any registry or GitHub, so they say nothing
about the real pages, scopes, or tokens.
"""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


SCRIPT = ROOT / "tools/release-publishers.py"
SPEC = importlib.util.spec_from_file_location("release_publishers", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SLUG = "owner/project"
USER = 42
TAG = "v0.1.1"
TOKEN = "cio-secret-token-value"
SCOPE, PACKAGES = MODULE.jsr_packages(ROOT)
SOURCE = MODULE.racket_source(SLUG, TAG)


class World:
    """Fake registry answers and a fake gh. Every default is a fully set up repository."""

    def __init__(self):
        self.environments = {
            name: {"reviewers": [USER], "protected": False, "custom": True, "tags": ["v*"]}
            for name in MODULE.ENVIRONMENTS
        }
        self.jsr = {package: {"owner": "owner", "name": "project"} for package in PACKAGES}
        self.jsr_total = None
        self.pypi, self.crate, self.racket = 200, 200, (200, SOURCE)
        self.secrets, self.tag = set(), TAG
        self.fetched, self.calls, self.fetch_errors = [], [], {}
        self.racket_checksum, self.racket_error = "a" * 40, None

    def fetch(self, url, slug):
        self.fetched.append(url)
        for fragment, error in self.fetch_errors.items():
            if fragment in url:
                raise error
        host = urlsplit(url).netloc
        if host == "api.jsr.io":
            items = [{"name": name, "githubRepository": link} for name, link in self.jsr.items()]
            return 200, json.dumps({"items": items, "total": self.jsr_total or len(items)})
        if host == "pypi.org":
            return self.pypi, "{}"
        if host == "crates.io":
            return self.crate, "{}"
        status, source = self.racket
        return status, json.dumps(
            {"source": source, "checksum": self.racket_checksum, "checksum-error": self.racket_error}
        )

    def refuse(self, args, text="gh: Not Found (HTTP 404)"):
        return subprocess.CalledProcessError(1, ["gh", *args], stderr=text)

    def gh(self, *args, input=None):
        self.calls.append((args, input))
        match args:
            case ("repo", "view", *_):
                return SLUG + "\n"
            case ("api", "user", *_):
                return f"{USER}\n"
            case ("release", "list", *_):
                return self.tag + "\n"
            case ("api", "-X", "PUT", path, "--input", "-"):
                body = json.loads(input)
                known = self.environments.get(path.rsplit("/", 1)[1], {"tags": []})
                self.environments[path.rsplit("/", 1)[1]] = {
                    "reviewers": [entry["id"] for entry in body["reviewers"]],
                    "protected": body["deployment_branch_policy"]["protected_branches"],
                    "custom": body["deployment_branch_policy"]["custom_branch_policies"],
                    "tags": known["tags"],
                }
                return ""
            case ("api", "-X", "POST", path, "-f", name, "-f", _):
                self.environments[path.split("/")[-2]]["tags"].append(name.removeprefix("name="))
                return ""
            case ("api", path, "--jq", _) if path.endswith("/secrets"):
                return "".join(f"{name}\n" for name in sorted(self.secrets))
            case ("api", path) if path.endswith("/deployment-branch-policies"):
                state = self.environments.get(path.split("/")[-2])
                if state is None:
                    raise self.refuse(args)
                return json.dumps({"branch_policies": [{"name": name, "type": "tag"} for name in state["tags"]]})
            case ("api", path):
                state = self.environments.get(path.rsplit("/", 1)[1])
                if state is None:
                    raise self.refuse(args)
                rule = {
                    "type": "required_reviewers",
                    "reviewers": [{"type": "User", "reviewer": {"id": id, "login": "x"}} for id in state["reviewers"]],
                }
                return json.dumps(
                    {
                        "protection_rules": [{"type": "branch_policy"}, rule],
                        "deployment_branch_policy": {
                            "protected_branches": state["protected"],
                            "custom_branch_policies": state["custom"],
                        },
                    }
                )
            case ("secret", "set", name, *_):
                self.secrets.add(name)
                return ""
            case ("secret", "delete", name, *_):
                self.secrets.discard(name)
                return ""
        raise AssertionError(f"unexpected gh call {args}")

    def writes(self):
        return [args for args, _ in self.calls if "-X" in args or args[0] == "secret"]


class Result:
    def __init__(self, code, out, err, prompts, opened, ask_secret):
        self.code, self.out, self.err, self.prompts, self.opened, self.ask_secret = (
            code,
            out,
            err,
            prompts,
            opened,
            ask_secret,
        )

    def lines(self, stage):
        return [line for line in self.out.splitlines() if line.startswith(f"release-publishers: {stage}: ")]


def run(world, *argv, answers=(), tty=False, root=ROOT):
    """Run main() against the world and return what it printed, asked, and opened."""
    remaining, prompts = list(answers), []

    def ask(prompt):
        prompts.append(prompt)
        return remaining.pop(0)

    out, err, secret, opened = io.StringIO(), io.StringIO(), mock.Mock(return_value=TOKEN), mock.Mock()
    with (
        mock.patch.object(MODULE, "fetch", world.fetch),
        mock.patch.object(MODULE, "gh", world.gh),
        mock.patch.object(MODULE, "ask", ask),
        mock.patch.object(MODULE, "ask_secret", secret),
        mock.patch.object(MODULE, "open_page", opened),
        mock.patch.object(MODULE, "interactive", lambda: tty),
        contextlib.redirect_stdout(out),
        contextlib.redirect_stderr(err),
    ):
        code = MODULE.main(list(argv), root=root)
    return Result(
        code, out.getvalue(), err.getvalue(), prompts, [call.args[0] for call in opened.call_args_list], secret
    )


class DerivationTest(unittest.TestCase):
    def test_names_come_from_the_tree(self):
        facts = MODULE.derive(ROOT, MODULE.STAGES)
        self.assertEqual(facts["scope"], "glowcap")
        self.assertEqual(
            sorted(facts["packages"]),
            sorted(["abi", "runtime", "tcp", "iroh", "inproc", "onion", "web", "webrtc", "relay"]),
        )
        self.assertEqual((facts["crate"], facts["project"]), ("glowcap", "glowcap"))
        self.assertEqual(
            MODULE.racket_source("o/r", "v1.2.3"),
            "https://github.com/o/r/releases/download/v1.2.3/glowcap-racket-v1.2.3.zip",
        )

    def test_a_missing_manifest_or_field_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, "Cargo.toml is missing"):
                MODULE.derive(root, ["crates-io"])
            (root / "bindings/rust").mkdir(parents=True)
            (root / "bindings/rust/Cargo.toml").write_text('[package]\nversion = "1"\n')
            with self.assertRaisesRegex(ValueError, r"no \[package\] name"):
                MODULE.derive(root, ["crates-io"])
            with self.assertRaises(ValueError):
                MODULE.derive(root, ["jsr"])

    def test_a_run_from_another_directory_reads_the_same_tree(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            os.chdir(temp)
            try:
                result = run(World(), "--check")
            finally:
                os.chdir(previous)
        self.assertEqual(result.code, 0)


class CheckTest(unittest.TestCase):
    def test_gh_runs_inside_the_checkout_with_input_on_stdin(self):
        with mock.patch.object(subprocess, "run", return_value=mock.Mock(stdout="out")) as launched:
            self.assertEqual(MODULE.gh("secret", "set", "X", input="token"), "out")
        self.assertEqual(launched.call_args.args, (["gh", "secret", "set", "X"],))
        self.assertEqual(launched.call_args.kwargs["cwd"], ROOT)
        self.assertEqual(launched.call_args.kwargs["input"], "token")
        self.assertTrue(launched.call_args.kwargs["check"])

    def test_complete_world_reads_only(self):
        world = World()
        result = run(world, "--check")
        self.assertEqual(result.code, 0)
        self.assertEqual(result.out.splitlines(), [f"release-publishers: {stage}: complete" for stage in MODULE.STAGES])
        self.assertEqual(world.writes(), [])
        self.assertEqual(result.prompts, [])
        self.assertEqual(result.opened, [])
        result.ask_secret.assert_not_called()

    def test_registry_user_agent_names_the_repository(self):
        seen = []
        world = World()
        original = world.fetch
        world.fetch = lambda url, slug: (seen.append(slug), original(url, slug))[1]
        run(world, "--check", "pypi")
        self.assertEqual(seen, [SLUG])

    def test_stage_selection_runs_those_stages_in_order(self):
        world = World()
        result = run(world, "--check", "racket", "jsr")
        self.assertEqual([line.split(": ")[1] for line in result.out.splitlines()], ["jsr", "racket"])
        self.assertEqual(len(world.fetched), 2)

    def test_unknown_stage_is_refused_before_any_effect(self):
        world = World()
        with self.assertRaises(SystemExit) as raised:
            run(world, "--check", "npm")
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual((world.fetched, world.calls), ([], []))

    def test_guided_mode_needs_a_terminal(self):
        world = World()
        with self.assertRaisesRegex(ValueError, "--check"):
            run(world, tty=False)
        self.assertEqual((world.fetched, world.calls), ([], []))

    def test_unreachable_registry_still_reports_the_other_stages(self):
        world = World()
        world.fetch_errors["pypi.org"] = urllib.error.URLError("offline")
        result = run(world, "--check")
        self.assertEqual(result.code, 1)
        self.assertEqual(
            result.lines("pypi"), ["release-publishers: pypi: cannot verify: cannot reach the registry: offline"]
        )
        for stage in ("github", "jsr", "crates-io", "racket"):
            self.assertEqual(result.lines(stage), [f"release-publishers: {stage}: complete"])

    def test_failing_gh_and_unexpected_status_do_not_traceback(self):
        world = World()
        original = world.gh

        def failing(*args, input=None):
            if args[:2] == ("api", "user"):
                raise world.refuse(args, "gh: authentication required")
            return original(*args, input=input)

        world.gh = failing
        world.crate = 503
        result = run(world, "--check")
        self.assertEqual(result.code, 1)
        self.assertIn("github: cannot verify: gh api user failed: gh: authentication required", result.out)
        self.assertIn("crates-io: cannot verify: https://crates.io/api/v1/crates/glowcap answered HTTP 503", result.out)


class GithubTest(unittest.TestCase):
    def broken(self):
        world = World()
        del world.environments["crates-io"]
        world.environments["pypi"]["reviewers"] = [7]
        world.environments["jsr"]["tags"] = []
        return world

    def test_each_gap_is_incomplete_and_names_the_environment(self):
        def missing(world):
            del world.environments["jsr"]

        def reviewer(world):
            world.environments["jsr"]["reviewers"] = [7]

        def protected(world):
            world.environments["jsr"].update(protected=True, custom=False)

        def tag(world):
            world.environments["jsr"]["tags"] = []

        for name, damage, expected in (
            ("missing", missing, "does not exist"),
            ("reviewer", reviewer, "not a required reviewer"),
            ("protected", protected, "not limited to custom"),
            ("tag", tag, "v* tag policy is missing"),
        ):
            with self.subTest(name):
                world = World()
                damage(world)
                result = run(world, "--check", "github")
                self.assertEqual(result.code, 1)
                self.assertEqual(len(result.lines("github")), 1)
                self.assertRegex(result.lines("github")[0], f"incomplete: jsr: .*{expected}")

    def test_guided_repair_writes_the_reviewer_and_policy_then_verifies(self):
        world = self.broken()
        result = run(world, "github", answers=["y"], tty=True)
        self.assertEqual(result.code, 0)
        puts = [(args, json.loads(stdin)) for args, stdin in world.calls if args[:3] == ("api", "-X", "PUT")]
        self.assertEqual(sorted(args[3].rsplit("/", 1)[1] for args, _ in puts), ["crates-io", "jsr", "pypi"])
        for _, body in puts:
            self.assertEqual(
                body,
                {
                    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
                    "reviewers": [{"type": "User", "id": USER}],
                },
            )
        posts = [args for args, _ in world.calls if args[:3] == ("api", "-X", "POST")]
        self.assertEqual(sorted(args[3].split("/")[-2] for args in posts), ["crates-io", "jsr"])
        self.assertEqual(posts[0][4:], ("-f", "name=v*", "-f", "type=tag"))
        self.assertEqual(result.lines("github")[-1], "release-publishers: github: complete")

    def test_a_no_writes_nothing_and_stays_incomplete(self):
        world = self.broken()
        result = run(world, "github", answers=["n"], tty=True)
        self.assertEqual(result.code, 1)
        self.assertEqual(world.writes(), [])
        self.assertIn("nothing was written", result.out)


class JsrTest(unittest.TestCase):
    def test_missing_package_and_foreign_link_are_named(self):
        world = World()
        del world.jsr["relay"]
        world.jsr["web"] = {"owner": "someone", "name": "else"}
        world.jsr["tcp"] = None
        result = run(world, "--check", "jsr")
        self.assertEqual(result.code, 1)
        text = result.out
        self.assertIn(f"@{SCOPE}/relay does not exist", text)
        self.assertIn(f"@{SCOPE}/web is linked to someone/else and not {SLUG}", text)
        self.assertIn(f"@{SCOPE}/tcp is not linked to a GitHub repository", text)

    def test_a_listing_cut_off_at_the_page_size_cannot_pass(self):
        world = World()
        world.jsr_total = len(PACKAGES) + 3
        result = run(world, "--check", "jsr")
        self.assertEqual(result.code, 1)
        self.assertIn(f"{len(PACKAGES)} of {len(PACKAGES) + 3} packages", result.out)
        self.assertIn("coverage is incomplete", result.out)

    def test_guided_steps_name_the_pages_and_values(self):
        world = World()
        del world.jsr["relay"]
        result = run(world, "jsr", answers=["n"], tty=True)
        self.assertEqual(result.opened, ["https://jsr.io/new"])
        self.assertIn(f"open https://jsr.io/new, choose scope {SCOPE} and package name relay", result.out)
        self.assertIn(f"open https://jsr.io/@{SCOPE}/relay/settings and link the GitHub repository {SLUG}", result.out)
        self.assertEqual(result.code, 1)

    def test_guided_confirmation_verifies_again(self):
        world = World()
        world.jsr["web"] = None
        original, reads = world.fetch, []

        def repaired_after_the_first_read(url, slug):
            answer = original(url, slug)
            if not reads:
                world.jsr["web"] = {"owner": "owner", "name": "project"}
            reads.append(url)
            return answer

        world.fetch = repaired_after_the_first_read
        result = run(world, "jsr", answers=["y"], tty=True)
        self.assertEqual(result.code, 0)
        self.assertEqual(len(reads), 2)
        self.assertEqual(result.opened, [f"https://jsr.io/@{SCOPE}/web/settings"])
        self.assertEqual(result.lines("jsr")[-1], "release-publishers: jsr: complete")


class PypiTest(unittest.TestCase):
    def test_verdicts(self):
        for status, expected in ((404, "waiting: a pending trusted publisher"), (200, "complete")):
            with self.subTest(status):
                world = World()
                world.pypi = status
                result = run(world, "--check", "pypi")
                self.assertEqual(result.code, 0)
                self.assertRegex(result.lines("pypi")[0], expected)

    def test_guided_prints_the_form_values(self):
        world = World()
        world.pypi = 404
        result = run(world, "pypi", answers=["y"], tty=True)
        self.assertEqual(result.opened, ["https://pypi.org/manage/account/publishing/"])
        for line in (
            "PyPI project name: glowcap",
            "Owner: owner",
            "Repository name: project",
            "Workflow name: publish.yml",
            "Environment name: pypi",
        ):
            self.assertIn(line, result.out)
        self.assertEqual(result.code, 0)


class CratesTest(unittest.TestCase):
    def test_crate_and_secret_decide_the_verdict(self):
        for exists, secret, expected in (
            (False, False, "incomplete"),
            (False, True, "waiting"),
            (True, True, "incomplete"),
            (True, False, "complete"),
        ):
            with self.subTest(exists=exists, secret=secret):
                world = World()
                world.crate = 200 if exists else 404
                world.secrets = {MODULE.FIRST_PUBLISH_VARIABLE} if secret else set()
                result = run(world, "--check", "crates-io")
                self.assertRegex(result.lines("crates-io")[0], f"crates-io: {expected}")
                self.assertEqual(result.code, 1 if expected == "incomplete" else 0)

    def test_first_publish_token_goes_to_gh_on_stdin_only(self):
        world = World()
        world.crate = 404
        result = run(world, "crates-io", answers=["y"], tty=True)
        self.assertEqual(result.opened, ["https://crates.io/settings/tokens/new"])
        result.ask_secret.assert_called_once()
        sets = [(args, stdin) for args, stdin in world.calls if args[:2] == ("secret", "set")]
        self.assertEqual(sets, [(("secret", "set", "CARGO_REGISTRY_TOKEN", "--env", "crates-io", "-R", SLUG), TOKEN)])
        self.assertTrue(all(TOKEN not in str(args) for args, _ in world.calls))
        self.assertNotIn(TOKEN, result.out)
        self.assertEqual((result.code, result.lines("crates-io")[-1].split(": ")[2]), (0, "waiting"))

    def test_first_publish_with_no_confirmation_writes_nothing(self):
        world = World()
        world.crate = 404
        result = run(world, "crates-io", answers=["n"], tty=True)
        self.assertEqual((result.code, world.writes()), (1, []))

    def test_after_publish_the_secret_goes_only_after_the_second_yes(self):
        for answers, deleted, code in ((["y", "y"], True, 0), (["y", "n"], False, 1), (["n"], False, 1)):
            with self.subTest(answers=answers):
                world = World()
                world.secrets = {MODULE.FIRST_PUBLISH_VARIABLE}
                result = run(world, "crates-io", answers=answers, tty=True)
                self.assertEqual(MODULE.FIRST_PUBLISH_VARIABLE in world.secrets, not deleted)
                self.assertEqual(result.code, code)
                self.assertEqual(result.opened, ["https://crates.io/crates/glowcap/settings/new-trusted-publisher"])
                for line in (
                    "Repository owner: owner",
                    "Repository name: project",
                    "Workflow filename: publish.yml",
                    "Environment: crates-io",
                ):
                    self.assertIn(line, result.out)
                self.assertEqual("https://crates.io/settings/tokens" in result.out, deleted)
                result.ask_secret.assert_not_called()


class RacketTest(unittest.TestCase):
    def test_verdicts(self):
        cases = (
            ("no release", lambda w: setattr(w, "tag", ""), "waiting: no release", 0),
            (
                "missing entry",
                lambda w: setattr(w, "racket", (404, "")),
                "incomplete: the catalog has no glowcap entry",
                1,
            ),
            (
                "stale source",
                lambda w: setattr(w, "racket", (200, "https://github.com/old/repo#v0.0.1")),
                f"incomplete: the catalog source is https://github.com/old/repo#v0.0.1 and the release expects {SOURCE}",
                1,
            ),
            ("matching", lambda w: None, "complete", 0),
            (
                "empty checksum",
                lambda w: setattr(w, "racket_checksum", ""),
                "incomplete: the catalog could not read the package",
                1,
            ),
            (
                "download error",
                lambda w: setattr(w, "racket_error", "unsafe link"),
                "incomplete: the catalog could not read the package: unsafe link",
                1,
            ),
        )
        for name, damage, expected, code in cases:
            with self.subTest(name):
                world = World()
                damage(world)
                result = run(world, "--check", "racket")
                self.assertEqual(result.code, code)
                self.assertIn(f"racket: {expected}", result.out)
                if name == "no release":
                    self.assertEqual(world.fetched, [])

    def test_guided_pages(self):
        for name, racket, page, words in (
            ("missing", (404, ""), "https://pkgs.racket-lang.org/", "add the package glowcap"),
            ("stale", (200, "x"), "https://pkgs.racket-lang.org/package/glowcap", "change the source of glowcap"),
        ):
            with self.subTest(name):
                world = World()
                world.racket = racket
                result = run(world, "racket", answers=["n"], tty=True)
                self.assertEqual(result.opened, [page])
                self.assertIn(f"{words}", result.out)
                self.assertIn(SOURCE, result.out)


if __name__ == "__main__":
    unittest.main()
