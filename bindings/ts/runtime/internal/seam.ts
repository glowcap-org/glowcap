// The binding-internal seam: the pointer, byte, and raw-socket plumbing the
// core `../mod.ts` and the transport modules (`@glowcap/tcp/transport`,
// `../transport/inproc.ts`, and the `@glowcap/iroh` package) share, so every
// module marshals frames through the same helpers. Nothing here rides the
// public `.` entry: an in-package sibling (and the dogfood) imports this file
// directly, and a companion package reaches the pointer and error-slot
// helpers through `@glowcap/runtime/ffi`. An application uses the core's
// `connect` / `listen` and never these.

import { ocapnS as s } from "./ffi/ocapn.ts";
import { ffi, net, type NetConn, type NetListener, NULL, type Ptr } from "./ffi/runtime.ts";
import { L } from "./layout.ts";

// Our buffers are always ArrayBuffer-backed; this bridges Deno's FFI/pointer
// BufferSource typing, which rejects the `Uint8Array<ArrayBufferLike>` generic.
export function ab(b: Uint8Array): Uint8Array<ArrayBuffer> {
	return b as Uint8Array<ArrayBuffer>;
}

/** Copy `len` bytes at `ptrValue` out of FFI memory into JS-owned storage
 * (empty for NULL/0). This is the one place byte ownership is established: every
 * adapter's `readMemory` returns a freshly-owned `ArrayBuffer`, so the result
 * outlives the FFI storage and a caller never re-copies it (no defensive
 * `.slice()` on a `readBytes` result). */
export function readBytes(ptrValue: Ptr, len: bigint): Uint8Array {
	if (ptrValue === NULL || len === 0n) return new Uint8Array(0);
	return new Uint8Array(ffi.readMemory(ptrValue, Number(len)));
}

/** Read the pointer an out-parameter buffer received from an FFI call. The
 * cell is always a freshly zeroed 8-byte buffer; the callee writes pointer
 * width (4 on wasm32), so the read goes through the active layout rather
 * than assuming 8. `outUsize` / `outU64` are the size and 64-bit siblings:
 * every out-cell read lives in this trio so no call site hand-picks a width. */
export function outPointer(buf: Uint8Array): Ptr {
	return L.getPtr(new DataView(buf.buffer), 0);
}

/** Read a 32-bit enum or feature-mask out-cell. */
export function outU32(buf: Uint8Array): number {
	return new DataView(buf.buffer).getUint32(0, true);
}

/** Read a `usize` out-cell (a consumed-byte count, a length, a hint count). */
export function outUsize(buf: Uint8Array): bigint {
	return L.getUsize(new DataView(buf.buffer), 0);
}

/** Read a true 64-bit out-cell (a vow id or opaque Host capability id): u64 on every
 * target, so this one reads 8 bytes unconditionally. */
export function outU64(buf: Uint8Array): bigint {
	return new DataView(buf.buffer).getBigUint64(0, true);
}

/** Read an archive's thread-local last-error slot into a string, or null when
 * empty. `read` is the archive's two-pass C reader `(buffer, cap) -> len`: probe
 * the length with a null buffer, then copy into a right-sized buffer and clamp to
 * what the second call wrote (the slot is zero-filled, so an unclamped
 * slice could trail NULs). Every archive family (core, the transports, and the
 * actor runtime) reads its own slot through this, so the two-pass discipline
 * lives in one place. */
export function readErrorSlot(
	read: (buf: Uint8Array | null, cap: bigint) => number | bigint,
): string | null {
	const len = Number(read(null, 0n));
	if (len === 0) return null;
	const buf = new Uint8Array(len + 1);
	const written = Number(read(buf, BigInt(buf.length)));
	return new TextDecoder().decode(buf.subarray(0, Math.min(written, buf.length)));
}

/** Release a managed frame the core ABI filled (a transport module's blocking
 * `readFrame` returns one). */
export function releaseManagedFrame(mf: Uint8Array): void {
	s.glowcap_managed_frame_release(ab(mf));
}

// The runtime socket seam for transports and dogfood tests that drive a raw
// connection (the keyed handshake, an unframed shuttle).
export type { NetConn, NetListener };

/** Dial a raw TCP socket through the host runtime. */
export function connectTcp(host: string, port: number): Promise<NetConn> {
	return net.connect(host, port);
}

/** Bind a raw TCP listener through the host runtime. */
export function listenTcp(host: string, port: number): Promise<NetListener> {
	return net.listen(host, port);
}
