#!/usr/bin/env python3
"""Package checks exercise damaged archives and the exact publication program.

The checksum failure regression was observed against the original file-by-file
publisher. Injected rename failures and signals cover the shared transaction;
SIGKILL, power loss, and concurrent external writers are not simulated.
"""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import glowcap_release as release
import glowcap_release_image as image

# The build supplies the exact production program, not a test reimplementation.
ARCHIVE_SCRIPT = sys.argv.pop(1) if len(sys.argv) > 1 else None


class PackageValidation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rooms-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "glowcap-test.tar.gz"
        self.destination = self.root / "install"
        self.destination.mkdir()

    def archive_with(self, name="libexec/rooms-session", *, link=False, duplicate=False):
        with tarfile.open(self.archive, "w:gz") as archive:
            row = tarfile.TarInfo(name)
            if link:
                row.type, row.linkname = tarfile.SYMTYPE, "/etc/passwd"
            else:
                row.size = 4
            archive.addfile(row, None if link else io.BytesIO(b"test"))
            if duplicate:
                archive.addfile(row, io.BytesIO(b"test"))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.archive.with_name("SHA256SUMS").write_text(f"{digest}  {self.archive.name}\n")

    def test_regular_archive_round_trip(self):
        self.archive_with()
        release.unpack(self.archive, self.destination)
        self.assertEqual((self.destination / "libexec/rooms-session").read_bytes(), b"test")

    def test_corrupted_archive_is_refused_before_extraction(self):
        self.archive_with()
        self.archive.write_bytes(self.archive.read_bytes() + b"corruption")
        with self.assertRaisesRegex(AssertionError, "checksum mismatch"):
            release.unpack(self.archive, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_unsafe_members_are_refused_before_extraction(self):
        for name, options, message in (
            ("../escaped", {}, "unsafe archive path"),
            ("/absolute", {}, "unsafe archive path"),
            ("bin/link", {"link": True}, "link or special file"),
            ("bin/repeated", {"duplicate": True}, "duplicate archive member"),
        ):
            with self.subTest(name=name):
                self.archive_with(name, **options)
                with self.assertRaisesRegex(AssertionError, message):
                    release.unpack(self.archive, self.destination)
                self.assertEqual(list(self.destination.iterdir()), [])

    def test_skills_must_resolve_inside_the_package(self):
        skills = self.destination / "share/glowcap/skills"
        for name in ("rooms-peer", "rooms-team"):
            (skills / name).mkdir(parents=True)
            (skills / name / "SKILL.md").write_text("# Skill\n")
        team = skills / "rooms-team/SKILL.md"
        team.write_text("[peer](../rooms-peer/SKILL.md)\n")
        release.check_skills(self.destination)
        team.write_text("[source](../../../../../source.md)\n")
        with self.assertRaisesRegex(AssertionError, "depends on checkout"):
            release.check_skills(self.destination)
        team.write_text("[missing](missing.md)\n")
        with self.assertRaisesRegex(AssertionError, "broken packaged skill link"):
            release.check_skills(self.destination)

    def test_loader_cannot_fall_back_to_checkout(self):
        for name in ("bin", "libexec", "lib"):
            (self.destination / name).mkdir()
        (self.destination / "libexec/rooms-session").touch()
        with patch.object(release.sys, "platform", "linux"), patch.object(release.subprocess, "check_output") as output:
            output.return_value = "libglowcap_net_transport_iroh.so.0 => /build/zig-out/lib/library.so (0x0)\n"
            with self.assertRaises(AssertionError):
                release.check_loader(self.destination)
            output.return_value = f"libglowcap_net_transport_iroh.so.0 => {self.destination}/lib/library.so (0x0)\n"
            release.check_loader(self.destination)
        with patch.object(release.sys, "platform", "darwin"), patch.object(release.subprocess, "check_output") as output:
            output.return_value = "binary:\n\t/build/library.dylib (compatibility version 1.0.0)\n"
            with self.assertRaises(AssertionError):
                release.check_loader(self.destination)
            output.return_value = "binary:\n\t@rpath/library.dylib (compatibility version 1.0.0)\n"
            with self.assertRaisesRegex(AssertionError, "missing relocatable"):
                release.check_loader(self.destination)
            output.side_effect = [output.return_value, "path @loader_path/../lib (offset 12)"]
            release.check_loader(self.destination)


class ImageInventory(unittest.TestCase):
    FILES = {
        "bin/glowcap": (b"product executable", True),
        "share/glowcap/release.json": (b"{}\n", False),
    }

    def fixture(self, *, contents=None, modes=None, special=None, base_program=None):
        contents = contents or {}
        modes = modes or {}
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w") as archive:
            directory = tarfile.TarInfo("runtime/share/")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            archive.addfile(directory)
            rows = []
            for path, (declared, executable) in sorted(self.FILES.items()):
                rows.append(
                    f"{hashlib.sha256(declared).hexdigest()} "
                    f"{'x' if executable else '-'} {path}\n"
                )
                actual = contents.get(path, declared)
                member = tarfile.TarInfo(f"runtime/{path}")
                member.size = len(actual)
                member.mode = modes.get(path, 0o755 if executable else 0o644)
                archive.addfile(member, io.BytesIO(actual))
            manifest = "".join(rows).encode()
            member = tarfile.TarInfo("runtime/share/glowcap/installation.manifest")
            member.size = len(manifest)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(manifest))
            if special is not None:
                member = tarfile.TarInfo(f"runtime/{special}")
                member.type = tarfile.SYMTYPE
                member.linkname = "/bin/sh"
                archive.addfile(member)
            if base_program is not None:
                member = tarfile.TarInfo(base_program)
                member.size = 1
                member.mode = 0o755
                archive.addfile(member, io.BytesIO(b"x"))
        return output.getvalue()

    def inspect(self, fixture):
        with tarfile.open(fileobj=io.BytesIO(fixture), mode="r") as rootfs:
            image.inspect_tar(rootfs)

    def test_exact_regular_inventory_passes(self):
        self.inspect(self.fixture())

    def test_content_and_mode_must_match_manifest(self):
        with self.assertRaisesRegex(AssertionError, "checksum mismatch"):
            self.inspect(self.fixture(contents={"bin/glowcap": b"damaged"}))
        with self.assertRaisesRegex(AssertionError, "mode mismatch"):
            self.inspect(self.fixture(modes={"bin/glowcap": 0o644}))

    def test_runtime_links_and_base_utilities_are_refused(self):
        with self.assertRaisesRegex(AssertionError, "link or special file"):
            self.inspect(self.fixture(special="bin/shell-link"))
        with self.assertRaisesRegex(AssertionError, "shell or package manager"):
            self.inspect(self.fixture(base_program="bin/sh"))


class ImageContainerOwnership(unittest.TestCase):
    def test_names_are_unique_and_role_scoped(self):
        first = image.container_name("web")
        second = image.container_name("web")
        self.assertRegex(first, r"^glowcap-image-web-[0-9a-f]{24}$")
        self.assertNotEqual(first, second)

    def test_inventory_cleanup_covers_create_timeout(self):
        deadline = image.Deadline()
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(image, "container_name", return_value="owned-inventory"), \
                patch.object(image, "run", side_effect=subprocess.TimeoutExpired("docker", 1)), \
                patch.object(image, "remove_container") as remove:
            with self.assertRaises(subprocess.TimeoutExpired):
                image.inspect_runtime_inventory(deadline, "image", Path(temporary))
        remove.assert_called_once_with("owned-inventory", False)

    def test_service_cleanup_covers_run_timeout(self):
        for proof, role in (
            (image.check_web_and_directory, "web"),
            (image.check_session, "session"),
        ):
            with self.subTest(role=role), \
                    patch.object(image, "container_name", return_value=f"owned-{role}"), \
                    patch.object(image, "run", side_effect=subprocess.TimeoutExpired("docker", 1)), \
                    patch.object(image, "cleanup_run", return_value=subprocess.CompletedProcess(
                        (), 0, "", ""
                    )), \
                    patch.object(image.sys, "stderr", io.StringIO()), \
                    patch.object(image, "stop") as stop:
                with self.assertRaises(subprocess.TimeoutExpired):
                    proof(image.Deadline(), "image")
            stop.assert_called_once_with(f"owned-{role}", False)


class ArchivePublication(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(ARCHIVE_SCRIPT, "run through zig build glowcap-package-test")
        temporary = tempfile.TemporaryDirectory(prefix="glowcap-publish-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source tree"
        self.output = self.root / "release output"
        self.source.mkdir()
        for directory in ("bin", "lib", "libexec", "include", "share"):
            (self.source / directory).mkdir()
        for name in ("README.md", "PROVENANCE.md", "LICENSE-APACHE", "LICENSE-THIRD-PARTY"):
            (self.source / name).write_text("first generation")
        self.assertEqual(self.publish().returncode, 0)
        self.previous = self.snapshot()
        (self.source / "README.md").write_text("second generation")

    def publish(self, injection=""):
        return subprocess.run(["sh", "-ec", injection + "\n" + ARCHIVE_SCRIPT, "archive-test",
                               str(self.output), str(self.source), "glowcap-test.tar.gz"],
                              cwd=self.root, env={**os.environ, "TAR_OPTIONS": ""},
                              capture_output=True, text=True, timeout=5)

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.output.iterdir()}

    def test_checksum_failure_preserves_the_previous_generation(self):
        result = self.publish("sha256sum() { return 81; }; shasum() { return 81; }")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), self.previous)

    def test_success_publishes_archive_and_checksums_together(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        current = self.snapshot()
        self.assertNotEqual(current, self.previous)
        destination = self.root / "extracted"
        destination.mkdir()
        release.unpack(self.output / "glowcap-test.tar.gz", destination)
        self.assertEqual((destination / "README.md").read_text(), "second generation")
        self.assertEqual(list(self.root.glob(".glowcap-stage.*")), [])

    def test_rename_failure_and_signals_restore_the_previous_generation(self):
        for action in ("return 82", "kill -HUP $$", "kill -INT $$", "kill -TERM $$"):
            with self.subTest(action=action):
                result = self.publish('mv() { if [ "$1" = "$stage/tree" ]; then ' + action +
                                      '; else command mv "$@"; fi; }')
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.snapshot(), self.previous)
                self.assertEqual(list(self.root.glob(".glowcap-stage.*")), [])

    def test_failed_rollback_keeps_the_recoverable_previous_generation(self):
        result = self.publish('mv() { case "$1" in "$stage/tree"|"$stage/previous") return 83;; '
                              '*) command mv "$@";; esac; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previous generation preserved at", result.stderr)
        stages = list(self.root.glob(".glowcap-stage.*"))
        self.assertEqual(len(stages), 1)
        recovered = {p.name: p.read_bytes() for p in (stages[0] / "previous").iterdir()}
        self.assertEqual(recovered, self.previous)

    def test_unowned_output_and_symlink_are_preserved(self):
        held = self.output.with_name("previous output")
        self.output.rename(held)
        self.output.mkdir()
        (self.output / "user-file").write_text("keep")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), {"user-file": b"keep"})
        (self.output / "user-file").unlink()
        self.output.rmdir()
        for target in (held, self.root / "absent"):
            with self.subTest(target=target):
                self.output.symlink_to(target, target_is_directory=True)
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing to replace symlink", result.stderr)
                self.assertTrue(self.output.is_symlink())
                self.output.unlink()
        self.assertEqual({p.name: p.read_bytes() for p in held.iterdir()}, self.previous)


if __name__ == "__main__":
    unittest.main()
