"""Every stated glowcap version follows `abi_version`, for infrastructure-check.

The archive-resolution contract carries the version the packages download.
Every tracked package manifest states it with the shared license and URLs,
and every tracked lock file records it for each workspace package, so a bump
that misses one fails here instead of in a `--locked` build on one CI lane.
`zig build set-version` is the one command that moves them all.
"""

import json
import re
import subprocess
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class VersionLockstep(unittest.TestCase):
    def test_lock_files_record_the_workspace_version(self):
        """Every tracked lock file states the release version for each workspace package.

        A `--locked` or frozen build refuses a lock that disagrees with its
        manifest, so a bump that misses a lock fails there, late, on one CI
        lane. A workspace entry is a Cargo package without a registry source,
        a uv package that is editable, or a `jsr:@glowcap/*` link.
        """
        version = json.loads((ROOT / "bindings/c-abi-resolve.json").read_text())["abi_version"]
        locks = subprocess.check_output(
            ["git", "ls-files", "*Cargo.lock", "*uv.lock", "*deno.lock"], cwd=ROOT, text=True
        ).splitlines()
        self.assertGreaterEqual(len(locks), 7)
        entries = 0
        for path in locks:
            source = (ROOT / path).read_text()
            with self.subTest(path=path):
                if path.endswith("deno.lock"):
                    stated = re.findall(r'"jsr:@glowcap/[^@"]+@([^"]+)"', source)
                else:
                    stated = [
                        re.search(r'^version = "([^"]+)"', block, re.M)[1]
                        for block in source.split("[[package]]")[1:]
                        if (
                            re.search(r"^source = \{ editable", block, re.M)
                            if path.endswith("uv.lock")
                            else not re.search(r"^source = ", block, re.M)
                        )
                    ]
                entries += len(stated)
                self.assertEqual(set(stated), {version} if stated else set(), path)
        self.assertGreaterEqual(entries, 10, "the lock files record workspace packages")

    def test_package_metadata_matches_the_pre_one_release(self):
        version = json.loads((ROOT / "bindings/c-abi-resolve.json").read_text())["abi_version"]
        self.assertRegex(version, r"^0\.[0-9]+\.[0-9]+$")
        manifest = (ROOT / "build.zig.zon").read_text()
        self.assertIn(f'.version = "{version}"', manifest)
        paths = subprocess.check_output(
            ["git", "ls-files", "*Cargo.toml", "*deno.json", "bindings/python/pyproject.toml"], cwd=ROOT, text=True
        ).splitlines()
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
                workspace = data.get("workspace", {}).get("package")
                packages = [p for p in (data.get("package", data.get("project")), workspace) if p is not None]
                self.assertTrue(packages)
                for package in packages:
                    for field, expected in (("version", version), ("license", "Apache-2.0")):
                        actual = package[field]
                        inherited = package is not workspace and actual == {"workspace": True}
                        self.assertTrue(actual == expected or inherited, (path, field, actual))
                    urls = package.get("urls", package)
                    # Documentation belongs to each package's guide or API reference.
                    # Only the project homepage and repository are shared URLs.
                    for field, expected in (
                        ("repository", "https://github.com/glowcap-org/glowcap"),
                        ("homepage", "https://glowcap.org"),
                    ):
                        actual = {key.lower(): value for key, value in urls.items()}[field]
                        inherited = package is not workspace and actual == {"workspace": True}
                        self.assertTrue(actual == expected or inherited, (path, field, actual))
        for path, section in (("bindings/rust/Cargo.toml", "package"), ("bindings/python/pyproject.toml", "project")):
            self.assertEqual(tomllib.loads((ROOT / path).read_text())[section]["name"], "glowcap")
        distribution = tomllib.loads((ROOT / "bindings/python/pyproject.toml").read_text())["project"]["name"]
        generated = f"bindings/python/{distribution.replace('-', '_')}.egg-info/PKG-INFO"
        ignored = subprocess.run(
            ["git", "check-ignore", "--no-index", "-v", generated], cwd=ROOT, capture_output=True, text=True
        )
        self.assertEqual(ignored.returncode, 0, f"generated packaging metadata must be ignored: {generated}")
        source, _, pattern = ignored.stdout.split("\t", 1)[0].split(":", 2)
        self.assertEqual(source, ".gitignore")
        self.assertFalse(pattern.startswith("!"))
        racket = (ROOT / "bindings/racket/info.rkt").read_text()
        self.assertIn(f'(define version "{version}")', racket)
        self.assertIn("(define license 'Apache-2.0)", racket)


if __name__ == "__main__":
    unittest.main()
