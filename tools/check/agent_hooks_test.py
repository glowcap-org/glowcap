"""Exercise the edit hook through its JSON interface for infrastructure-check.

Uses the installed formatters in temporary workspaces, including a non-root
caller. The Rust isolation case was validated against recursive rustfmt: it
fails when the hook changes a child module alongside the requested file.
"""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[2] / ".agents/hooks/format-edited-file.sh"


class EditHookTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="glowcap-agent-hooks-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.caller = self.root / "caller"
        self.caller.mkdir()

    def run_hook(self, payload):
        result = subprocess.run(
            ["bash", str(HOOK)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            cwd=self.caller,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_claude_formats_zig_from_another_directory(self):
        target = self.root / "name with spaces.zig"
        original = "pub fn main() void{}\n"
        target.write_text(original)
        self.run_hook({"tool_input": {"file_path": str(target)}})
        self.assertNotEqual(target.read_text(), original)
        self.assertEqual(target.read_text(), "pub fn main() void {}\n")

    def test_cursor_formats_only_the_requested_rust_file(self):
        target = self.root / "lib.rs"
        child = self.root / "child.rs"
        original = "mod child;\npub async fn run(){ }\n"
        sibling = "pub fn child(){ }\n"
        target.write_text(original)
        child.write_text(sibling)
        (self.root / "rustfmt.toml").write_text('edition = "2024"\n')
        self.run_hook({"file_path": str(target)})
        self.assertNotEqual(target.read_text(), original)
        self.assertEqual(child.read_text(), sibling)

    def test_typescript_uses_the_nearest_config(self):
        (self.root / "deno.json").write_text('{"fmt":{"useTabs":false}}')
        scope = self.root / "browser"
        scope.mkdir()
        (scope / "deno.json").write_text('{"fmt":{"useTabs":true}}')
        target = scope / "view.tsx"
        target.write_text("export function view(){\nreturn <div/>;\n}\n")
        self.run_hook({"file_path": str(target)})
        self.assertIn("\treturn <div />;", target.read_text())

    def test_unfinished_edit_reports_failure_without_blocking(self):
        target = self.root / "unfinished.zig"
        original = "pub fn main(\n"
        target.write_text(original)
        result = self.run_hook({"file_path": str(target)})
        self.assertTrue(result.stderr)
        self.assertEqual(target.read_text(), original)

    def test_absent_path_and_unsupported_file_are_noops(self):
        target = self.root / "notes.txt"
        target.write_text("leave  this alone\n")
        for payload in ({}, {"file_path": str(self.root / "absent.zig")},
                        {"file_path": str(target)}):
            self.run_hook(payload)
        self.assertEqual(target.read_text(), "leave  this alone\n")


if __name__ == "__main__":
    unittest.main()
