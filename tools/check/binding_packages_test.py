"""The binding package rehearsal refuses Zig build tooling, for infrastructure-check.

`binding_packages.py` checks each language archive's member names. JSR
publishes the TypeScript packages from the tracked tree under `bindings/ts`,
so that check reads `git ls-files` there before any `deno publish` runs.
"""

import importlib.util
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("binding_packages", ROOT / "tools/check/binding_packages.py")
PACKAGES = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PACKAGES)


def tracked(*names):
    return "".join(f"{name}\0" for name in names)


class TypeScriptPackages(unittest.TestCase):
    def test_typescript_sources_pass_without_zig_tooling(self):
        listing = tracked("bindings/ts/runtime/mod.ts", "bindings/ts/runtime/deno.json")
        with mock.patch.object(PACKAGES.subprocess, "check_output", return_value=listing) as git:
            PACKAGES.verify_typescript_files()
        self.assertEqual(git.call_args.args[0], ["git", "ls-files", "-z", "--", "bindings/ts"])

    def test_typescript_package_refuses_zig_tooling_before_publishing(self):
        listing = tracked("bindings/ts/runtime/mod.ts", "bindings/ts/runtime/policy.zig")
        with (
            mock.patch.object(PACKAGES.subprocess, "check_output", return_value=listing),
            mock.patch.object(PACKAGES, "run") as run,
            self.assertRaisesRegex(ValueError, "Zig build tooling: bindings/ts/runtime/policy.zig"),
        ):
            PACKAGES.typescript_package(Path("unused"), {}, None)
        run.assert_not_called()

    def test_an_empty_listing_is_no_evidence(self):
        with (
            mock.patch.object(PACKAGES.subprocess, "check_output", return_value=""),
            self.assertRaisesRegex(AssertionError, "no tracked files"),
        ):
            PACKAGES.verify_typescript_files()

    def test_the_real_typescript_tree_has_no_zig_tooling(self):
        PACKAGES.verify_typescript_files()


if __name__ == "__main__":
    unittest.main()
