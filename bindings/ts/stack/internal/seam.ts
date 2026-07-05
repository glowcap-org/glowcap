// The binding-internal seam: the pointer, byte, and raw-socket plumbing the
// core `../mod.ts` and the transport modules (`../transport/tcp.ts`,
// `../transport/inproc.ts`, and the `@pancake/iroh` package) share, so every
// module marshals frames through the same helpers. Nothing here rides the
// public `.` entry: an in-package sibling imports this file directly, and a
// companion package reaches it through `@pancake/stack/ffi`. An application
// uses the core's `connect` / `listen` and never these.

import { coreS as s } from "./ffi/core.ts";
import { ffi, net, type NetConn, type NetListener, NULL, type Ptr } from "./ffi/runtime.ts";

// Our buffers are always ArrayBuffer-backed; this bridges Deno's FFI/pointer
// BufferSource typing, which rejects the `Uint8Array<ArrayBufferLike>` generic.
export function ab(b: Uint8Array): Uint8Array<ArrayBuffer> {
	return b as Uint8Array<ArrayBuffer>;
}

/** Copy `len` bytes at `ptrValue` out of native memory (empty for NULL/0). */
export function readBytes(ptrValue: Ptr, len: bigint): Uint8Array {
	if (ptrValue === NULL || len === 0n) return new Uint8Array(0);
	return new Uint8Array(ffi.readMemory(ptrValue, Number(len)));
}

/** Read the pointer an out-parameter buffer received from an FFI call. */
export function outPointer(buf: Uint8Array): Ptr {
	return new DataView(buf.buffer).getBigUint64(0, true);
}

/** Release a managed frame the core ABI filled (a transport module's blocking
 * `readFrame` returns one). */
export function releaseManagedFrame(mf: Uint8Array): void {
	s.pancake_managed_frame_release(ab(mf));
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
