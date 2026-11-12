#!/usr/bin/env python3
"""Check binding website snippets against their public package surfaces."""

from __future__ import annotations

import argparse
import ast
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site" / "examples"
# Each language check runs under its build step's 30-second deadline, so the
# compiler it starts stops first and the failure names that compiler.
COMPILER_SECONDS = 25


def example_files(suffix: str) -> list[Path]:
    files = sorted(SITE.glob(f"dial/*.{suffix}"))
    files += sorted(SITE.glob(f"listen/*.{suffix}"))
    files += sorted(SITE.glob(f"onion/*.{suffix}"))
    return files


def check_python() -> None:
    with tempfile.TemporaryDirectory(prefix="glowcap-site-python-") as directory:
        generated: list[str] = []
        for source_path in example_files("python"):
            tree = ast.parse(source_path.read_text(), filename=str(source_path))
            wrapper = ast.AsyncFunctionDef(
                name=f"example_{source_path.parent.name}_{source_path.stem.replace('-', '_')}",
                args=ast.arguments(posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[], defaults=[]),
                body=tree.body,
                decorator_list=[],
                returns=ast.Constant(value=None),
            )
            module = ast.fix_missing_locations(ast.Module(body=[wrapper], type_ignores=[]))
            output = Path(directory) / f"{source_path.parent.name}_{source_path.stem}.py"
            output.write_text(ast.unparse(module) + "\n")
            generated.append(str(output))

        environment = os.environ.copy()
        environment["MYPYPATH"] = str(ROOT / "bindings" / "python")
        # The installed mypy is the one pinned in .devcontainer/pins.sh, as in
        # the binding's own gate. This check reports snippet errors while still
        # reading the public inline annotations.
        subprocess.run(
            [
                "mypy",
                "--ignore-missing-imports",
                "--follow-imports=silent",
                "--cache-dir",
                str(Path(directory) / "mypy-cache"),
                *generated,
            ],
            cwd=ROOT,
            env=environment,
            check=True,
            timeout=COMPILER_SECONDS,
        )


def check_racket() -> None:
    binding = ROOT / "bindings" / "racket"
    with tempfile.TemporaryDirectory(prefix="glowcap-site-racket-") as directory:
        work = Path(directory)
        # A copy without bytecode: racket-test runs `racket -y` over the
        # same binding tree and writes its `compiled/` while this check runs,
        # and a stale `.zo` could hide a broken source. The copy expands every
        # binding module from source, while Racket's own libraries keep their
        # installed bytecode.
        no_bytecode = shutil.ignore_patterns("compiled")
        collection = work / "glowcap"
        collection.mkdir()
        for module in binding.glob("*.rkt"):
            shutil.copy2(module, collection / module.name)
        shutil.copytree(binding / "private", collection / "private", ignore=no_bytecode)
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
        environment = os.environ.copy()
        environment["PLTCOLLECTS"] = str(work) + os.pathsep + environment.get("PLTCOLLECTS", "")
        subprocess.run(
            ["racket", "-e", compiler, *generated], cwd=work, env=environment, check=True, timeout=COMPILER_SECONDS
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
            timeout=COMPILER_SECONDS,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("language", choices=("python", "racket", "rust"))
    language = parser.parse_args().language
    check = {"python": check_python, "rust": check_rust, "racket": check_racket}[language]
    try:
        check()
    except subprocess.TimeoutExpired as error:
        raise SystemExit(
            f"site-{language}-examples-check: {error.cmd[0]} gave no result in {error.timeout} s"
        ) from None
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"site-{language}-examples-check: {error.cmd[0]} exited {error.returncode}") from None


if __name__ == "__main__":
    main()
