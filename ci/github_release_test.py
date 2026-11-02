"""The GitHub release script holds a release to its exact archives, draft, and public state.

These tests drive every mode of ci/github_release.py against built
archives and a stub gh, then run the release.yml steps that call it. They prove
that assemble refuses any archive whose digest, metadata, or entry points
disagree with the release, that a re-run of the release job resumes only a
draft of its own run holding matching uploads, that the release is made public
only after the complete draft verifies, and that publish.yml accepts only a
signed tag whose public release holds exactly the inventory. A failure here
means a release could ship bytes nobody verified, or a failed run could not
resume. The tests do not reach GitHub, so they say nothing about the Actions
runner itself.
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import github_release as RELEASE
from workflows import ROOT, jobs, run, stub

SCRIPT = ROOT / "ci/github_release.py"
REPOSITORY = "owner/project"
COMMIT = "a" * 40
TAG = "v0.1.0"
MARKER = RELEASE.run_marker("123")
needs_jq = unittest.skipUnless(shutil.which("jq"), "the release steps parse state with jq")


@contextlib.contextmanager
def workdir():
    """A fresh working directory, because the script reads release-assets/ and artifacts/ relative to it."""
    previous = Path.cwd()
    with tempfile.TemporaryDirectory() as temp:
        os.chdir(temp)
        try:
            yield Path(temp)
        finally:
            os.chdir(previous)


def run_main(*argv, **env):
    """Run main() as the workflow would and return what it printed."""
    environment = {
        "PATH": os.environ["PATH"],
        "HOME": os.environ.get("HOME", ""),
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_RUN_ID": "123",
        "GITHUB_SHA": COMMIT,
        **env,
    }
    environment = {key: value for key, value in environment.items() if value is not None}
    stdout = io.StringIO()
    with (
        mock.patch.dict(os.environ, environment, clear=True),
        mock.patch.object(sys, "argv", ["github_release.py", *argv]),
        contextlib.redirect_stdout(stdout),
    ):
        RELEASE.main()
    return stdout.getvalue()


def minimum_runtime(target):
    return "macOS 14.0.0" if target.endswith("-macos") else "glibc 2.31.0"


def archive_bytes(role, target, *, meta=None, omit=None, empty=None):
    """A release tarball holding its metadata, common files, and the role's entry points."""
    metadata = {
        "version": TAG[1:],
        "target": target,
        "revision": COMMIT,
        "dirty": False,
        "minimum_runtime": minimum_runtime(target),
        **(meta or {}),
    }
    members = {"share/glowcap/release.json": json.dumps(metadata).encode()}
    for name in (*RELEASE.COMMON_FILES, *RELEASE.ENTRY_POINTS[role]):
        members[name] = b"" if name == empty else b"content"
    members.pop(omit, None)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, data in members.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    return buffer.getvalue()


def build_artifacts(root, problems=None):
    """The run's download-artifact tree: one archives-<runner> directory per target, one folder per role."""
    problems = problems or {}
    for target in RELEASE.TARGETS:
        for role, folder in (("sdk", "release"), ("product", "glowcap-release")):
            problem = problems.get((role, target), {})
            if problem.get("absent"):
                continue
            directory = root / f"archives-{target}" / folder
            directory.mkdir(parents=True)
            named = problem.get("named", target)
            name = RELEASE.archive_name(TAG, named, role)
            data = archive_bytes(role, named, **problem.get("options", {}))
            if not problem.get("missing"):
                (directory / name).write_bytes(data)
            digest = problem.get("digest", hashlib.sha256(data).hexdigest())
            (directory / "SHA256SUMS").write_text(f"{digest}  {name}\n")


def write_assets(names, content=b"approved"):
    Path("release-assets").mkdir(exist_ok=True)
    for name in names:
        (Path("release-assets") / name).write_bytes(content if content else name.encode())


class Assemble(unittest.TestCase):
    def test_archives_are_copied_with_one_checksum_file_and_the_release_facts(self):
        with workdir() as root:
            build_artifacts(root / "artifacts")
            output = run_main("assemble", "artifacts", TAG)
            self.assertEqual(output, f"Assembled 8 archives for {TAG} at {COMMIT}\n")
            archives = sorted(path.name for path in Path("release-assets").glob("*.tar.gz"))
            self.assertEqual(len(archives), 8)
            self.assertEqual(
                sorted(path.name for path in Path("release-assets").iterdir()), sorted([*archives, "SHA256SUMS"])
            )
            sums = Path("release-assets/SHA256SUMS").read_text().splitlines()
            self.assertEqual(
                sums,
                [
                    f"{hashlib.sha256((Path('release-assets') / name).read_bytes()).hexdigest()}  {name}"
                    for name in archives
                ],
            )
            facts = json.loads(Path("artifacts/release.json").read_text())
            self.assertEqual(
                {key: facts[key] for key in ("repository", "version", "tag", "commit", "run")},
                {
                    "repository": f"https://github.com/{REPOSITORY}",
                    "version": "0.1.0",
                    "tag": TAG,
                    "commit": COMMIT,
                    "run": f"https://github.com/{REPOSITORY}/actions/runs/123",
                },
            )
            self.assertEqual([fact["name"] for fact in facts["archives"]], archives)
            for fact in facts["archives"]:
                self.assertIn(fact["role"], ("product", "sdk"))
                self.assertEqual(fact["minimum_runtime"], minimum_runtime(fact["target"]))
            self.assertEqual(
                {(fact["target"], fact["role"]) for fact in facts["archives"]},
                {(target, role) for target in RELEASE.TARGETS for role in ("product", "sdk")},
            )

    def test_every_disagreement_between_archive_and_release_is_refused(self):
        linux = "x86_64-linux"
        cases = {
            "digest mismatch": ({("sdk", linux): {"digest": "0" * 64}}, "packaged checksum mismatch"),
            "missing archive": ({("product", linux): {"missing": True}}, "packaged checksum mismatch"),
            "missing runner": ({("product", linux): {"absent": True}}, "exactly the eight"),
            "wrong revision": ({("sdk", linux): {"options": {"meta": {"revision": "b" * 40}}}}, "metadata disagrees"),
            "wrong version": ({("sdk", linux): {"options": {"meta": {"version": "0.2.0"}}}}, "metadata disagrees"),
            "dirty tree": ({("product", linux): {"options": {"meta": {"dirty": True}}}}, "metadata disagrees"),
            "malformed runtime": (
                {("sdk", linux): {"options": {"meta": {"minimum_runtime": "glibc 2"}}}},
                "metadata disagrees",
            ),
            "runtime of another OS": (
                {("sdk", "aarch64-macos"): {"options": {"meta": {"minimum_runtime": "glibc 2.31.0"}}}},
                "metadata disagrees",
            ),
            "unequal minimums": (
                {("sdk", linux): {"options": {"meta": {"minimum_runtime": "glibc 2.35.0"}}}},
                "disagree on the minimum runtime",
            ),
            "unknown target": ({("sdk", linux): {"named": "riscv-linux"}}, "unexpected release archive"),
            "empty entry point": (
                {("product", linux): {"options": {"empty": "bin/glowcap"}}},
                "missing release entry point",
            ),
        }
        for label, (problems, message) in cases.items():
            with self.subTest(label), workdir() as root:
                build_artifacts(root / "artifacts", problems)
                with self.assertRaisesRegex(ValueError, message):
                    run_main("assemble", "artifacts", TAG)

    def test_an_archive_missing_an_entry_point_is_refused(self):
        for role, member in (
            ("product", "libexec/rooms-server"),
            ("sdk", "include/glowcap_ocapn.h"),
            ("sdk", "LICENSE-APACHE"),
        ):
            with self.subTest(member), workdir() as root:
                build_artifacts(root / "artifacts", {(role, "aarch64-linux"): {"options": {"omit": member}}})
                with self.assertRaises((ValueError, KeyError)):
                    run_main("assemble", "artifacts", TAG)


class Bundles(unittest.TestCase):
    GH = """#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
with open(os.environ['GH_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
assert sys.argv[1:3] == ['attestation', 'download']
# gh opens the file named on its command line from its own working directory.
digest = hashlib.sha256(Path(sys.argv[3]).read_bytes()).hexdigest()
lines = {'one': 1, 'two': 2, 'none': 0}[os.environ['GH_MODE']]
if lines:
    Path(f'sha256:{digest}.jsonl').write_text('{"bundle": 1}\\n' * lines)
"""

    def prepare(self, root, mode, missing=None):
        signed = [name for name in RELEASE.inventory(TAG) if not name.endswith(".json")]
        write_assets([*signed, f"glowcap-rooms-{TAG}.spdx.json"], content=b"")
        if missing:
            (Path("release-assets") / missing).unlink()
        stub(root / "bin", "gh", self.GH)
        return {
            "PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}",
            "GH_MODE": mode,
            "GH_LOG": str(root / "gh.log"),
        }

    def test_each_signed_asset_gets_a_bundle_named_beside_it(self):
        with workdir() as root:
            environment = self.prepare(root, "one")
            run_main("bundles", TAG, **environment)
            self.assertEqual(sorted(path.name for path in Path("release-assets").iterdir()), RELEASE.inventory(TAG))
            calls = [json.loads(line) for line in (root / "gh.log").read_text().splitlines()]
            self.assertEqual(len(calls), 9)
            for call in calls:
                self.assertEqual(call[3:], ["--repo", REPOSITORY, "--predicate-type", RELEASE.PROVENANCE])

    def test_a_rerun_attests_again_and_every_attestation_is_kept(self):
        with workdir() as root:
            environment = self.prepare(root, "two")
            run_main("bundles", TAG, **environment)
            bundle = Path("release-assets") / "SHA256SUMS.sigstore.json"
            self.assertEqual(len(bundle.read_text().splitlines()), 2)

    def test_a_download_without_an_attestation_is_refused(self):
        with workdir() as root:
            environment = self.prepare(root, "none")
            with self.assertRaises((ValueError, OSError)):
                run_main("bundles", TAG, **environment)

    def test_a_missing_asset_fails_the_complete_inventory(self):
        with workdir() as root:
            environment = self.prepare(root, "one", missing=f"glowcap-{TAG}-x86_64-linux.tar.gz")
            with self.assertRaisesRegex(ValueError, "not the complete asset set"):
                run_main("bundles", TAG, **environment)


class Draft(unittest.TestCase):
    NAMES = RELEASE.inventory(TAG)
    DIGEST = "sha256:" + hashlib.sha256(b"approved").hexdigest()

    def release(self, **changes):
        assets = [{"name": name, "state": "uploaded", "digest": self.DIGEST} for name in self.NAMES]
        return {"tag_name": TAG, "draft": True, "body": f"notes\n{MARKER}\n", "assets": assets, **changes}

    def state(self, answer, *argv):
        def lookup(*args, **kwargs):
            if isinstance(answer, Exception):
                raise answer
            return answer

        with mock.patch.object(RELEASE, "api", side_effect=lookup):
            return run_main(*argv or ("draft-state", TAG))

    def test_draft_state_resumes_only_matching_uploads_of_this_run(self):
        count = len(self.NAMES)
        damaged = self.release()
        damaged["assets"][0]["digest"] = "sha256:" + "0" * 64
        extra = self.release()
        extra["assets"][0]["name"] = "extra"
        duplicate = self.release()
        duplicate["assets"].append(dict(duplicate["assets"][0]))
        unfinished = self.release()
        unfinished["assets"][0]["state"] = "starter"
        partial = self.release()
        partial["assets"].pop()
        resumable = {
            "new": ([[]], False, count),
            "complete": ([[self.release()]], True, 0),
            "partial": ([[partial]], True, 1),
        }
        refused = {
            "published": self.release(draft=False),
            "foreign run": self.release(body=RELEASE.run_marker("999")),
            "no notes": self.release(body=None),
            "damaged digest": damaged,
            "extra asset": extra,
            "duplicate asset": duplicate,
            "unfinished upload": unfinished,
        }
        with workdir():
            write_assets(self.NAMES)
            for label, (answer, exists, missing) in resumable.items():
                with self.subTest(label):
                    state = json.loads(self.state(answer))
                    self.assertEqual(state["draft_exists"], exists)
                    self.assertEqual(len(state["missing_assets"]), missing)
                    self.assertEqual(state["missing_assets"], sorted(state["missing_assets"]))
            for label, release in refused.items():
                with self.subTest(label), self.assertRaises(ValueError):
                    self.state([[release]])
            with self.subTest("two releases for the tag"), self.assertRaisesRegex(ValueError, "multiple releases"):
                self.state([[self.release(), self.release()]])
            with self.subTest("releases of other tags are ignored"):
                state = json.loads(self.state([[self.release(tag_name="v0.2.0", draft=False)]]))
                self.assertEqual(state["draft_exists"], False)
            with self.subTest("network error"), self.assertRaises(subprocess.SubprocessError):
                self.state(subprocess.CalledProcessError(1, ["gh", "api"]))

    def test_verify_draft_requires_the_complete_draft(self):
        partial = self.release()
        partial["assets"].pop()
        with workdir():
            write_assets(self.NAMES)
            self.assertIn("Complete release draft", self.state([[self.release()]], "verify-draft", TAG))
            for label, answer in (
                ("no draft", [[]]),
                ("partial", [[partial]]),
                ("published", [[self.release(draft=False)]]),
            ):
                with self.subTest(label), self.assertRaises(ValueError):
                    self.state(answer, "verify-draft", TAG)

    def test_an_incomplete_local_asset_set_is_refused_before_any_upload(self):
        with workdir():
            write_assets(self.NAMES[1:])
            with self.assertRaisesRegex(ValueError, "not the complete asset set"):
                self.state([[]])


class Published(unittest.TestCase):
    def answers(self, **changes):
        assets = [{"name": name, "state": "uploaded"} for name in RELEASE.inventory(TAG)]
        return {
            f"git/ref/tags/{TAG}": {"object": {"type": "tag", "sha": "c" * 40}},
            "git/tags/" + "c" * 40: {"verification": {"verified": True}, "object": {"type": "commit", "sha": COMMIT}},
            f"releases/tags/{TAG}": {"draft": False, "tag_name": TAG, "assets": assets},
            **changes,
        }

    def check(self, answers, main_check=None):
        def lookup(repository, endpoint, *, pages=False):
            if isinstance(answers[endpoint], Exception):
                raise answers[endpoint]
            return answers[endpoint]

        with (
            mock.patch.object(RELEASE, "api", side_effect=lookup),
            mock.patch.object(RELEASE.subprocess, "run", side_effect=main_check) as run,
        ):
            return RELEASE.published(REPOSITORY, TAG), run

    def test_a_signed_tag_on_checked_main_with_the_exact_public_assets_is_accepted(self):
        commit, run = self.check(self.answers())
        self.assertEqual(commit, COMMIT)
        self.assertEqual(run.call_args[0][0][1:], ["ci/require_main_check.py", COMMIT])

    def test_each_departure_from_a_signed_checked_public_release_is_refused(self):
        release = self.answers()[f"releases/tags/{TAG}"]
        names = release["assets"]
        failed_check = subprocess.CalledProcessError(1, ["require-main-check.py"])
        cases = {
            "lightweight tag": ({f"git/ref/tags/{TAG}": {"object": {"type": "commit", "sha": COMMIT}}}, None),
            "unverified signature": (
                {
                    "git/tags/" + "c" * 40: {
                        "verification": {"verified": False},
                        "object": {"type": "commit", "sha": COMMIT},
                    }
                },
                None,
            ),
            "tag of a tree": (
                {
                    "git/tags/" + "c" * 40: {
                        "verification": {"verified": True},
                        "object": {"type": "tree", "sha": COMMIT},
                    }
                },
                None,
            ),
            "failed main check": ({}, failed_check),
            "missing asset": ({f"releases/tags/{TAG}": {**release, "assets": names[1:]}}, None),
            "extra asset": (
                {f"releases/tags/{TAG}": {**release, "assets": names + [{"name": "extra", "state": "uploaded"}]}},
                None,
            ),
            "unfinished upload": (
                {f"releases/tags/{TAG}": {**release, "assets": [dict(names[0], state="starter"), *names[1:]]}},
                None,
            ),
            "draft release": ({f"releases/tags/{TAG}": {**release, "draft": True}}, None),
            "draft hidden from the tag lookup": (
                {f"releases/tags/{TAG}": subprocess.CalledProcessError(1, ["gh", "api"])},
                None,
            ),
            "release of another tag": ({f"releases/tags/{TAG}": {**release, "tag_name": "v0.2.0"}}, None),
        }
        for label, (changes, main_check) in cases.items():
            with self.subTest(label), self.assertRaises((ValueError, subprocess.SubprocessError)):
                self.check(self.answers(**changes), main_check)

    def test_publication_writes_version_tag_and_commit_to_the_step_output(self):
        with workdir() as root:
            output = root / "output"
            output.write_text("")
            with mock.patch.object(RELEASE, "published", return_value=COMMIT):
                printed = run_main("published", TAG, GITHUB_OUTPUT=str(output))
            self.assertEqual(output.read_text(), f"version=0.1.0\ntag={TAG}\ncommit={COMMIT}\n")
            self.assertIn(COMMIT, printed)


class Arguments(unittest.TestCase):
    def script(self, *argv, **env):
        with tempfile.TemporaryDirectory() as temp:
            return subprocess.run(
                [sys.executable, "-I", str(SCRIPT), *argv],
                cwd=temp,
                capture_output=True,
                text=True,
                timeout=20,
                env={"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", ""), **env},
            )

    def test_missing_environment_is_refused_with_the_script_prefix(self):
        result = self.script("verify-draft", TAG)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("github-release: invalid GITHUB_REPOSITORY"), result.stderr)
        result = self.script("verify-draft", TAG, GITHUB_REPOSITORY=REPOSITORY)
        self.assertTrue(result.stderr.startswith("github-release: invalid GITHUB_RUN_ID"), result.stderr)

    def test_an_unknown_mode_is_refused_before_any_effect(self):
        result = self.script("republish", TAG, GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="123")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice", result.stderr)

    def test_malformed_values_are_refused(self):
        for argv, env, message in [
            (("draft-state", TAG), {"GITHUB_RUN_ID": "0123"}, "invalid GITHUB_RUN_ID"),
            (("draft-state", TAG), {"GITHUB_REPOSITORY": "owner"}, "invalid GITHUB_REPOSITORY"),
            (("assemble", "artifacts", TAG), {"GITHUB_SHA": "abc"}, "invalid GITHUB_SHA"),
        ]:
            with self.subTest(argv=argv, env=env), self.assertRaisesRegex(ValueError, message):
                run_main(*argv, **env)
        for argv, message in [
            (("draft-state", "v1.0.0"), "invalid prerelease tag"),
            (("draft-state", TAG, "extra"), "unrecognized arguments"),
            (("published", TAG, "extra"), "unrecognized arguments"),
            (("assemble", TAG), "required: tag"),
        ]:
            with self.subTest(argv=argv):
                result = self.script(*argv, GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="123", GITHUB_SHA=COMMIT)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)


@needs_jq
class Workflow(unittest.TestCase):
    RELEASE = jobs(".github/workflows/release.yml")["release"]
    GH = """#!/usr/bin/env python3
import json, os, sys
with open('calls', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['release', 'upload']:
    sys.exit(int(os.environ['UPLOAD_STATUS']))
"""
    VERIFIER = """import os, sys
from pathlib import Path
if sys.argv[1] == 'draft-state':
    print(os.environ['DRAFT_STATE'])
else:
    Path('verification-attempted').touch()
    sys.exit(int(os.environ['VERIFY_STATUS']))
"""

    def fill(self, draft_exists, *, upload=0, verify=0):
        script = run(self.RELEASE, "Fill the draft release, then make it public")
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "artifacts").mkdir()
            stub(directory, "gh", self.GH)
            stub(directory, "ci/github_release.py", self.VERIFIER)
            state = json.dumps({"draft_exists": draft_exists, "missing_assets": ["a", "b"]})
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c", script],
                cwd=directory,
                env=dict(
                    os.environ,
                    PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                    RELEASE_TAG=TAG,
                    GITHUB_REPOSITORY=REPOSITORY,
                    DRAFT_STATE=state,
                    UPLOAD_STATUS=str(upload),
                    VERIFY_STATUS=str(verify),
                ),
                capture_output=True,
                text=True,
                timeout=20,
            )
            calls = (directory / "calls").read_text().splitlines() if (directory / "calls").exists() else []
            return result, [json.loads(line) for line in calls], (directory / "verification-attempted").exists()

    def test_a_new_draft_is_created_filled_in_order_and_then_made_public(self):
        result, calls, verified = self.fill(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[:2] for call in calls],
            [["release", "create"], ["release", "upload"], ["release", "upload"], ["release", "edit"]],
        )
        for flag in ("--draft", "--prerelease", "--latest=false", "--verify-tag"):
            self.assertIn(flag, calls[0])
        self.assertIn(f"glowcap {TAG} alpha", calls[0])
        self.assertEqual([call[3] for call in calls[1:3]], ["release-assets/a", "release-assets/b"])
        for flag in ("--draft=false", "--prerelease", "--latest=false"):
            self.assertIn(flag, calls[3])
        self.assertTrue(verified)

    def test_an_existing_draft_is_resumed_without_creating_another(self):
        result, calls, _ = self.fill(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[:2] for call in calls], [["release", "upload"], ["release", "upload"], ["release", "edit"]]
        )

    def test_a_failed_upload_or_verification_never_publishes_the_draft(self):
        for upload, verify in ((37, 0), (0, 41)):
            with self.subTest(upload=upload, verify=verify):
                result, calls, verified = self.fill(False, upload=upload, verify=verify)
                self.assertEqual(result.returncode, upload or verify, result.stderr)
                self.assertNotIn(["release", "edit"], [call[:2] for call in calls])
                self.assertEqual(verified, not upload)

    def test_the_release_job_and_publish_contract_call_the_script_modes(self):
        self.assertEqual(
            run(jobs(".github/workflows/publish.yml")["contract"], "Verify the public release behind the tag"),
            'python3 ci/github_release.py published "$RELEASE_TAG"',
        )
        for mode in (
            'assemble artifacts "$RELEASE_TAG"',
            'bundles "$RELEASE_TAG"',
            'draft-state "$RELEASE_TAG"',
            'verify-draft "$RELEASE_TAG"',
        ):
            self.assertTrue(
                any(f"python3 ci/github_release.py {mode}" in found.get("run", "") for found in self.RELEASE["steps"])
            )
        script = run(self.RELEASE, "Fill the draft release, then make it public")
        self.assertIn('gh release create "$RELEASE_TAG"', script)
        self.assertNotIn("GITHUB_REF_NAME", script)


if __name__ == "__main__":
    unittest.main()
