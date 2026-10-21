#!/usr/bin/env python3
"""Check binding website snippets against their public package surfaces."""

from __future__ import annotations

import argparse
import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site" / "examples"
PLANNED_MARKER = "PLANNED:"

# Line-comment prefix per snippet extension present under site/examples/. A
# planned snippet is excluded from the compile checks below, so it must be
# comment-only: live-looking code no check can fail would mislead.
COMMENT_PREFIXES = {
    ".zig": "//",
    ".ts": "//",
    ".rust": "//",
    ".python": "#",
    ".racket": ";",
}


def example_files(suffix: str) -> list[Path]:
    files = sorted(SITE.glob(f"dial/*.{suffix}"))
    files += sorted(SITE.glob(f"listen/*.{suffix}"))
    files += sorted(SITE.glob(f"onion/*.{suffix}"))
    return [path for path in files if PLANNED_MARKER not in path.read_text()]


def check_planned_snippets_comment_only() -> None:
    failures: list[str] = []
    for path in sorted(SITE.rglob("*")):
        prefix = COMMENT_PREFIXES.get(path.suffix)
        if prefix is None or not path.is_file():
            continue
        text = path.read_text()
        if PLANNED_MARKER not in text:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped and not stripped.startswith(prefix):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: live code in a"
                    f" {PLANNED_MARKER} snippet escapes every compile check:"
                    f" {stripped}"
                )
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)


def check_python() -> None:
    with tempfile.TemporaryDirectory(prefix="glowcap-site-python-") as directory:
        generated: list[str] = []
        for source_path in example_files("python"):
            tree = ast.parse(source_path.read_text(), filename=str(source_path))
            wrapper = ast.AsyncFunctionDef(
                name=f"example_{source_path.parent.name}_{source_path.stem.replace('-', '_')}",
                args=ast.arguments(
                    posonlyargs=[],
                    args=[],
                    kwonlyargs=[],
                    kw_defaults=[],
                    defaults=[],
                ),
                body=tree.body,
                decorator_list=[],
                returns=ast.Constant(value=None),
            )
            module = ast.fix_missing_locations(
                ast.Module(body=[wrapper], type_ignores=[])
            )
            output = (
                Path(directory) / f"{source_path.parent.name}_{source_path.stem}.py"
            )
            output.write_text(ast.unparse(module) + "\n")
            generated.append(str(output))

        environment = os.environ.copy()
        environment["MYPYPATH"] = str(ROOT / "bindings" / "python")
        # The binding implementation has its own mypy gate. This check reports
        # snippet errors while still reading the public inline annotations.
        subprocess.run(
            [
                "uvx",
                "mypy@1.15.0",
                "--ignore-missing-imports",
                "--follow-imports=silent",
                "--cache-dir",
                str(Path(directory) / "mypy-cache"),
                *generated,
            ],
            cwd=ROOT,
            env=environment,
            check=True,
        )


def check_racket() -> None:
    binding = ROOT / "bindings" / "racket"
    with tempfile.TemporaryDirectory(prefix="glowcap-site-racket-") as directory:
        work = Path(directory)
        for module in binding.glob("*.rkt"):
            (work / module.name).symlink_to(module)
        (work / "private").symlink_to(binding / "private", target_is_directory=True)
        generated: list[str] = []
        for source_path in example_files("racket"):
            output = work / f"{source_path.parent.name}-{source_path.stem}.rkt"
            output.write_text("#lang racket/base\n" + source_path.read_text())
            generated.append(str(output))
        compiler = """
(for ([path (in-list (vector->list (current-command-line-arguments)))])
  (parameterize ([read-accept-reader #t])
    (call-with-input-file path
      (lambda (input) (compile (read-syntax path input))))))
"""
        # --no-compiled: the racket-dogfood step runs `racket -y` over the same
        # binding tree and writes its `compiled/` bytecode while this check may
        # be compiling through the symlinks. Refusing bytecode makes this check
        # immune to that race and to stale caches; it always expands source.
        subprocess.run(
            ["racket", "--no-compiled", "-e", compiler, *generated], cwd=work, check=True
        )


def check_rust() -> None:
    with tempfile.TemporaryDirectory(prefix="glowcap-site-rust-") as directory:
        work = Path(directory)
        binding = ROOT / "bindings" / "rust"
        manifest = f"""\
[package]
name = "glowcap-site-rust-examples"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
glowcap = {{ package = "glowcap", path = "{binding.as_posix()}", features = ["async", "iroh", "onion", "relay", "webrtc"] }}
"""
        (work / "Cargo.toml").write_text(manifest)
        source = [
            "#![deny(unused_must_use)]",
            "#![allow(dead_code, unreachable_code, unused_imports, unused_variables)]",
            "",
        ]
        for source_path in example_files("rust"):
            name = f"example_{source_path.parent.name}_{source_path.stem.replace('-', '_')}"
            source.extend(
                [
                    f"async fn {name}() -> glowcap::Result<()> {{",
                    source_path.read_text(),
                    "#[allow(unreachable_code)]",
                    "Ok(())",
                    "}",
                    "",
                ]
            )
        source_dir = work / "src"
        source_dir.mkdir()
        (source_dir / "lib.rs").write_text("\n".join(source))
        environment = os.environ.copy()
        environment["CARGO_TARGET_DIR"] = str(binding / "target")
        subprocess.run(
            ["cargo", "check", "--quiet", "--manifest-path", str(work / "Cargo.toml")],
            cwd=ROOT,
            env=environment,
            check=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("language", choices=("python", "racket", "rust"))
    language = parser.parse_args().language
    check_planned_snippets_comment_only()
    if language == "python":
        check_python()
    elif language == "rust":
        check_rust()
    else:
        check_racket()


if __name__ == "__main__":
    main()
