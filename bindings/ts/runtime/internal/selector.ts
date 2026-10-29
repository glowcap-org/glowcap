// The Host ABI uses pointer presence for selector presence. A shared byte
// keeps an empty selector non-null in every FFI adapter, including Wasm.
import { NULL, type Ptr } from "./ffi/runtime.ts";
import { readBytes } from "./seam.ts";

const empty = new Uint8Array(1);
const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function selectorBuffer(verb: string | null): Uint8Array<ArrayBuffer> | null {
	return verb === null ? null : verb === "" ? empty : encoder.encode(verb);
}

export function selectorLength(buffer: Uint8Array | null): bigint {
	return buffer === empty ? 0n : BigInt(buffer?.length ?? 0);
}

export function readSelector(ptr: Ptr, len: number | bigint): string | null {
	return ptr === NULL ? null : decoder.decode(readBytes(ptr, BigInt(len)));
}
