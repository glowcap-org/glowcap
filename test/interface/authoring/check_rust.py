"""interface-conversation-check: compile isolated generated Rust library modules.

Argument: the build-owned authoring checker. The scratch library reuses the
existing conversation crate's package, dependencies, lock, and Cargo caches.
Each checker child has the ordinary 30-second deadline. Cargo compilation uses
the build tool's enclosing allowance, with offline/locked dependency resolution.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROOF = ROOT / "test/interface/rust"
CASES = [
    ("text", "Reader", "read"),
    ("capability", "Source", "open"),
    ("reference_input", "Source", "accept"),
    ("promise_input", "Source", "acceptPending"),
    ("optional", "Source", "optional"),
    ("value", "Source", "value"),
    ("tell_zero", "Notices", "zero"),
    ("tell_text", "Notices", "text"),
    ("tell_undefined", "Notices", "absent"),
    ("tell_value", "Notices", "changed"),
    ("tell_optional", "Notices", "optional"),
    ("receipt", "Prepared", "accept"),
]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_rust.py CHECKER")
    checker = str(Path(sys.argv[1]).resolve())
    metadata = json.loads(
        subprocess.check_output(
            [
                "cargo",
                "metadata",
                "--format-version",
                "1",
                "--no-deps",
                "--locked",
                "--offline",
                "--manifest-path",
                str(PROOF / "Cargo.toml"),
            ],
            cwd=ROOT,
        )
    )
    manifest = (PROOF / "Cargo.toml").read_text()
    parsed = tomllib.loads(manifest)
    assert "lib" not in parsed, "conversation crate already has a library target"
    manifest = re.sub(r"(?ms)^\[\[bin\]\]\n.*?(?=^\[|\Z)", "", manifest)
    for dependency in parsed["dependencies"].values():
        if isinstance(dependency, dict) and "path" in dependency:
            path = dependency["path"]
            manifest = manifest.replace(json.dumps(path), json.dumps(str((PROOF / path).resolve())))
    manifest += '\n[lib]\npath = "lib.rs"\n'
    scratch_root = ROOT / "zig-out"
    scratch_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="interface-rust-minimal-", dir=scratch_root) as scratch:
        directory = Path(scratch)
        (directory / "Cargo.toml").write_text(manifest)
        shutil.copyfile(PROOF / "Cargo.lock", directory / "Cargo.lock")
        for module, receiver, selector in CASES:
            subprocess.run(
                [
                    checker,
                    "text",
                    str(Path(__file__).with_name("rust_helpers.interface")),
                    "rust",
                    f"minimal.{receiver}",
                    selector,
                    "invoke",
                    str(directory / f"{module}.rs"),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
        (directory / "lib.rs").write_text(
            "#![deny(warnings)]\n" + "".join(f"pub mod {module};\n" for module, _, _ in CASES)
        )
        environment = os.environ.copy()
        environment["CARGO_TARGET_DIR"] = metadata["target_directory"]
        environment["CARGO_BUILD_BUILD_DIR"] = metadata["build_directory"]
        subprocess.run(
            [
                "cargo",
                "clippy",
                "--quiet",
                "--locked",
                "--offline",
                "--manifest-path",
                str(directory / "Cargo.toml"),
                "--lib",
                "--",
                "-D",
                "warnings",
            ],
            cwd=ROOT,
            env=environment,
            check=True,
        )


if __name__ == "__main__":
    main()
