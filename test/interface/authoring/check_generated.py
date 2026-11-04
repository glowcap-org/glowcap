"""interface-conversation-check: compile generated Rust and TypeScript exports.

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
    ("helper_collision", "Reader", "read", "text"),
    ("module_collision", "Reader", "read", "__glowcap"),
    ("import_collision", "Reader", "read", "Session"),
    ("call_collision", "Reader", "read", "call_0"),
    ("bounded_collision", "Bounded", "text", "text_1_64"),
    ("integer_collision", "Bounded", "signed", "integer_m9223372036854775808_p9223372036854775807"),
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
    ("bounded_text", "Bounded", "text"),
    ("lower_text", "Bounded", "lower"),
    ("wide_text", "Bounded", "wide"),
    ("integer_argument", "Bounded", "integer"),
    ("integer_tell", "Bounded", "index"),
    ("signed_integer", "Bounded", "signed"),
    ("bounded_optional", "Bounded", "optional"),
]
SCALARS = [
    (f"scalar_{kind}_{shape}", "Scalars", f"{kind}_{shape}")
    for kind in ("bool", "bytes", "bounded", "symbol", "float", "error")
    for shape in ("call", "optional", "tell", "optional_tell")
] + [("scalar_wide", "Wide", "bytes")]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_generated.py CHECKER")
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
        for case in CASES + SCALARS:
            module, receiver, selector = case[:3]
            api = case[3] if len(case) == 4 else "invoke"
            subprocess.run(
                [
                    checker,
                    "text",
                    str(Path(__file__).with_name("scalars.interface" if case in SCALARS else "rust_helpers.interface")),
                    "rust",
                    f"{'scalars' if case in SCALARS else 'minimal'}.{receiver}",
                    "--named",
                    selector,
                    api,
                    str(directory / f"{module}.rs"),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
        (directory / "lib.rs").write_text(
            "#![deny(warnings)]\n"
            + "".join(f"pub mod {case[0]};\n" for case in CASES + SCALARS)
            + f'#[path = "{ROOT}/test/interface/generated/names.rs"]\npub mod names;\n'
            + "pub use names::{text, capability, nothing, Session, Ref, call_0, __glowcap, __glowcap_1, text_1_4096, integer_p0_p256};\n"
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
        # Alias exports must remain callable even when local helper/import names match.
        imports = []
        for index, name in enumerate(("text", "capability", "nothing", "Session", "Ref", "call_0", "Observation")):
            output = directory / f"collision{index}.ts"
            subprocess.run(
                [
                    checker,
                    "text",
                    str(Path(__file__).with_name("rust_helpers.interface")),
                    "ts",
                    "minimal.Reader",
                    "--named",
                    "read",
                    name,
                    str(output),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
            imports.append(f'import {{ {name} as call{index} }} from "./collision{index}.ts";\nvoid call{index};\n')
        imports.append(f'import * as names from "{ROOT}/test/interface/generated/names.ts";\n')
        imports.append(
            "void [names.text, names.capability, names.nothing, names.Session, names.Ref, names.call_0, names.__glowcap, names.__glowcap_1, names.Observation];\n"
        )
        for module, receiver, selector in SCALARS:
            output = directory / f"{module}.ts"
            subprocess.run(
                [
                    checker,
                    "text",
                    str(Path(__file__).with_name("scalars.interface")),
                    "ts",
                    f"scalars.{receiver}",
                    "--named",
                    selector,
                    "invoke",
                    str(output),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
            imports.append(f'import {{ invoke as {module} }} from "./{module}.ts";\nvoid {module};\n')
        consumer = directory / "consumer.ts"
        consumer.write_text("".join(imports))
        subprocess.run(
            ["deno", "check", "--config", str(ROOT / "deno.json"), str(consumer)], cwd=ROOT, check=True, timeout=30
        )


if __name__ == "__main__":
    main()
