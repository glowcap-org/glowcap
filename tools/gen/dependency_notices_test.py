"""Release notice contracts over fixture package graphs and original text files."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import dependency_notices as notices
from notices import graphs


class NoticeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.package = {
            "ecosystem": "cargo",
            "name": "fixture",
            "version": "1.0.0",
            "source": "registry+fixture",
            "directory": self.root,
            "license_file": None,
        }

    def render(self, supplements=None):
        return notices.render([self.package], supplements or {}, self.root)

    def test_preserves_original_notices_with_nested_attribution(self):
        (self.root / "LICENSE").write_text("A license\n")
        nested = self.root / "vendor/other"
        nested.mkdir(parents=True)
        (nested / "NOTICE").write_text("A different copyright notice\n")
        output = self.render()
        self.assertIn("--- vendor/other/NOTICE ---\nA different copyright notice\n", output)
        self.assertIn("--- LICENSE ---\nA license\n", output)
        self.assertEqual(output, self.render())

    def test_missing_empty_and_escaping_notices_refuse(self):
        with self.assertRaisesRegex(ValueError, "no license/notice text"):
            self.render()
        (self.root / "NOTICE").write_text("Attribution alone supplies no license terms")
        with self.assertRaisesRegex(ValueError, "no license/notice text"):
            self.render()
        (self.root / "LICENSE").write_text("")
        with self.assertRaisesRegex(ValueError, "empty notice"):
            self.render()
        self.package["license_file"] = "../missing-license"
        with self.assertRaisesRegex(ValueError, "missing or escapes"):
            self.render()

    def test_license_directories_and_explicit_nonstandard_filename(self):
        directory = self.root / "LICENSES"
        directory.mkdir()
        (directory / "MIT.txt").write_text("MIT original text")
        (self.root / "terms.txt").write_text("Declared license file")
        self.package["license_file"] = "terms.txt"
        output = self.render()
        self.assertIn("MIT original text", output)
        self.assertIn("Declared license file", output)

    def test_supplements_are_exact_version_revision_and_digest(self):
        body = b"Upstream root license\n"
        (self.root / "supplement.txt").write_bytes(body)
        (self.root / ".cargo_vcs_info.json").write_text(json.dumps({"git": {"sha1": "revision"}}))
        item = {
            "file": "supplement.txt",
            "path": "LICENSE",
            "url": "https://example.invalid/revision/LICENSE",
            "sha256": hashlib.sha256(body).hexdigest(),
        }
        supplements = {"cargo:fixture@1.0.0": {"revision": "revision", "files": [item]}}
        self.assertIn("Upstream root license", self.render(supplements))
        self.package["version"] = "1.0.1"
        with self.assertRaisesRegex(ValueError, "no license/notice text"):
            self.render(supplements)
        self.package["version"] = "1.0.0"
        supplements["cargo:fixture@1.0.0"]["revision"] = "other"
        with self.assertRaisesRegex(ValueError, "source revision changed"):
            self.render(supplements)
        supplements["cargo:fixture@1.0.0"]["revision"] = "revision"
        (self.root / "supplement.txt").write_bytes(b"Corrupted")
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.render(supplements)

    def test_cargo_uses_selected_target_and_excludes_unselected_metadata(self):
        external = self.root / "registry"
        external.mkdir()
        metadata = {
            "packages": [
                {
                    "name": name,
                    "version": "1.0.0",
                    "source": "registry+fixture",
                    "manifest_path": str(external / name / "Cargo.toml"),
                    "license_file": None,
                }
                for name in ("runtime", "only-tests")
            ]
        }
        with patch.object(graphs, "command", side_effect=[json.dumps(metadata), "runtime v1.0.0\n"]) as command:
            result = list(graphs.cargo_packages(self.root, "Cargo.toml", "product", "wasm32-unknown-unknown"))
        self.assertEqual([p["name"] for p in result], ["runtime"])
        args = command.call_args_list[1].args[0]
        self.assertEqual(args[args.index("--edges") + 1], "normal,build")
        self.assertEqual(args[args.index("--target") + 1], "wasm32-unknown-unknown")
        self.assertEqual(args[args.index("-p") + 1], "product")

    def test_browser_follows_emitted_packages_not_tools_or_types(self):
        assets = self.root / "share/glowcap/rooms"
        assets.mkdir(parents=True)
        (assets / "bundled-packages.json").write_text(json.dumps([{"name": "runtime", "version": "1"}]))
        packages = {
            name: {
                "name": name,
                "version": "1",
                "registryUrl": "https://example.invalid/",
                "localPath": str(self.root / name),
            }
            for name in ("runtime", "bundler", "@types/runtime")
        }
        with patch.object(graphs, "command", return_value=json.dumps({"npmPackages": packages})):
            result = list(graphs.browser_packages(self.root, self.root))
        self.assertEqual([p["name"] for p in result], ["runtime"])
        (assets / "bundled-packages.json").write_text(json.dumps([{"name": "runtime", "version": "0"}]))
        with (
            patch.object(graphs, "command", return_value=json.dumps({"npmPackages": packages})),
            self.assertRaisesRegex(ValueError, "holds runtime@0, which apps/rooms/deno.lock does not resolve"),
        ):
            list(graphs.browser_packages(self.root, self.root))
        (assets / "bundled-packages.json").write_text("[]")
        with self.assertRaisesRegex(ValueError, "no dependency inventory"):
            list(graphs.browser_packages(self.root, self.root))


if __name__ == "__main__":
    unittest.main()
