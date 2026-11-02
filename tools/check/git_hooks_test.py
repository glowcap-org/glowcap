"""Exercise the pre-commit hook through `git commit` for infrastructure-check.

Each case commits in a temporary repository whose `core.hooksPath` is this
checkout's `.agents/hooks`. The formatters run directly from PATH, so the
direct path is real. The missing-formatter case runs the hook with a PATH that
lacks them and a stub front that records its arguments.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parents[2]
HOOKS = CHECKOUT / ".agents/hooks"
GIT = shutil.which("git")

UNFORMATTED_PY = "x   =   {'a':1,\n   'b':2}\n"
FORMATTED_PY = 'x = {"a": 1, "b": 2}\n'
UNFORMATTED_TS = 'export const a = {"k":1}\n'
FORMATTED_TS = "export const a = { 'k': 1 };\n"


needs_formatters = unittest.skipUnless(shutil.which("ruff") and shutil.which("deno"), "ruff and deno are not on PATH")


def committed(repo, path):
    return subprocess.run(["git", "show", f"HEAD:{path}"], cwd=repo, text=True, capture_output=True, check=True).stdout


class PreCommitTests(unittest.TestCase):
    def test_hook_is_executable(self):
        # Git skips a hook without the executable bit and says only a hint.
        self.assertTrue(os.access(HOOKS / "pre-commit", os.X_OK))

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="glowcap-git-hooks-")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name) / "home"
        self.home.mkdir()
        self.repo = Path(scratch.name) / "repo"
        self.repo.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Hook Test",
            "GIT_AUTHOR_EMAIL": "hook@example.invalid",
            "GIT_COMMITTER_NAME": "Hook Test",
            "GIT_COMMITTER_EMAIL": "hook@example.invalid",
        }
        self.env.pop("GLOWCAP_HOOK_FRONT", None)
        self.git("init", "-q", "-b", "main")
        self.git("config", "core.hooksPath", str(HOOKS))
        shutil.copy(CHECKOUT / "ruff.toml", self.repo / "ruff.toml")
        (self.repo / "deno.json").write_text('{"fmt":{"singleQuote":true,"semiColons":true}}\n')
        self.write("README.md", "# scratch\n")
        self.commit("start")

    def git(self, *args, env=None):
        return subprocess.run(
            [GIT, *args], cwd=self.repo, env=env or self.env, text=True, capture_output=True, timeout=20
        )

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message, env=None):
        self.git("add", "-A")
        return self.git("commit", "-q", "-m", message, env=env)

    @needs_formatters
    def test_staged_python_and_typescript_are_formatted_in_the_commit(self):
        self.write("tool.py", UNFORMATTED_PY)
        self.write("app.ts", UNFORMATTED_TS)
        result = self.commit("format")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(committed(self.repo, "tool.py"), FORMATTED_PY)
        self.assertEqual(committed(self.repo, "app.ts"), FORMATTED_TS)
        self.assertEqual((self.repo / "tool.py").read_text(), FORMATTED_PY)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    @needs_formatters
    def test_each_deno_scope_formats_with_its_own_config(self):
        self.write("sub/deno.json", '{"fmt":{"useTabs":true,"singleQuote":false}}\n')
        self.write("a.ts", "export function a(){\nreturn 'x';\n}\n")
        self.write("sub/b.mjs", "export function b(){\nreturn 'x';\n}\n")
        result = self.commit("scopes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("  return 'x';", committed(self.repo, "a.ts"))
        self.assertIn('\treturn "x";', committed(self.repo, "sub/b.mjs"))

    @needs_formatters
    def test_files_a_formatter_excludes_stay_as_generated(self):
        self.write("deno.json", '{"fmt":{"singleQuote":true,"exclude":["generated.ts"]}}\n')
        self.write("generated.ts", UNFORMATTED_TS)
        self.write("table_gen.py", UNFORMATTED_PY)
        result = self.commit("generated")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(committed(self.repo, "generated.ts"), UNFORMATTED_TS)
        self.assertEqual(committed(self.repo, "table_gen.py"), UNFORMATTED_PY)

    @needs_formatters
    def test_partially_staged_file_is_refused_and_named(self):
        self.write("tool.py", FORMATTED_PY)
        self.assertEqual(self.commit("tool").returncode, 0)
        before = self.git("rev-parse", "HEAD").stdout
        self.write("tool.py", FORMATTED_PY + "y = 1\n")
        self.git("add", "tool.py")
        self.write("tool.py", FORMATTED_PY + "y = 1\nz   = 2\n")
        result = self.git("commit", "-q", "-m", "partial")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("tool.py", result.stderr)
        self.assertIn("unstaged", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, before)
        self.assertEqual((self.repo / "tool.py").read_text(), FORMATTED_PY + "y = 1\nz   = 2\n")

    @needs_formatters
    def test_unstaged_change_to_an_unrelated_file_does_not_block(self):
        self.write("other.py", FORMATTED_PY)
        self.assertEqual(self.commit("other").returncode, 0)
        self.write("other.py", "scratch   =   1\n")
        self.write("tool.py", UNFORMATTED_PY)
        self.git("add", "tool.py")
        result = self.git("commit", "-q", "-m", "tool")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(committed(self.repo, "tool.py"), FORMATTED_PY)

    @needs_formatters
    def test_python_syntax_error_refuses_the_commit(self):
        before = self.git("rev-parse", "HEAD").stdout
        self.write("broken.py", "def broken(:\n")
        result = self.commit("broken")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("broken.py", result.stderr)
        self.assertIn("formatter rejected", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, before)

    def stub_front(self):
        """A front that records its arguments and succeeds, and a PATH without formatters."""
        front = self.home / "front.sh"
        record = self.home / "front.log"
        front.write_text(f'#!/bin/sh\necho "$@" >> "{record}"\n')
        front.chmod(front.stat().st_mode | stat.S_IXUSR)
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        for tool in ("git", "bash", "env", "dirname", "basename", "sed", "cat"):
            found = shutil.which(tool)
            if found:
                (bin_dir / tool).symlink_to(found)
        env = {**self.env, "PATH": str(bin_dir), "GLOWCAP_HOOK_FRONT": str(front)}
        return env, record

    def test_markdown_only_commit_runs_no_formatter(self):
        env, record = self.stub_front()
        self.write("NOTES.md", "notes   here\n")
        result = self.commit("notes", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(record.exists())
        self.assertEqual(committed(self.repo, "NOTES.md"), "notes   here\n")

    def test_missing_formatter_runs_through_the_front(self):
        env, record = self.stub_front()
        self.write("tool.py", UNFORMATTED_PY)
        result = self.commit("front", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(record.read_text().strip(), "bash .agents/hooks/lib/format.sh tool.py")

    def test_failed_front_refuses_the_commit_and_names_the_escape(self):
        env, _ = self.stub_front()
        Path(env["GLOWCAP_HOOK_FRONT"]).write_text("#!/bin/sh\necho 'no running devcontainer' >&2\nexit 1\n")
        before = self.git("rev-parse", "HEAD").stdout
        self.write("tool.py", UNFORMATTED_PY)
        result = self.commit("front", env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no running devcontainer", result.stderr)
        self.assertIn("git commit --no-verify", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, before)


if __name__ == "__main__":
    unittest.main()
