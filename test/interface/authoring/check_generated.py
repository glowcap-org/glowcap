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

from check_bounds import check_bounds
from check_packed import check_packed

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
    ("receipt_capture", "Prepared", "capture"),
    ("receipt_optional", "Prepared", "optional"),
    ("receipt_scalars", "Prepared", "scalars"),
    ("receipt_data", "Prepared", "data"),
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
IMPORTED = [
    ("imported_list", "tasks.imported.Board", "list"),
    ("imported_poll", "shared.control.Receiver", "poll"),
    ("imported_receive", "shared.control.Receiver", "receive"),
    *[
        (f"imported_{method}", "shared.control.Containers", method)
        for method in ("notices", "nested", "empty_record", "empty_tuple", "positional")
    ],
]
AUTHORED = [
    ("authored_list", "tasks.Board", "list"),
    ("authored_text", "tasks.Task", "text"),
    ("authored_poll", "loam.Receiver", "poll"),
    ("authored_receive", "loam.Receiver", "receive"),
    ("authored_cancel", "loam.Canceller", "cancel"),
    ("authored_move", "tasks.TaskList", "move"),
    ("authored_observe", "loam.Observable", "observe"),
    ("authored_live", "loam.Observable", "observe-live"),
]


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
        for folder, entry, cases in (
            ("imports", "board.interface", IMPORTED),
            ("contracts", "contracts.interface", AUTHORED),
        ):
            for module, receiver, selector in cases:
                source_root = Path(__file__).with_name(folder)
                subprocess.run(
                    [
                        checker,
                        "--root",
                        str(source_root),
                        "text",
                        str(source_root / entry),
                        "rust",
                        receiver,
                        "--named",
                        selector,
                        "invoke",
                        str(directory / f"{module}.rs"),
                    ],
                    cwd=ROOT,
                    check=True,
                    timeout=30,
                )
        for selector in ("list", "limited", "tuple", "zero", "nested"):
            subprocess.run(
                [
                    checker,
                    "syrup",
                    str(ROOT / "test/interface/compounds.syrup"),
                    "rust",
                    "compound.Source",
                    "--named",
                    selector,
                    "invoke",
                    str(directory / f"compound_{selector}.rs"),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
        nested = directory / "compound_nested.rs"
        source = nested.read_text()
        cut = source.rfind("\n}")
        source = (
            source[:cut]
            + r"""
    #[cfg(test)]
    mod reservation_tests {
        use super::*;
        #[test]
        fn element_work_precedes_child_decoding() {
            let value = Argument::List(vec![Argument::List(vec![Argument::Void; 3])]);
            assert!(matches!(compound_0_at(value, &mut DecodeBudget { remaining: 4 }), Err(Error::ResourceLimit)));
        }
    }
"""
            + source[cut:]
        )
        nested.write_text(source)
        # A child test module can call the real emitted private decoder without
        # adding a production hook or constructing a huge transport reply.
        path = directory / "compound_list.rs"
        source = path.read_text()
        cut = source.rfind("\n}")
        source = (
            source[:cut]
            + r"""
    #[cfg(test)]
    mod decoder_tests {
        use super::*;
        #[test]
        fn limits_and_owned_payloads() {
            let text = String::from("moved symbol");
            let pointer = text.as_ptr();
            let result = compound_0(Argument::List(vec![Argument::Symbol(text)])).unwrap();
            assert_eq!(result[0].as_ptr(), pointer);
            assert!(matches!(compound_0_at(Argument::List(vec![Argument::Symbol(String::from("x"))]), &mut DecodeBudget { remaining: 1 }), Err(Error::ResourceLimit)));
        }
    }
"""
            + source[cut:]
        )
        path.write_text(source)
        observation = directory / "compound_observation.rs"
        subprocess.run(
            [
                checker,
                "syrup",
                str(ROOT / "test/interface/contracts.syrup"),
                "rust",
                "loam.Receiver",
                "--named",
                "poll",
                "invoke",
                str(observation),
            ],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        source = observation.read_text()
        cut = source.rfind("\n}")
        source = (
            source[:cut]
            + r"""
    #[cfg(test)]
    mod decoder_tests {
        use super::*;
        #[test]
        fn opaque_value_and_cursor_transfer() {
            let cursor = vec![7; 56];
            let pointer = cursor.as_ptr();
            let opaque = Argument::List(vec![Argument::Void; MAX_REPLY_WORK + 1]);
            let value = Argument::Tagged { tag: String::from("access:observation"), value: vec![Argument::Bytes(cursor), opaque, Argument::Boolean(false), Argument::Boolean(true), Argument::List(vec![])] };
            let result = compound_0_at(value, &mut DecodeBudget { remaining: 6 }).unwrap();
            assert_eq!(result.0.as_ptr(), pointer);
            assert_eq!(result.1.as_list().unwrap().len(), MAX_REPLY_WORK + 1);
        }
    }
"""
            + source[cut:]
        )
        observation.write_text(source)
        opaque = directory / "compound_opaque.rs"
        subprocess.run(
            [
                checker,
                "syrup",
                str(ROOT / "test/interface/scalar_bounds.syrup"),
                "rust",
                "bounds.Mixed",
                "--named",
                "values",
                "invoke",
                str(opaque),
            ],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        source = opaque.read_text()
        cut = source.rfind("\n}")
        source = (
            source[:cut]
            + r"""
    #[cfg(test)]
    mod opaque_list_tests {
        use super::*;
        #[test]
        fn opaque_list_reuses_its_buffer_without_element_work() {
            let values = vec![Argument::Void; MAX_REPLY_WORK + 1];
            let pointer = values.as_ptr();
            let mut budget = DecodeBudget { remaining: 1 };
            let result = compound_0_at(Argument::List(values), &mut budget).unwrap();
            assert_eq!(result.as_ptr(), pointer);
            assert_eq!(result.len(), MAX_REPLY_WORK + 1);
            assert_eq!(budget.remaining, 0);
        }
    }
"""
            + source[cut:]
        )
        opaque.write_text(source)
        (directory / "lib.rs").write_text(
            "#![deny(warnings)]\n"
            + "".join(f"pub mod {module};\n" for module, _, _ in IMPORTED + AUTHORED)
            + "".join(f"pub mod {case[0]};\n" for case in CASES + SCALARS)
            + "".join(
                f"pub mod compound_{name};\n"
                for name in ("list", "limited", "tuple", "zero", "nested", "observation", "opaque")
            )
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
        tests = subprocess.run(
            [
                "cargo",
                "test",
                "--quiet",
                "--locked",
                "--offline",
                "--manifest-path",
                str(directory / "Cargo.toml"),
                "--lib",
            ],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if tests.returncode:
            sys.stderr.write(tests.stdout)
            tests.check_returncode()

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
        compound_ts = []
        for selector in ("list", "limited", "tuple", "zero", "nested", "observation"):
            output = directory / f"compound_{selector}.ts"
            subprocess.run(
                [
                    checker,
                    "syrup",
                    str(
                        ROOT
                        / "test/interface"
                        / ("contracts.syrup" if selector == "observation" else "compounds.syrup")
                    ),
                    "ts",
                    "loam.Receiver" if selector == "observation" else "compound.Source",
                    "--named",
                    "poll" if selector == "observation" else selector,
                    "invoke",
                    str(output),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
            imports.append(
                f'import {{ invoke as compound_{selector} }} from "./compound_{selector}.ts";\nvoid compound_{selector};\n'
            )
            compound_ts.append(output)
        primitive_source = directory / "primitive_compound.syrup"
        primitive_source.write_text(
            "<17'glowcap:interface1+{14\"glowcap.values1+}{1\"R<9'interface{1\"m<6'method[]"
            "<5'tuple[9'undefined6'string4'bool5'bytes6'symbol7'float645'error5'value]>4'call>}>}>"
        )
        primitive_output = directory / "primitive_compound.ts"
        subprocess.run(
            [checker, "syrup", str(primitive_source), "ts", "R", "--named", "m", "invoke", str(primitive_output)],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        primitive_output.write_text(
            primitive_output.read_text()
            + r"""
const values: Argument[] = [null, "text", true, new Uint8Array(), new Sym("symbol"), 1.5, new Error("data"), [new Sym("opaque")]];
if (compound_0(values) !== values) throw new Error("primitive tuple copied");
for (const [field, wrong] of [[0, false], [1, new Sym("text")], [2, 1n], [3, []], [4, "symbol"], [5, 1n], [6, "data"]] satisfies [number, Argument][]) {
    const malformed = values.slice();
    malformed[field] = wrong;
    let refused = false;
    try { compound_0(malformed); }
    catch (error) { refused = error instanceof TypeError; }
    if (!refused) throw new Error("primitive field category accepted");
}
"""
        )
        compound_ts.append(primitive_output)
        imports.append(
            'import { invoke as primitive_compound } from "./primitive_compound.ts";\nvoid primitive_compound;\n'
        )
        # Exercise the actual private helpers with small budgets. These hooks
        # exist only in scratch copies, never in production-generated exports.
        (directory / "compound_list.ts").write_text(
            (directory / "compound_list.ts").read_text()
            + r"""
const symbol = new Sym("same object");
const values = [symbol];
if (compound_0(values) !== values || compound_0(values)[0] !== symbol) throw new Error("list copied");
for (const budget of [0, 1]) {
    let refused = false;
    try { compound_0_at(values, { remaining: budget }); }
    catch (error) { refused = error instanceof ResourceLimit && !(error instanceof TypeError); }
    if (!refused) throw new Error("decoder resource bound accepted");
}
let refused = false;
try { compound_0(new Array(MAX_REPLY_WORK).fill(symbol)); }
catch (error) { refused = error instanceof ResourceLimit; }
if (!refused) throw new Error("full work limit accepted");
"""
        )
        (directory / "compound_nested.ts").write_text(
            (directory / "compound_nested.ts").read_text()
            + r"""
let refused = false;
try { compound_0_at([[null, null, null]], { remaining: 2 }); }
catch (error) { refused = error instanceof ResourceLimit; }
if (!refused) throw new Error("actual schema visits exceeded the work budget");
"""
        )
        (directory / "compound_observation.ts").write_text(
            (directory / "compound_observation.ts").read_text()
            + r"""
const cursor = new Uint8Array(56);
const opaque = new Array(MAX_REPLY_WORK + 1).fill(null);
const notices = [new Sym("future"), new Sym("future")];
const original = new Tagged("access:observation", [cursor, opaque, false, true, notices]);
const result = compound_0_at(original, { remaining: 8 });
if (result !== original || result.value[0] !== cursor || result.value[1] !== opaque || result.value[4] !== notices)
    throw new Error("record projection copied or traversed opaque data");
"""
        )
        for index, name in enumerate(("compound_0", "Compound0", "DecodeBudget", "step", "Tagged", "Sym")):
            output = directory / f"compound_collision{index}.ts"
            subprocess.run(
                [
                    checker,
                    "syrup",
                    str(ROOT / "test/interface/compounds.syrup"),
                    "ts",
                    "compound.Source",
                    "--named",
                    "nested",
                    name,
                    str(output),
                ],
                cwd=ROOT,
                check=True,
                timeout=30,
            )
            imports.append(
                f'import {{ {name} as compound_collision{index} }} from "./compound_collision{index}.ts";\nvoid compound_collision{index};\n'
            )
        collision = directory / "refused_collision.ts"
        result = subprocess.run(
            [
                checker,
                "syrup",
                str(ROOT / "test/interface/compounds.syrup"),
                "ts",
                "compound.Source",
                "--named",
                "list",
                "ResourceLimit",
                str(collision),
            ],
            cwd=ROOT,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode != 0 and b"ExportCollision" in result.stderr, "support export collision accepted"
        assert not collision.exists(), "refused generation wrote output"
        compound_ts.extend(check_bounds(checker, directory, imports))
        compound_ts.extend(check_packed(checker, directory, imports))
        consumer = directory / "consumer.ts"
        consumer.write_text("".join(imports))
        subprocess.run(
            ["deno", "check", "--config", str(ROOT / "deno.json"), str(consumer)], cwd=ROOT, check=True, timeout=30
        )
        # Prove the runtime checks detect a real emitted category regression,
        # then restore exactly before the successful decoder runs.
        mutant = directory / "compound_list.ts"
        original = mutant.read_bytes()
        changed = original.replace(b"if (!(value instanceof Sym))", b'if (typeof value !== "string")')
        assert changed != original, "mutation did not change the symbol guard"
        mutant.write_bytes(changed)
        try:
            result = subprocess.run(
                ["deno", "run", "--config", str(ROOT / "deno.json"), str(mutant)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
            )
            assert result.returncode != 0 and b"wrong scalar value" in result.stderr, "category mutation survived"
        finally:
            mutant.write_bytes(original)
        assert mutant.read_bytes() == original, "mutation restore was not exact"
        for module in compound_ts:
            subprocess.run(
                ["deno", "run", "--config", str(ROOT / "deno.json"), str(module)], cwd=ROOT, check=True, timeout=30
            )


if __name__ == "__main__":
    main()
