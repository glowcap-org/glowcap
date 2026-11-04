"""interface-conversation-check: passable sequence types and actual packed work.

Called by check_generated.py with its checker, scratch owner, and consumer imports.
Each compiler child has a 30-second deadline. Runtime hooks append only to scratch
copies of the actual emitted helpers, with no production API or payload copies.
"""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "test/interface/scalar_bounds.syrup"
METHODS = (
    "integers",
    "signed",
    "narrow",
    "values",
    "symbols",
    "floats",
    "targets",
    "texts",
    "booleans",
    "byteArrays",
    "nested",
    "tuple",
    "wideTuple",
    "zero",
    "incompatible",
    "limited",
    "opaqueTuple",
    "nestedTuples",
    "record",
)


def check_packed(checker, directory, imports):
    for selector in METHODS:
        path = directory / f"packed_{selector}.ts"
        subprocess.run(
            [checker, "syrup", str(FIXTURE), "ts", "bounds.Packed", "--named", selector, "invoke", str(path)],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        imports.append(f'import {{ invoke as packed_{selector} }} from "./{path.name}";\nvoid packed_{selector};\n')
    integers = directory / "packed_integers.ts"
    integers.write_text(
        integers.read_text()
        + r"""
const packed = new BigInt64Array(MAX_REPLY_WORK + 1);
const budget = { remaining: 1 };
if (compound_0_at(packed, budget) !== packed || budget.remaining !== 0) throw new Error("packed integer category walked");
let refused = false;
try { compound_0(Array.from(packed)); } catch (error) { refused = error instanceof ResourceLimit; }
if (!refused) throw new Error("array integer categories escaped actual work budget");
"""
    )
    narrow = directory / "packed_narrow.ts"
    narrow.write_text(
        narrow.read_text()
        + r"""
const packed = new BigInt64Array([-2n, 0n, 2n]);
const budget = { remaining: 4 };
if (compound_0_at(packed, budget) !== packed || budget.remaining !== 0) throw new Error("narrow packed work is not exact");
let refused = false;
try { compound_0_at(packed, { remaining: 3 }); } catch (error) { refused = error instanceof ResourceLimit; }
if (!refused) throw new Error("packed bound scan escaped work budget");
"""
    )
    nested = directory / "packed_nestedTuples.ts"
    nested.write_text(
        nested.read_text()
        + r"""
const child = new BigInt64Array([1n, 2n]);
const original = [child, child];
const budget = { remaining: 3 };
if (compound_0_at(original, budget) !== original || budget.remaining !== 0) throw new Error("nested packed tuple overcharged");
"""
    )
    typing = directory / "packed_typing.ts"
    typing.write_text(f'''
import {{ type Argument, type Session, Ref, Sym, Tagged }} from "@glowcap/runtime";
import * as lists from "{ROOT}/test/interface/generated/packed_lists.ts";
import * as tuples from "{ROOT}/test/interface/generated/packed_tuples.ts";
import {{ presence_value }} from "{ROOT}/test/interface/generated/callbacks.ts";
async function forwarding(session: Session, target: Ref): Promise<void> {{
    const integers = await lists.integers(session, target).observe();
    void session.send(target, "accept", [integers]);
    await session.tell(target, "accept", [integers]);
    await presence_value(session, target, integers).observe();
    for (const value of integers) {{ const integer: bigint = value; void integer; }}
    type TextView = Awaited<ReturnType<ReturnType<typeof lists.texts>["observe"]>>;
    // @ts-expect-error a primitive string is not a semantic list object.
    const primitive: TextView = "text";
    const fake = {{ length: 1, 0: "text", *[Symbol.iterator]() {{ yield "text"; }} }};
    // @ts-expect-error structural sequence data alone is not a passable Argument.
    const unpassable: TextView = fake;
    void [primitive, unpassable];
    const symbols = await lists.symbols(session, target).observe();
    for (const value of symbols) {{ const symbol: Sym = value; void symbol; }}
    const fixed = await tuples.incompatible(session, target).observe();
    const first: bigint = fixed[0];
    const second: string = fixed[1];
    const [integer, text] = fixed;
    const exactInteger: bigint = integer;
    const exactText: string = text;
    void [first, second, exactInteger, exactText];
    for (const value of fixed) {{ const element: bigint | string = value; void element; }}
    const record = await tuples.record(session, target).observe();
    const fields: Argument[] = [integers, fixed, record.value[0], record.value[1]];
    void new Tagged("forward", fields);
    // @ts-expect-error a sequence view guarantees no Array push method.
    integers.push(1n);
    // @ts-expect-error Array map is not part of the common sequence contract.
    integers.map((value: bigint) => value.toString());
    // @ts-expect-error projected sequence indices are read-only.
    integers[0] = 2n;
}}
void forwarding;
''')
    imports.append('import "./packed_typing.ts";\n')
    return [integers, narrow, nested]
