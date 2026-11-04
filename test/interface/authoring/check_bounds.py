"""Extend interface-conversation-check with isolated TS bound projections.

Called by check_generated.py with its compiled checker, scratch directory, and
consumer imports. Every child has a 30-second deadline. Scratch hooks exercise
the real emitted private helpers and are never committed generated API.
"""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "test/interface/scalar_bounds.syrup"


def check_bounds(checker, directory, imports):
    for receiver, variants in (
        ("Integer", ("bare", "empty", "lower", "upper", "signed", "narrow", "alias")),
        ("Text", ("bare", "empty", "lower", "upper", "zero", "bounded", "alias")),
    ):
        for variant in variants:
            for shape in ("call", "optional", "tell", "optional_tell"):
                name = f"bounds_{receiver}_{variant}_{shape}"
                path = directory / f"{name}.ts"
                subprocess.run(
                    [
                        checker,
                        "syrup",
                        str(FIXTURE),
                        "ts",
                        f"bounds.{receiver}",
                        "--named",
                        f"{variant}_{shape}",
                        "invoke",
                        str(path),
                    ],
                    cwd=ROOT,
                    check=True,
                    timeout=30,
                )
                imports.append(f'import {{ invoke as {name} }} from "./{name}.ts";\nvoid {name};\n')
    text = directory / "bounds_Text_bounded_call.ts"
    text.write_text(
        text.read_text()
        + r"""
const encoder = new TextEncoder();
function refuses(run: () => void, message: string): void {
    let refused = false;
    try { run(); } catch (error) { refused = error instanceof TypeError; }
    if (!refused) throw new Error(message);
}
for (let unit = 0; unit <= 0xffff; unit++) {
    const value = String.fromCharCode(unit);
    const bytes = BigInt(encoder.encode(value).length);
    text_bytes(value, bytes, bytes);
    refuses(() => text_bytes(value, bytes + 1n, null), "text lower bound accepted");
    refuses(() => text_bytes(value, 0n, bytes - 1n), "text upper bound accepted");
}
for (const left of ["a", "é", "€", "\ud800", "\udbff", "\udc00", "\udfff", "💩"]) {
    for (const right of ["", "a", "\ud800", "\udbff", "\udc00", "\udfff", "💩"]) {
        const value = left + right;
        const bytes = BigInt(encoder.encode(value).length);
        text_bytes(value, bytes, bytes);
    }
}
let reads = 0;
const original = String.prototype.charCodeAt;
String.prototype.charCodeAt = function(this: string, index: number): number { reads++; return Reflect.apply(original, this, [index]); };
try {
    text_bytes("a".repeat(10000), 1n, null);
    if (reads !== 1) throw new Error("lower bound scan did not stop");
    reads = 0;
    refuses(() => text_bytes("a".repeat(10000), 0n, 4n), "text upper bound admitted");
    if (Number(reads) !== 5) throw new Error("upper bound scan did not stop");
} finally { String.prototype.charCodeAt = original; }
"""
    )
    integer = directory / "bounds_Integer_upper_call.ts"
    integer.write_text(
        integer.read_text()
        + r"""
if (integer_unbounded_p2(-(2n ** 128n)) !== -(2n ** 128n)) throw new Error("partial integer narrowed");
let refused = false;
try { integer_unbounded_p2(3n); } catch (error) { refused = error instanceof TypeError; }
if (!refused) throw new Error("integer upper bound admitted");
"""
    )
    values = directory / "bounds_values.ts"
    subprocess.run(
        [checker, "syrup", str(FIXTURE), "ts", "bounds.Mixed", "--named", "values", "invoke", str(values)],
        cwd=ROOT,
        check=True,
        timeout=30,
    )
    values.write_text(
        values.read_text()
        + r"""
const values = new Array<Argument>(MAX_REPLY_WORK + 1).fill(null);
Object.defineProperty(values, 0, { get() { throw new Error("opaque list element read"); } });
if (compound_0(values) !== values) throw new Error("opaque list replaced");
const budget = { remaining: 1 };
if (compound_0_at(values, budget) !== values || budget.remaining !== 0) throw new Error("opaque list added work");
"""
    )
    imports.append('import { invoke as bounds_values } from "./bounds_values.ts";\nvoid bounds_values;\n')
    # Change an actual emitted bound, require the scratch runtime assertion to
    # fail, and restore the exact bytes before checking the final consumers.
    original = integer.read_bytes()
    changed = original.replace(b"value > 2n", b"value > 3n")
    assert changed != original, "integer mutation did not change its bound"
    integer.write_bytes(changed)
    try:
        result = subprocess.run(
            ["deno", "run", "--config", str(ROOT / "deno.json"), str(integer)],
            cwd=ROOT,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode and b"integer upper bound admitted" in result.stderr, "bound mutation survived"
    finally:
        integer.write_bytes(original)
    assert integer.read_bytes() == original, "integer mutation restore was not exact"
    for index, (name, receiver, selector) in enumerate(
        (
            ("text_bytes", "Text", "bounded_call"),
            ("text_1_4", "Text", "bounded_call"),
            ("integer_unbounded_p2", "Integer", "upper_call"),
            ("integer_m2_p2", "Integer", "narrow_call"),
        )
    ):
        path = directory / f"bounds_collision{index}.ts"
        subprocess.run(
            [checker, "syrup", str(FIXTURE), "ts", f"bounds.{receiver}", "--named", selector, name, str(path)],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        imports.append(
            f'import {{ {name} as bounds_collision{index} }} from "./{path.name}";\nvoid bounds_collision{index};\n'
        )
    # Only the modules with appended runtime assertions need to execute. The
    # importer checks every minimal projection, including tell-only helpers.
    return [text, integer, values]
