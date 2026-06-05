/**
 * abi.ts — shared FFI plumbing across all three cdylibs.
 *
 * The pancake C ABI is a family of cdylibs (ADR-0050/0051): the
 * protocol core (`PANCAKE_LIB`), the TCP/TLS netlayer
 * (`PANCAKE_NET_TCP_LIB`), and the iroh netlayer (`PANCAKE_NET_IROH_LIB`).
 * They share two struct layouts via the generated `pancake_abi.h` —
 * `PancakeFrame` (a bare borrow for the inbound feed) and
 * `PancakeManagedFrame` (a self-describing, release-carrying handle for
 * every producer-allocated buffer: outbound frames + netlayer read
 * frames) — plus the one `pancake_managed_frame_release` that frees the
 * latter regardless of which cdylib produced it.
 *
 * The panic seam (pancake-ffi-abi) is statically linked into EACH
 * cdylib, so every library has its OWN per-thread last-error slot. A
 * failed net-tcp call stashes its diagnostic in the net-tcp lib's
 * slot, NOT the runtime lib's. Each FFI module therefore binds its own
 * `pancake_last_error` (see `makeLastError`).
 *
 * Layout assumptions: LP64, 64-bit little-endian pointers (x86_64 /
 * aarch64). Windows / 32-bit would need the offsets revisited.
 */

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

/** A pointer-or-null as Deno's FFI surfaces it. */
export type Ptr = Deno.PointerValue;

/**
 * An `ArrayBuffer`-backed byte buffer. Deno's FFI `"buffer"` params and
 * `Deno.UnsafePointer.of` require `BufferSource` (an `ArrayBuffer`
 * view, not a `SharedArrayBuffer` one), so the binding standardizes on
 * this concrete buffer type at every FFI boundary.
 */
export type Buf = Uint8Array<ArrayBuffer>;

/** Allocate a fresh zeroed `ArrayBuffer`-backed buffer of `size` bytes. */
export function allocBuf(size: number): Buf {
  return new Uint8Array(size);
}

/** Assert a `Uint8Array` is `ArrayBuffer`-backed (true for all we create / accept). */
export function asBuf(u: Uint8Array): Buf {
  return u as Buf;
}

/** Encode a JS string as a NUL-terminated UTF-8 buffer for `const char *`. */
export function cstr(s: string): Buf {
  const bytes = textEncoder.encode(s);
  const out = allocBuf(bytes.length + 1);
  out.set(bytes);
  return out;
}

/** Encode a JS string as a UTF-8 buffer WITHOUT a NUL (for `bytes`/`len` pairs). */
export function utf8(s: string): Buf {
  const bytes = textEncoder.encode(s);
  const out = allocBuf(bytes.length);
  out.set(bytes);
  return out;
}

export function decodeUtf8(bytes: Uint8Array): string {
  return textDecoder.decode(bytes);
}

/** Read a NUL-terminated C string at a (non-null) pointer. */
export function readCString(ptr: Ptr): string {
  if (ptr === null) return "";
  return new Deno.UnsafePointerView(ptr).getCString();
}

/**
 * Copy `len` bytes out of a (non-null) pointer into a fresh, JS-owned
 * buffer.
 *
 * `UnsafePointerView.getArrayBuffer` returns a buffer that ALIASES the
 * native memory — wrapping it in a `Uint8Array` does not copy. Callers
 * that free the underlying Rust allocation immediately afterwards (the
 * `pancake_managed_frame_release` / `pancake_typed_*_free` paths) would
 * otherwise read allocator free-list bytes back. The explicit `.set`
 * forces an owned copy while the native memory is still live.
 */
export function readBytes(ptr: Ptr, len: number): Buf {
  if (ptr === null || len === 0) return allocBuf(0);
  const aliased = new Uint8Array(new Deno.UnsafePointerView(ptr).getArrayBuffer(len));
  const owned = allocBuf(len);
  owned.set(aliased);
  return owned;
}

/** True for a NULL `Deno.PointerValue` (narrows the pointer on the false branch). */
export function isNull(ptr: Ptr): ptr is null {
  return ptr === null;
}

/**
 * A scoped allocation arena.
 *
 * The send-side marshalling builds trees of heap buffers (peer-id
 * bytes, swissnum bytes, symbol/string UTF-8, nested argument arrays)
 * whose pointers get written into parent structs. Those backing
 * buffers MUST stay reachable (un-GC'd, un-moved) for the duration of
 * the FFI call. The arena retains every buffer it hands out a pointer
 * for; the caller keeps the arena alive across the call, then drops
 * it. pancake copies every projected leaf on push, so the arena is
 * safe to discard the instant the FFI call returns.
 */
export class Arena {
  readonly #buffers: Buf[] = [];

  /** Register a buffer and return a stable pointer into it. */
  pin(buf: Buf): Ptr {
    this.#buffers.push(buf);
    return Deno.UnsafePointer.of(buf);
  }

  /** Allocate a zeroed buffer of `size` bytes, pinned. */
  alloc(size: number): { buf: Buf; ptr: Ptr } {
    const buf = allocBuf(size);
    return { buf, ptr: this.pin(buf) };
  }
}

/**
 * Build a per-library last-error reader. Each cdylib statically links
 * the panic seam, so the host binds this 3× (runtime / net-tcp /
 * net-iroh) and surfaces the matching library's diagnostic.
 */
export function makeLastError(
  fn: () => Ptr,
): () => string {
  return () => {
    const ptr = fn();
    return ptr === null ? "" : readCString(ptr);
  };
}

/** Error raised when an FFI call returns a non-OK code. */
export class PancakeError extends Error {
  readonly code: number;
  constructor(op: string, code: number, lastError: string) {
    super(`${op}: rc=${code}${lastError ? `; last error: ${lastError}` : ""}`);
    this.name = "PancakeError";
    this.code = code;
  }
}

/** DataView over a Uint8Array for writing/reading little-endian fields. */
export function viewOf(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
}

/** Write a pointer value into a DataView field at `offset` (little-endian u64). */
export function writePtr(dv: DataView, offset: number, ptr: Ptr): void {
  dv.setBigUint64(offset, ptr === null ? 0n : Deno.UnsafePointer.value(ptr), true);
}
