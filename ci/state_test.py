"""ci/state.py, the compiled state a build job hands its test jobs, for infrastructure-check.

Every case runs against a disposable home and checkout. The store sizes and
the free disk a `bound` reads are supplied in process, and a passthrough
stands in for the runner's zstd.
"""

import contextlib
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from workflows import load, on_path, stub

GIB = 1 << 30
GIT_ENV = {"GIT_AUTHOR_DATE": "@1700000000 +0000", "GIT_COMMITTER_DATE": "@1700000000 +0000"}


def module(home, root):
    """The module with its stores under `home` and its checkout at `root`."""
    with mock.patch.dict(os.environ, {"HOME": str(home)}):
        state = load("ci/state.py")
    state.ROOT = Path(root)
    return state


def commit(root, env):
    git = [
        "git",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "user.name=CI fixture",
        "-c",
        "user.email=ci@example.invalid",
        "-C",
        str(root),
    ]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "add", "."], check=True)
    subprocess.run([*git, "commit", "-qm", "fixture"], env=env, check=True)


class StateTest(unittest.TestCase):
    def test_stores_are_bounded_by_size_and_free_disk(self):
        # (stores present, free bytes, limit GiB, bytes per store, dropped)
        cases = [
            (0, 40 * GIB, 12, GIB, False),
            (1, 40 * GIB, 12, GIB, False),
            (7, 40 * GIB, 12, GIB, False),
            (7, 40 * GIB, 2, GIB, True),
            (1, 5 * GIB, 12, GIB, True),
            (7, 40 * GIB, 1, 1 << 20, False),  # Seven MiB must not count as seven GiB.
            (1, 20 * GIB - 1, 12, 1 << 20, True),  # Free disk must not round up.
            (1, 20 * GIB, 1, GIB, False),
        ]  # Exact limits keep the store.
        for count, free, limit, store_bytes, dropped in cases:
            with (
                self.subTest(count=count, free=free, limit=limit, store_bytes=store_bytes),
                tempfile.TemporaryDirectory() as temporary,
            ):
                state = module(temporary, temporary)
                self.assertEqual(len(state.STORES), 7)
                inodes = {}
                for store in state.STORES[:count]:
                    (store / "o").mkdir(parents=True)
                    (store / "o/object").write_text("state\n")
                    inodes[store] = store.stat().st_ino
                output = io.StringIO()
                with (
                    mock.patch.object(state, "size", lambda path: store_bytes),
                    mock.patch.object(state.shutil, "disk_usage", return_value=mock.Mock(free=free)),
                    contextlib.redirect_stdout(output),
                ):
                    self.assertEqual(state.main(["bound", str(limit), "20"]), 0)
                self.assertIn("Restored build state:", output.getvalue())
                self.assertEqual("Dropped it" in output.getvalue(), dropped)
                # A drop keeps each directory, because the container mounts it.
                for store in state.STORES[:count]:
                    self.assertEqual(store.stat().st_ino, inodes[store])
                    self.assertEqual(any(store.iterdir()), not dropped)

    def test_size_counts_the_blocks_a_tree_occupies(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = module(temporary, temporary)
            tree = Path(temporary) / "tree/deep"
            tree.mkdir(parents=True)
            (tree / "file").write_bytes(b"x" * 10_000)
            measured = state.size(Path(temporary) / "tree")
            self.assertGreaterEqual(measured, 10_000)
            self.assertEqual(measured % 512, 0)
            self.assertEqual(state.size(Path(temporary) / "absent"), 0)

    def test_malformed_calls_change_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = module(temporary, temporary)
            for argv in (
                [],
                ["stores", "extra"],
                ["pack"],
                ["unpack", "x"],
                ["bound", "1"],
                ["restore", "dir", "[1]"],
                ["unknown"],
            ):
                with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as refused:
                        state.main(argv)
                    self.assertEqual(refused.exception.code, 2)
            with mock.patch("builtins.print"):
                self.assertEqual(state.main(["pack", f"{temporary}/empty.tar.zst"]), 1, "nothing to pack")
            self.assertFalse(Path(temporary, "empty.tar.zst").exists())

    def test_compiled_state_round_trips_with_its_times(self):
        # A build job packs its stores and zig-out, and a test job unpacks them
        # at the same absolute paths with the times Cargo recorded. Both stamp
        # the checkout to the commit time first.
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, home, binary = base / "checkout", base / "home", base / "bin"
            root.mkdir()
            (root / "tracked.zig").write_text("source\n")
            (root / "absent.zig").write_text("listed in the index, missing from the checkout\n")
            binary.mkdir()
            stub(binary, "zstd", "#!/bin/sh\nexec cat\n")
            environment = on_path(binary, HOME=str(home), **GIT_ENV)
            commit(root, environment)
            (root / "absent.zig").unlink()
            state = module(home, root)
            with mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(state.main(["stamp"]), 0)
                self.assertEqual((root / "tracked.zig").stat().st_mtime, 1700000000)

                stores = state.STORES
                self.assertTrue(all(str(store).startswith(str(home) + "/") for store in stores))
                outputs = [stores[1] / "o/object", root / "zig-out/lib/libglowcap.a"]
                for index, output in enumerate(outputs):
                    output.parent.mkdir(parents=True)
                    output.write_text(f"output {index}\n")
                    os.utime(output, (1700000100 + index, 1700000100 + index))
                # Cargo names a workspace's build directory by a path hash, and
                # the pack listing sizes each of its profiles, an empty one included.
                cargo = state.CARGO_BUILD / "ab/cdef0123456789"
                (cargo / "debug/deps").mkdir(parents=True)
                (cargo / "release").mkdir()
                (cargo / "debug/deps/librooms_product.rlib").write_bytes(b"\0" * 2_097_152)
                archive = base / "state" / "state-1.tar.zst"
                archive.parent.mkdir()
                listing = io.StringIO()
                with contextlib.redirect_stdout(listing):
                    self.assertEqual(state.main(["pack", str(archive)]), 0)
                self.assertRegex(listing.getvalue(), r"\n\d\.\dG\tab/cdef0123456789/debug\n")
                self.assertRegex(listing.getvalue(), r"\n0\.0G\tab/cdef0123456789/release\n")
                shutil.rmtree(home)
                shutil.rmtree(root / "zig-out")
                self.assertEqual(state.main(["restore", str(archive.parent), "[1]", "success"]), 0)
                for index, output in enumerate(outputs):
                    self.assertEqual(output.read_text(), f"output {index}\n")
                    self.assertEqual(output.stat().st_mtime, 1700000100 + index)
                self.assertFalse(archive.exists(), "a restored archive is removed")
                # The passthrough compressor leaves format validation to tar.
                archive.write_bytes(b"\xff" * 1024)
                with self.assertRaises(subprocess.CalledProcessError):
                    state.main(["restore", str(archive.parent), "[1]", "success"])

    def test_a_test_job_finds_every_shard_state_or_fails(self):
        # (build result, archives present, exit, archives unpacked in order)
        cases = [
            ("success", (1, 2), 0, [2, 1]),
            ("success", (2,), 1, []),
            ("success", (1,), 1, []),
            ("failure", (2,), 0, [2]),
            ("failure", (), 0, []),
        ]
        for build, present, status, unpacked in cases:
            with self.subTest(build=build, present=present), tempfile.TemporaryDirectory() as temporary:
                state = module(temporary, temporary)
                directory = Path(temporary) / "state"
                directory.mkdir()
                for shard in present:
                    (directory / f"state-{shard}.tar.zst").write_text("")
                output = io.StringIO()
                with mock.patch.object(state.subprocess, "run") as run, contextlib.redirect_stdout(output):
                    # toJSON renders the shard list over several lines.
                    self.assertEqual(state.main(["restore", str(directory), "[\n  1,\n  2\n]", build]), status)
                self.assertEqual(
                    [call.args[0][-1] for call in run.call_args_list],
                    [directory / f"state-{shard}.tar.zst" for shard in unpacked],
                )
                for shard in {1, 2} - set(present):
                    kind = "error" if build == "success" else "warning"
                    self.assertIn(f"::{kind}::Shard {shard}", output.getvalue())


if __name__ == "__main__":
    unittest.main()
