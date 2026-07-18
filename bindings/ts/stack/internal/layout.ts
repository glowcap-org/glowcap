// The one ABI-layout authority the struct marshallers read.
//
// JavaScript FFI has no struct types, so the binding reads and writes C structs
// by byte offset — and those offsets are target-specific: pointers and `usize`
// are eight bytes on the dlopen targets and four on wasm32. This module holds
// the active layout as one object, `L`: the generated 64-bit mirror
// (`abi.ts`, `zig build gen-ts-abi`) by default, or a layout rebuilt from the
// wasm32 module's own descriptor (`pancake_wasm_abi_layout`) when the browser
// adapter is active. Struct consumers read every size and field offset through
// `L`, and read/write pointer-width fields through `L.getPtr` / `L.setPtr` /
// `L.getUsize` / `L.setUsize`, so one marshaller body serves both widths.
//
// Selection happens once, at adapter load (`./ffi/runtime.ts` calls
// `setActiveLayout` from its top-level await), before any dependent module can
// marshal a struct. Fixed-width fields (u32 kinds, i64 integers, u64 ids,
// f64) keep their direct DataView calls; only pointer-width fields and the
// offsets themselves go through the layout.

import * as abi64 from "./abi.ts";
import { WASM_LAYOUT_STRUCTS } from "@pancake/abi";

/** Every struct size / field-offset constant the generated 64-bit mirror
 * declares; the wasm32 layout rebuilds the same names at its own offsets. */
export type LayoutNumbers = { readonly [K in keyof typeof abi64]: number };

/** The active ABI layout: the mirror's constant names plus the pointer width
 * and the width-aware accessors for pointer/`usize` fields. */
export type AbiLayout = LayoutNumbers & {
	/** Pointer / `usize` width in bytes on the loaded ABI target. */
	readonly ptrSize: 4 | 8;
	/** Read a pointer-width field as a `bigint` address (`0n` is null). */
	readonly getPtr: (dv: DataView, off: number) => bigint;
	/** Write a pointer-width field from a `bigint` address. */
	readonly setPtr: (dv: DataView, off: number, v: bigint) => void;
	/** Read a `usize` field as a `bigint`. */
	readonly getUsize: (dv: DataView, off: number) => bigint;
	/** Write a `usize` field from a `bigint` (or safe-integer `number`). */
	readonly setUsize: (dv: DataView, off: number, v: bigint | number) => void;
};

function withAccessors(nums: LayoutNumbers, ptrSize: 4 | 8): AbiLayout {
	if (ptrSize === 8) {
		return {
			...nums,
			ptrSize,
			getPtr: (dv, off) => dv.getBigUint64(off, true),
			setPtr: (dv, off, v) => dv.setBigUint64(off, v, true),
			getUsize: (dv, off) => dv.getBigUint64(off, true),
			setUsize: (dv, off, v) => dv.setBigUint64(off, BigInt(v), true),
		};
	}
	return {
		...nums,
		ptrSize,
		getPtr: (dv, off) => BigInt(dv.getUint32(off, true)),
		setPtr: (dv, off, v) => dv.setUint32(off, Number(v & 0xffffffffn), true),
		getUsize: (dv, off) => BigInt(dv.getUint32(off, true)),
		setUsize: (dv, off, v) => dv.setUint32(off, Number(v), true),
	};
}

/** The generated 64-bit mirror as the active-layout shape (dlopen targets). */
export const layout64: AbiLayout = withAccessors(abi64, 8);

/** FNV-1a over a manifest prefix: the struct-identity word each descriptor
 * block leads with, recomputed here so an order swap between the module's
 * `layout_specs` and the manifest fails loud instead of zipping offsets onto
 * the wrong struct's names. */
export function fnv1a32(name: string): number {
	let hash = 0x811c9dc5;
	for (let i = 0; i < name.length; i++) {
		hash ^= name.charCodeAt(i);
		hash = Math.imul(hash, 0x01000193) >>> 0;
	}
	return hash >>> 0;
}

/** Rebuild the layout from a wasm32 module's descriptor blob
 * (`pancake_wasm_abi_layout`): little-endian u32 words, per struct in the
 * `WASM_LAYOUT_STRUCTS` manifest order, `[name_hash, size, field_count,
 * off_0, …]`. The identity hash proves each block is the struct the manifest
 * row names, and the manifest lists the fields in declaration order, so the
 * words zip onto the same constant names the 64-bit mirror declares. Any
 * mismatch is a build-skew failure (`zig build wasm-abi-layout-check` holds
 * the pair), refused loudly rather than marshalled wrong. */
export function layoutFromWasmDescriptor(words: Uint32Array): AbiLayout {
	const nums: Record<string, number> = { ...abi64 };
	let i = 0;
	for (const row of WASM_LAYOUT_STRUCTS) {
		if (i + 3 > words.length) {
			throw new Error(`wasm layout descriptor ran out of words at ${row.prefix}`);
		}
		const hash = words[i++];
		if (hash !== fnv1a32(row.prefix)) {
			throw new Error(
				`wasm layout descriptor block ${row.prefix} carries identity ${hash}, ` +
					`not ${fnv1a32(row.prefix)}: layout_specs and the manifest disagree on order`,
			);
		}
		const size = words[i++];
		const fieldCount = words[i++];
		if (fieldCount !== row.fields.length) {
			throw new Error(
				`wasm layout descriptor ${row.prefix} field count ${fieldCount} != manifest ${row.fields.length}`,
			);
		}
		nums[`${row.prefix}_SIZE`] = size;
		for (const field of row.fields) {
			nums[`${row.prefix}_${field}_OFF`] = words[i++];
		}
	}
	if (i !== words.length) {
		throw new Error(`wasm layout descriptor decoded ${i} of ${words.length} words`);
	}
	return withAccessors(nums as LayoutNumbers, 4);
}

/** The active layout. Live binding: reads through `L` see the adapter's
 * selection the moment `setActiveLayout` runs (before any marshalling). */
export let L: AbiLayout = layout64;

/** Install the adapter's layout. Called once from the runtime seam's
 * top-level adapter selection; never after marshalling has begun. */
export function setActiveLayout(layout: AbiLayout): void {
	L = layout;
}
