// Gate: the browser binding's wasm32 layout descriptor decodes cleanly.
//
// The freestanding wasm32 Host (`zig build wasm-driver`, ADR-0070) reports its
// own struct layout through the single export `glowcap_wasm_abi_layout`, because
// the wasm32 field offsets differ from the 64-bit host mirror `abi.ts` carries
// and cannot be reached from it. This check instantiates the module, reads the
// descriptor, and proves it is well formed, the JS marshaller depends on that
// blob, so a malformed or misordered descriptor must fail the build, not a
// browser at runtime.
//
// The descriptor is a run of little-endian u32 words: per struct in canonical
// order, `[ name_hash, size, field_count, off_0, … ]`, the hash being FNV-1a
// of the struct's manifest prefix. The call returns the total word count; when
// the buffer is smaller it writes nothing, so we probe with a zero capacity,
// then allocate and read.
//
// The canonical struct order and the field count of each struct are the
// contract with the marshaller, and both live in the generated
// `WASM_LAYOUT_STRUCTS` manifest (`@glowcap/abi`, `zig build gen-ts-abi`).
// This check holds the wasm module's descriptor against that manifest (same
// struct count, same per-struct field count) and cross-checks each struct's
// field count against the 64-bit `abi.ts` mirror's offset-constant group, so
// the three layout sources (descriptor, manifest, host mirror) cannot
// disagree on shape even though offsets legitimately differ by target width.

import * as abi from "../../bindings/ts/runtime/internal/abi.ts";
import { NATIVE_ONLY_LAYOUT_PREFIXES, WASM_LAYOUT_STRUCTS } from "../../bindings/ts/abi/constants.ts";
import { fnv1a32 } from "../../bindings/ts/runtime/internal/layout.ts";

// The manifest rows, in the descriptor's canonical order (`layout_specs` in
// `src/c_abi/wasm/mod.zig` mirrors this order; a drift fails below).
const SPECS = WASM_LAYOUT_STRUCTS.map((row) => ({
	name: row.prefix,
	fields: row.fields.length,
	mirrorPrefix: row.nativeMirror ? row.prefix as string | null : null,
}));

// Count `<PREFIX>_*_OFF` exports in the generated host mirror: that is how many
// fields the host side reads, which must equal the wasm descriptor's field count.
function mirrorFieldCount(prefix: string): number {
	let n = 0;
	for (const key of Object.keys(abi)) {
		if (key.startsWith(prefix + "_") && key.endsWith("_OFF")) n += 1;
	}
	return n;
}

const wasmPath = new URL("../../zig-out/wasm/glowcap_host.wasm", import.meta.url);

type Exports = {
	memory: WebAssembly.Memory;
	glowcap_wasm_alloc: (len: number) => number;
	glowcap_wasm_free: (ptr: number, len: number) => void;
	glowcap_wasm_abi_layout: (out: number, cap: number) => number;
};

function fail(msg: string): never {
	console.error("wasm-abi-layout-check: " + msg);
	Deno.exit(1);
}

const wasmBytes = await Deno.readFile(wasmPath);
// The module declares its behavior and hosted-free callback imports; supply
// no-op stubs so instantiation succeeds. This check triggers neither callback.
const { instance } = await WebAssembly.instantiate(wasmBytes, {
	env: {
		glowcap_behavior_trampoline: () => 0,
		glowcap_hosted_free_trampoline: () => {},
	},
});
const ex = instance.exports as unknown as Exports;
const mem = ex.memory;

// Probe the size with a zero capacity: the descriptor must write nothing and
// return the full word count. A null `out` (offset 0) is safe on this path.
const needed = ex.glowcap_wasm_abi_layout(0, 0);
if (!Number.isInteger(needed) || needed <= 0) {
	fail(`descriptor probe returned a non-positive word count (${needed})`);
}

const byteLen = needed * 4;
const ptr = ex.glowcap_wasm_alloc(byteLen);
if (ptr === 0) fail("glowcap_wasm_alloc failed for the descriptor buffer");

const wrote = ex.glowcap_wasm_abi_layout(ptr, needed);
if (wrote !== needed) {
	fail(`descriptor wrote a different word count than it probed (${wrote} vs ${needed})`);
}

const words = new Uint32Array(mem.buffer.slice(ptr, ptr + byteLen));
ex.glowcap_wasm_free(ptr, byteLen);

// Decode struct by struct, in canonical order, validating structural invariants
// and consuming exactly `needed` words.
let i = 0;
for (const spec of SPECS) {
	if (i + 3 > words.length) fail(`ran out of words decoding ${spec.name} header`);
	const hash = words[i++];
	if (hash !== fnv1a32(spec.name)) {
		fail(
			`${spec.name} descriptor block carries identity ${hash}, not ${fnv1a32(spec.name)}: ` +
				"layout_specs (src/c_abi/wasm/mod.zig) and WASM_LAYOUT_STRUCTS disagree on order",
		);
	}
	const size = words[i++];
	const fieldCount = words[i++];

	if (size === 0) fail(`${spec.name} reports zero size`);
	if (fieldCount === 0) fail(`${spec.name} reports zero fields`);
	if (fieldCount !== spec.fields) {
		fail(
			`${spec.name} descriptor field count ${fieldCount} disagrees with the WASM_LAYOUT_STRUCTS manifest (${spec.fields})`,
		);
	}
	if (i + fieldCount > words.length) {
		fail(`${spec.name} declares ${fieldCount} fields but the blob is too short`);
	}

	let prev = -1;
	for (let f = 0; f < fieldCount; f++) {
		const off = words[i++];
		if (off <= prev && !(f === 0 && off === 0)) {
			fail(
				`${spec.name} field ${f} offset ${off} is not strictly after the previous (${prev})`,
			);
		}
		if (off >= size) {
			fail(`${spec.name} field ${f} offset ${off} lies outside the struct size ${size}`);
		}
		prev = off;
	}

	if (spec.mirrorPrefix !== null) {
		const mirror = mirrorFieldCount(spec.mirrorPrefix);
		if (mirror === 0) {
			fail(
				`${spec.name} names mirror prefix ${spec.mirrorPrefix}, but abi.ts declares no such offsets`,
			);
		}
		if (mirror !== fieldCount) {
			fail(
				`${spec.name} field count ${fieldCount} disagrees with the abi.ts mirror ${spec.mirrorPrefix} (${mirror})`,
			);
		}
	}
}

if (i !== needed) fail(`decoded ${i} words but the descriptor claimed ${needed}`);

// The inverse direction: every struct the 64-bit mirror declares must have a
// manifest row (and therefore a descriptor entry), or a marshaller reading
// its `L.<PREFIX>_*` names would silently fall back to 64-bit offsets under
// the wasm adapter, which is wrong by construction on that target.
const manifestPrefixes = new Set(WASM_LAYOUT_STRUCTS.map((row) => row.prefix as string));
const nativeOnly = new Set<string>(NATIVE_ONLY_LAYOUT_PREFIXES);
for (const prefix of nativeOnly) {
	if (manifestPrefixes.has(prefix)) {
		fail(
			`${prefix} is listed native-only but has a WASM_LAYOUT_STRUCTS row; ` +
				"drop it from native_only_layouts (tools/gen/binding/ts_abi.zig)",
		);
	}
}
for (const key of Object.keys(abi)) {
	if (!key.endsWith("_SIZE")) continue;
	const prefix = key.slice(0, -"_SIZE".length);
	if (nativeOnly.has(prefix)) continue;
	if (!manifestPrefixes.has(prefix)) {
		fail(
			`abi.ts declares ${key} but WASM_LAYOUT_STRUCTS has no ${prefix} row; ` +
				"add the struct to the manifest (tools/gen/binding/ts_abi.zig) and " +
				"layout_specs (src/c_abi/wasm/mod.zig), or list it in " +
				"native_only_layouts if its archive never links into wasm32",
		);
	}
}

console.log(
	`wasm-abi-layout-check: ${SPECS.length} struct(s), ${needed} words, layout well formed.`,
);
