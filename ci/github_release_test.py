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
import zipfile
from pathlib import Path
from unittest import mock

import github_release as RELEASE
from workflows import ROOT, jobs, run, stub

SCRIPT = ROOT / "ci/github_release.py"
REPOSITORY = "owner/project"
COMMIT = "a" * 40
TAG = "v0.1.0"
MARKER = RELEASE.run_marker("123")


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
    if target in RELEASE.PORTABLE:
        return "WebAssembly"
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
    entries = RELEASE.PORTABLE[target][2] if target in RELEASE.PORTABLE else RELEASE.ENTRY_POINTS[role]
    for name in (*RELEASE.COMMON_FILES, *entries):
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
    directory = root / "archives-portable" / "portable-release"
    directory.mkdir(parents=True)
    sums = []
    for target, (role, prefix, _) in RELEASE.PORTABLE.items():
        name = f"{prefix}-{TAG}-{target}.tar.gz"
        data = archive_bytes(role, target)
        (directory / name).write_bytes(data)
        sums.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(sums))
    with zipfile.ZipFile(root / f"glowcap-racket-{TAG}.zip", "w") as package:
        package.writestr("glowcap/private/c-abi-resolve.json", json.dumps({"abi_version": TAG[1:]}))
        for name in ("info.rkt", "glowcap.rkt", "LICENSE-APACHE", "README.md"):
            package.writestr(f"glowcap/{name}", "content")


def write_assets(names, content=b"approved"):
    Path("release-assets").mkdir(exist_ok=True)
    for name in names:
        (Path("release-assets") / name).write_bytes(content if content else name.encode())


class Assemble(unittest.TestCase):
    def test_racket_packaging_reads_only_the_signed_commits_binding_tree(self):
        with workdir() as root:
            binding = root / "bindings/racket"
            binding.mkdir(parents=True)
            (binding / "info.rkt").write_text("committed binding")
            (root / "LICENSE-APACHE").write_text("license text")
            (binding / "LICENSE-APACHE").symlink_to("../../LICENSE-APACHE")
            (root / "unrelated-link").symlink_to("../outside")
            subprocess.run(["git", "init", "-q"], check=True)
            subprocess.run(["git", "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.org",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
                env=dict(os.environ, GIT_AUTHOR_DATE="2000-01-02T03:04:06Z", GIT_COMMITTER_DATE="2000-01-02T03:04:06Z"),
            )
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            (binding / "info.rkt").write_text("uncommitted change")
            (root / "artifacts").mkdir()
            (root / "ci").mkdir()
            for program in (SCRIPT, SCRIPT.with_name("release_version.py")):
                shutil.copyfile(program, root / "ci" / program.name)
            script = run(jobs(".github/workflows/release.yml")["release"], "Package the Racket binding")
            subprocess.run(
                ["bash", "-e", "-c", script],
                check=True,
                timeout=10,
                env=dict(
                    os.environ, GITHUB_SHA=commit, RELEASE_TAG=TAG, GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="123"
                ),
            )
            with zipfile.ZipFile(root / "artifacts" / f"glowcap-racket-{TAG}.zip") as archive:
                self.assertEqual(archive.namelist(), ["glowcap/LICENSE-APACHE", "glowcap/info.rkt"])
                self.assertEqual(archive.read("glowcap/LICENSE-APACHE"), b"license text")
                self.assertEqual(archive.read("glowcap/info.rkt"), b"committed binding")
                self.assertEqual(archive.getinfo("glowcap/info.rkt").date_time, (2000, 1, 2, 3, 4, 6))

    def test_racket_archive_must_exist_and_match_the_release(self):
        for problem in ("missing", "wrong version", "missing entry", "corrupt"):
            with self.subTest(problem), workdir() as root:
                build_artifacts(root / "artifacts")
                archive = root / "artifacts" / f"glowcap-racket-{TAG}.zip"
                if problem == "missing":
                    archive.unlink()
                elif problem == "corrupt":
                    archive.write_bytes(b"not a ZIP")
                else:
                    with zipfile.ZipFile(archive, "w") as package:
                        version = "9.9.9" if problem == "wrong version" else TAG[1:]
                        package.writestr("glowcap/private/c-abi-resolve.json", json.dumps({"abi_version": version}))
                with self.assertRaises((ValueError, OSError, KeyError, zipfile.BadZipFile)):
                    run_main("assemble", "artifacts", TAG)

    def test_portable_archives_require_their_version_and_every_entry_point(self):
        for target, (role, prefix, entries) in RELEASE.PORTABLE.items():
            for problem in ({"omit": entries[0]}, {"meta": {"version": "9.9.9"}}, {"meta": {"dirty": True}}):
                with self.subTest(target=target, problem=problem), workdir() as root:
                    archive = root / f"{prefix}-{TAG}-{target}.tar.gz"
                    archive.write_bytes(archive_bytes(role, target, **problem))
                    with self.assertRaises((ValueError, KeyError)):
                        RELEASE.archive_facts(archive, TAG, COMMIT)

    def test_archives_are_copied_with_one_checksum_file_and_the_release_facts(self):
        with workdir() as root:
            build_artifacts(root / "artifacts")
            output = run_main("assemble", "artifacts", TAG)
            self.assertEqual(output, f"Assembled 10 archives for {TAG} at {COMMIT}\n")
            archives = sorted(path.name for path in Path("release-assets").glob("*.tar.gz"))
            self.assertEqual(len(archives), 10)
            racket = f"glowcap-racket-{TAG}.zip"
            packaged = sorted([*archives, racket, racket + ".CHECKSUM"])
            self.assertEqual(
                sorted(path.name for path in Path("release-assets").iterdir()), sorted([*packaged, "SHA256SUMS"])
            )
            self.assertEqual(
                Path("release-assets", racket + ".CHECKSUM").read_text(),
                hashlib.sha1(Path("release-assets", racket).read_bytes()).hexdigest(),
            )
            sums = Path("release-assets/SHA256SUMS").read_text().splitlines()
            self.assertEqual(
                sums,
                [
                    f"{hashlib.sha256((Path('release-assets') / name).read_bytes()).hexdigest()}  {name}"
                    for name in packaged
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
                self.assertIn(fact["role"], ("product", "sdk", "web", "wasm-libraries"))
                self.assertEqual(fact["minimum_runtime"], minimum_runtime(fact["target"]))
            self.assertEqual(
                {(fact["target"], fact["role"]) for fact in facts["archives"]},
                {(target, role) for target in RELEASE.TARGETS for role in ("product", "sdk")}
                | {(target, role) for target, (role, _, _) in RELEASE.PORTABLE.items()},
            )

    def test_every_disagreement_between_archive_and_release_is_refused(self):
        linux = "x86_64-linux"
        cases = {
            "digest mismatch": ({("sdk", linux): {"digest": "0" * 64}}, "packaged checksum mismatch"),
            "missing archive": ({("product", linux): {"missing": True}}, "packaged checksum mismatch"),
            "missing runner": ({("product", linux): {"absent": True}}, "exactly the expected"),
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
            self.assertEqual(len(calls), 13)
            for call in calls:
                self.assertEqual(call[3:], ["--repo", REPOSITORY, "--predicate-type", RELEASE.PROVENANCE])

    def test_preparation_keeps_every_available_attestation(self):
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

    def state(self, answer, *, complete=False):
        def lookup(*args, **kwargs):
            if isinstance(answer, Exception):
                raise answer
            return answer

        with mock.patch.object(RELEASE, "api", side_effect=lookup):
            if complete:
                return RELEASE.draft_state(REPOSITORY, TAG, "123", complete=True)
            return RELEASE.draft_state(REPOSITORY, TAG, "123", allow_published=True)

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
            "published": ([[self.release(draft=False)]], False, 0),
            "partial": ([[partial]], True, 1),
        }
        refused = {
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
                    state = self.state(answer)
                    self.assertEqual(state["draft_exists"], exists)
                    self.assertEqual(len(state["missing_assets"]), missing)
                    self.assertEqual(state["missing_assets"], sorted(state["missing_assets"]))
            for label, release in refused.items():
                with self.subTest(label), self.assertRaises(ValueError):
                    self.state([[release]])
            with self.subTest("two releases for the tag"), self.assertRaisesRegex(ValueError, "multiple releases"):
                self.state([[self.release(), self.release()]])
            with self.subTest("releases of other tags are ignored"):
                state = self.state([[self.release(tag_name="v0.2.0", draft=False)]])
                self.assertEqual(state["draft_exists"], False)
            with self.subTest("network error"), self.assertRaises(subprocess.SubprocessError):
                self.state(subprocess.CalledProcessError(1, ["gh", "api"]))

    def test_the_complete_check_requires_the_whole_draft(self):
        partial = self.release()
        partial["assets"].pop()
        with workdir():
            write_assets(self.NAMES)
            self.assertEqual(self.state([[self.release()]], complete=True)["missing_assets"], [])
            for label, answer in (
                ("no draft", [[]]),
                ("partial", [[partial]]),
                ("published", [[self.release(draft=False)]]),
            ):
                with self.subTest(label), self.assertRaises(ValueError):
                    self.state(answer, complete=True)

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
        cases: dict[str, tuple[dict[str, object], subprocess.CalledProcessError | None]] = {
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
                [sys.executable, "-E", "-s", str(SCRIPT), *argv],
                cwd=temp,
                capture_output=True,
                text=True,
                timeout=20,
                env={"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", ""), **env},
            )

    def test_missing_environment_is_refused_with_the_script_prefix(self):
        result = self.script("publish-draft", TAG)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("github-release: invalid GITHUB_REPOSITORY"), result.stderr)
        result = self.script("publish-draft", TAG, GITHUB_REPOSITORY=REPOSITORY)
        self.assertTrue(result.stderr.startswith("github-release: invalid GITHUB_RUN_ID"), result.stderr)

    def test_an_unknown_mode_is_refused_before_any_effect(self):
        result = self.script("republish", TAG, GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="123")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice", result.stderr)

    def test_malformed_values_are_refused(self):
        for argv, env, message in [
            (("publish-draft", TAG), {"GITHUB_RUN_ID": "0123"}, "invalid GITHUB_RUN_ID"),
            (("publish-draft", TAG), {"GITHUB_REPOSITORY": "owner"}, "invalid GITHUB_REPOSITORY"),
            (("assemble", "artifacts", TAG), {"GITHUB_SHA": "abc"}, "invalid GITHUB_SHA"),
        ]:
            with self.subTest(argv=argv, env=env), self.assertRaisesRegex(ValueError, message):
                run_main(*argv, **env)
        for argv, message in [
            (("publish-draft", "v1.0.0"), "invalid prerelease tag"),
            (("publish-draft", TAG, "extra"), "unrecognized arguments"),
            (("published", TAG, "extra"), "unrecognized arguments"),
            (("assemble", TAG), "required: tag"),
        ]:
            with self.subTest(argv=argv):
                result = self.script(*argv, GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="123", GITHUB_SHA=COMMIT)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)


class BindingPackages(unittest.TestCase):
    def test_language_archives_refuse_zig_tooling(self):
        RELEASE.verify_binding_files(["glowcap/src/lib.rs", "glowcap/main.rkt", "glowcap/lib/libglowcap.so"])
        for name in ("build.zig", "build.zig.zon", "bin/zig", "bin/zig.exe", "lib/zig/std.zig"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Zig build tooling"):
                RELEASE.verify_binding_files([f"glowcap/{name}"])

    def test_release_racket_archive_refuses_build_sources(self):
        source = io.BytesIO()
        with tarfile.open(fileobj=source, mode="w") as tree:
            member = tarfile.TarInfo("bindings/racket/policy.zig")
            member.size = 1
            tree.addfile(member, io.BytesIO(b"x"))
        with workdir(), mock.patch.object(RELEASE.subprocess, "check_output", return_value=source.getvalue()):
            with self.assertRaisesRegex(ValueError, "Zig build tooling"):
                RELEASE.racket_package(TAG, COMMIT)
            self.assertFalse(Path("artifacts/glowcap-racket-v0.1.0.zip").exists())


if __name__ == "__main__":
    unittest.main()
