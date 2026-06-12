// Idiomatic Deno API for libpancake — an OCapN/CapTP peer you drive.
//
// The raw Deno.dlopen FFI is private to this module. What you use is a `Peer`
// class (disposable via `using`), discriminated-union value types, and typed
// `Event` objects out of `poll`. The default `Peer` negotiates an authenticated
// session; raw direct-frame fixtures use `Peer.rawOpen`. Integers are `bigint`,
// floats are `number`.
//
//   using peer = Peer.rawOpen();
//   peer.registerImport(5n);
//   peer.sendDeliver(far(5n), [42n, new Uint8Array([1, 2])], 9n);
//   peer.step();
//   const frame = peer.takeOutbound();

import {
  ARG_BOOLEAN,
  ARG_BIG_INTEGER,
  ARG_BYTES,
  ARG_FLOAT64,
  ARG_INTEGER,
  ARG_KEYWORD,
  INVALID_ARGUMENT,
  ABORT_DOMAIN_CODEC,
  ABORT_DOMAIN_SESSION,
  ARG_LIST,
  ARG_REFERENCE,
  ARG_SET,
  ARG_SIZE,
  ARG_STRING,
  ARG_SYMBOL,
  ARG_TAGGED,
  ARG_VOID,
  BROKEN,
  CAPTP_VERSION_PRE_SPEC,
  CAPTP_VERSION_V1_0,
  CLOSED,
  CODEC_CAPNP,
  CODEC_SYRUP,
  EVENT_DELIVER,
  EVENT_RESOLVE,
  FRAME_SHAPE_BYTE,
  HINTS_EMPTY_FALSE,
  HINTS_EMPTY_MAP,
  OK,
  REF_BROKEN,
  REF_FAR,
  REF_NEAR,
  REF_SUB_OBJECT,
  REF_PROMISE,
  REF_SUB_PROMISE,
  REF_SIZE,
  REF_STURDY,
  RESOLUTION_BREAK,
  RESOLUTION_FULFILL,
  UNSUPPORTED_VALUE,
  WOULD_BLOCK,
} from "./constants.ts";

// The dynamic library's name is platform-specific: `.dylib` on macOS, `.dll` on
// Windows, `.so` elsewhere. `zig build` emits the right one into zig-out/lib.
const libFile = Deno.build.os === "darwin"
  ? "libpancake.dylib"
  : Deno.build.os === "windows"
  ? "pancake.dll"
  : "libpancake.so";
const libPath = new URL(`../../zig-out/lib/${libFile}`, import.meta.url).pathname;

const lib = Deno.dlopen(libPath, {
  pancake_abi_version: { parameters: ["buffer", "buffer", "buffer"], result: "void" },
  pancake_last_error: { parameters: ["buffer", "usize"], result: "usize" },
  pancake_clear_last_error: { parameters: [], result: "void" },
  pancake_context_new: { parameters: ["buffer"], result: "i32" },
  pancake_context_new_with_allocator: { parameters: ["buffer", "buffer"], result: "i32" },
  pancake_context_release: { parameters: ["pointer"], result: "void" },
  pancake_peer_new_in: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_new_negotiated: { parameters: ["u32", "u32", "buffer"], result: "i32" },
  pancake_peer_new_negotiated_in: { parameters: ["pointer", "u32", "u32", "buffer"], result: "i32" },
  pancake_tcp_netlayer_new_in: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_feed_owned: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_new: { parameters: ["buffer"], result: "i32" },
  pancake_peer_new_raw_open: { parameters: ["buffer"], result: "i32" },
  pancake_peer_new_raw_open_in: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_start_session: {
    parameters: ["pointer", "buffer", "usize", "buffer", "usize", "u32", "buffer", "usize"],
    result: "i32",
  },
  pancake_peer_session_is_open: { parameters: ["pointer"], result: "i32" },
  pancake_peer_release: { parameters: ["pointer"], result: "void" },
  pancake_peer_feed_borrowed: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_recv_stream: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  pancake_peer_step: { parameters: ["pointer"], result: "i32" },
  pancake_peer_take_outbound: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_managed_frame_release: { parameters: ["buffer"], result: "void" },
  pancake_peer_poll_event: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_event_release: { parameters: ["buffer"], result: "void" },
  pancake_peer_last_abort: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_register_export: { parameters: ["pointer", "u64"], result: "i32" },
  pancake_peer_next_export: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_next_answer: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_register_import: { parameters: ["pointer", "u64"], result: "i32" },
  pancake_peer_peek_event: { parameters: ["pointer"], result: "i32" },
  pancake_peer_send_deliver: {
    parameters: ["pointer", "buffer", "buffer", "usize", "u32", "u64"],
    result: "i32",
  },
  pancake_peer_send_resolve: {
    parameters: ["pointer", "u64", "u32", "buffer", "buffer", "usize"],
    result: "i32",
  },
  pancake_peer_poll_event_deliver: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_poll_event_resolve: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_deliver_release: { parameters: ["buffer"], result: "void" },
  pancake_resolve_release: { parameters: ["buffer"], result: "void" },
  pancake_peer_register_bootstrap_cap: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  pancake_peer_send_bootstrap_fetch: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  pancake_peer_codec: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_send_gc_export: { parameters: ["pointer", "buffer", "buffer", "usize"], result: "i32" },
  pancake_peer_send_gc_answer: { parameters: ["pointer", "u64"], result: "i32" },
  pancake_tcp_netlayer_new: { parameters: ["buffer"], result: "i32" },
  pancake_tcp_netlayer_release: { parameters: ["pointer"], result: "void" },
  pancake_tcp_connect: {
    parameters: ["pointer", "buffer", "usize", "u16", "u32", "usize", "buffer"],
    result: "i32",
  },
  pancake_tcp_listen: {
    parameters: ["pointer", "buffer", "usize", "u16", "buffer"],
    result: "i32",
  },
  pancake_tcp_listener_port: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_tcp_accept: { parameters: ["pointer", "u32", "usize", "buffer"], result: "i32" },
  pancake_tcp_conn_read_frame: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_tcp_conn_write_frame: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_tcp_conn_release: { parameters: ["pointer"], result: "void" },
  pancake_tcp_listener_release: { parameters: ["pointer"], result: "void" },
  // OCapN locator URIs — core vocabulary in libpancake, so a TCP-only consumer
  // reaches them without the iroh superset. The one grammar every binding shares.
  pancake_uri_parse_peer: { parameters: ["buffer", "usize", "buffer"], result: "i32" },
  pancake_uri_parse_sturdyref: { parameters: ["buffer", "usize", "buffer"], result: "i32" },
  pancake_uri_format_peer: {
    parameters: ["buffer", "usize", "buffer", "usize", "buffer", "buffer", "buffer", "buffer", "usize", "buffer", "usize", "buffer"],
    result: "i32",
  },
  pancake_uri_format_sturdyref: {
    parameters: ["buffer", "usize", "buffer", "usize", "buffer", "usize", "buffer", "buffer", "buffer", "buffer", "usize", "buffer", "usize", "buffer"],
    result: "i32",
  },
  pancake_locator_transport: { parameters: ["pointer", "buffer", "buffer"], result: "i32" },
  pancake_locator_designator: { parameters: ["pointer", "buffer", "buffer"], result: "i32" },
  pancake_locator_swissnum: { parameters: ["pointer", "buffer", "buffer"], result: "i32" },
  pancake_locator_hint: { parameters: ["pointer", "buffer", "usize", "buffer", "buffer"], result: "i32" },
  pancake_locator_hint_count: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_locator_hint_at: { parameters: ["pointer", "usize", "buffer", "buffer", "buffer", "buffer"], result: "i32" },
  pancake_locator_release: { parameters: ["pointer"], result: "void" },
});

const s = lib.symbols;
type Profile = "v1.0" | "pre-spec";

function profileId(profile: Profile): number {
  return profile === "pre-spec" ? CAPTP_VERSION_PRE_SPEC : CAPTP_VERSION_V1_0;
}

type Codec = "syrup" | "capnp";

function codecId(codec: Codec): number {
  return codec === "capnp" ? CODEC_CAPNP : CODEC_SYRUP;
}

// ── ABI version and per-thread last error ───────────────────────────────────

/** The linked library's ABI version as `[major, minor, patch]`. */
export function abiVersion(): [number, number, number] {
  const major = new Uint8Array(4), minor = new Uint8Array(4), patch = new Uint8Array(4);
  s.pancake_abi_version(major, minor, patch);
  return [
    new DataView(major.buffer).getUint32(0, true),
    new DataView(minor.buffer).getUint32(0, true),
    new DataView(patch.buffer).getUint32(0, true),
  ];
}

/** The calling thread's last error message, or null when there is none. */
export function lastError(): string | null {
  const len = Number(s.pancake_last_error(null, 0n));
  if (len === 0) return null;
  // The C side reserves one byte for a NUL and copies at most cap-1 message
  // bytes, so allocate len + 1 to receive all len of them.
  const buf = new Uint8Array(len + 1);
  const written = Number(s.pancake_last_error(buf, BigInt(buf.length)));
  return new TextDecoder().decode(buf.subarray(0, Math.min(written, buf.length)));
}

/** Clear the calling thread's last error. */
export function clearLastError(): void {
  s.pancake_clear_last_error();
}

/** The typed cause of a peer's most recent local dispatch failure — the
 * counterpart of the C ABI's `PancakeLastAbort`. `domain` names the layer that
 * refused, `kind` the projected `op:abort` kind when one exists, `message` the
 * static diagnostic, and `errorName` the originating error. */
export interface AbortDetail {
  domain: "codec" | "session" | "foreign";
  kind: string | null;
  message: string;
  errorName: string;
}

export class PancakeError extends Error {
  /** The thread-local diagnostic captured when this error was raised, if any. */
  readonly detail: string | null;
  /** The typed abort cause, attached when a peer refused an inbound frame. */
  abort: AbortDetail | null = null;
  constructor(public code: number, detail?: string) {
    // For a code an FFI call returned, capture the thread-local message now.
    // A client-side validation throw passes an explicit `detail` instead, so it
    // never scrapes an unrelated thread-local left by some earlier call.
    const d = detail ?? lastError();
    super(d ? `pancake error ${code}: ${d}` : `pancake error ${code}`);
    this.detail = d;
    this.name = "PancakeError";
  }
}

/** A promise the partner broke — the typed rejection an awaited `send` (or any
 * settled vow) produces. `reason` is the partner's break message. */
export class VowBroken extends PancakeError {
  constructor(public readonly reason: string) {
    super(BROKEN, reason);
    this.name = "VowBroken";
  }
}

/** A `fetch` that settled, but not with a capability — the application-level
 * outcome (the partner answered, and the answer was not a reference), distinct
 * from a marshalling failure or a broken promise. `capabilityName` is the
 * swiss-number the fetch asked for. */
export class FetchFailed extends PancakeError {
  constructor(public readonly capabilityName: string) {
    super(BROKEN, `fetch("${capabilityName}") did not resolve to a capability`);
    this.name = "FetchFailed";
  }
}

function check(code: number): void {
  if (code !== OK) throw new PancakeError(code);
}

// Our buffers are always ArrayBuffer-backed; this bridges Deno's FFI/pointer
// BufferSource typing, which rejects the `Uint8Array<ArrayBufferLike>` generic.
function ab(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return b as Uint8Array<ArrayBuffer>;
}

// ── Value vocabulary ─────────────────────────────────────────────────────────

export type Reference =
  | { kind: "near"; id: bigint; promise?: boolean }
  | { kind: "far"; id: bigint; promise?: boolean }
  | { kind: "promise"; answer: bigint }
  | { kind: "sturdy" }
  | { kind: "broken" };

export const near = (id: bigint, promise = false): Reference => ({ kind: "near", id, promise });
export const far = (id: bigint, promise = false): Reference => ({ kind: "far", id, promise });
export const promise = (answer: bigint): Reference => ({ kind: "promise", answer });

/** Tag a string so it marshals as an OCapN symbol rather than a string. */
export class Sym {
  constructor(public readonly value: string) {}
}
export const sym = (value: string): Sym => new Sym(value);

/** A string that marshals as an OCapN keyword. */
export class Kw {
  constructor(public readonly value: string) {}
}
export const kw = (value: string): Kw => new Kw(value);

/** A set of values (an OCapN set; elements may be non-primitive). */
export class PSet {
  constructor(public readonly items: Argument[]) {}
}
export const set = (items: Argument[]): PSet => new PSet(items);

/** An OCapN tagged record: a tag over a value list. */
export class Tagged {
  constructor(public readonly tag: string, public readonly value: Argument[]) {}
}
export const tagged = (tag: string, value: Argument[]): Tagged => new Tagged(tag, value);

// An argument is a native value or a wrapper:
//   bigint (integer), number (float64), boolean, Uint8Array (bytes), string,
//   Sym (symbol), Kw (keyword), null (void), Reference, Argument[] (list),
//   PSet (set), or Tagged.
export type Argument =
  | bigint
  | number
  | boolean
  | Uint8Array
  | string
  | Sym
  | Kw
  | null
  | Reference
  | Argument[]
  | PSet
  | Tagged;

export type Resolution = { fulfill: Argument } | { break: string };

export type Event =
  | { kind: "deliver"; target: Reference; args: Argument[]; answer: bigint | null }
  | { kind: "resolve"; answer: bigint; resolution: Resolution }
  | { kind: "other"; eventKind: number; frame: Uint8Array };

function isReference(v: unknown): v is Reference {
  return typeof v === "object" && v !== null && "kind" in v &&
    ["near", "far", "promise", "sturdy", "broken"].includes((v as Reference).kind);
}

// ── Marshalling (encode) ─────────────────────────────────────────────────────

function writeReference(dv: DataView, off: number, ref: Reference): void {
  let kind = REF_BROKEN, sub = 0, id = 0n;
  switch (ref.kind) {
    case "near":
      kind = REF_NEAR;
      sub = ref.promise ? REF_SUB_PROMISE : REF_SUB_OBJECT;
      id = ref.id;
      break;
    case "far":
      kind = REF_FAR;
      sub = ref.promise ? REF_SUB_PROMISE : REF_SUB_OBJECT;
      id = ref.id;
      break;
    case "promise":
      kind = REF_PROMISE;
      id = ref.answer;
      break;
    default:
      throw new PancakeError(UNSUPPORTED_VALUE, "sturdy/broken ref not carried on send");
  }
  dv.setUint32(off, kind, true);
  dv.setUint32(off + 4, sub, true);
  dv.setBigUint64(off + 8, id, true);
}

function refStruct(ref: Reference): Uint8Array {
  const buf = new Uint8Array(REF_SIZE);
  writeReference(new DataView(buf.buffer), 0, ref);
  return buf;
}

// Encodes args into one contiguous Uint8Array of ARG_SIZE structs, pushing any
// backing byte/child buffers onto `keep` so they outlive the FFI call.
function encodeArgs(args: Argument[], keep: Uint8Array[]): Uint8Array {
  const buf = new Uint8Array(ARG_SIZE * args.length);
  const dv = new DataView(buf.buffer);
  args.forEach((arg, i) => encodeArg(dv, i * ARG_SIZE, arg, keep));
  keep.push(buf);
  return buf;
}

function encodeArg(dv: DataView, off: number, arg: Argument, keep: Uint8Array[]): void {
  const setBytes = (kind: number, bytes: Uint8Array) => {
    keep.push(bytes);
    dv.setUint32(off, kind, true);
    const ptr = Deno.UnsafePointer.of(ab(bytes));
    dv.setBigUint64(off + 24, BigInt(Deno.UnsafePointer.value(ptr)), true);
    dv.setBigUint64(off + 32, BigInt(bytes.length), true);
  };
  if (typeof arg === "bigint") {
    if (arg < -(2n ** 63n) || arg >= 2n ** 63n) {
      // Outside the C ABI int64: ARG_BIG_INTEGER carries the canonical decimal
      // digits in bytes/bytes_len and the sign in boolean (ADR-0049).
      const negative = arg < 0n;
      setBytes(ARG_BIG_INTEGER, new TextEncoder().encode((negative ? -arg : arg).toString()));
      dv.setUint32(off + 4, negative ? 1 : 0, true);
    } else {
      dv.setUint32(off, ARG_INTEGER, true);
      dv.setBigInt64(off + 8, arg, true);
    }
  } else if (typeof arg === "number") {
    dv.setUint32(off, ARG_FLOAT64, true);
    dv.setFloat64(off + 16, arg, true);
  } else if (typeof arg === "boolean") {
    dv.setUint32(off, ARG_BOOLEAN, true);
    dv.setUint32(off + 4, arg ? 1 : 0, true);
  } else if (arg instanceof Uint8Array) {
    setBytes(ARG_BYTES, arg);
  } else if (arg instanceof Sym) {
    setBytes(ARG_SYMBOL, new TextEncoder().encode(arg.value));
  } else if (arg instanceof Kw) {
    setBytes(ARG_KEYWORD, new TextEncoder().encode(arg.value));
  } else if (typeof arg === "string") {
    setBytes(ARG_STRING, new TextEncoder().encode(arg));
  } else if (arg === null) {
    dv.setUint32(off, ARG_VOID, true);
  } else if (isReference(arg)) {
    dv.setUint32(off, ARG_REFERENCE, true);
    writeReference(dv, off + 40, arg);
  } else if (Array.isArray(arg)) {
    writeItems(ARG_LIST, arg);
  } else if (arg instanceof PSet) {
    writeItems(ARG_SET, arg.items);
  } else if (arg instanceof Tagged) {
    setBytes(ARG_TAGGED, new TextEncoder().encode(arg.tag));
    writeItems(ARG_TAGGED, arg.value);
  } else {
    throw new PancakeError(UNSUPPORTED_VALUE, "unsupported argument value");
  }

  function writeItems(kind: number, items: Argument[]): void {
    dv.setUint32(off, kind, true);
    const child = encodeArgs(items, keep);
    const ptr = Deno.UnsafePointer.of(ab(child));
    dv.setBigUint64(off + 56, BigInt(Deno.UnsafePointer.value(ptr)), true);
    dv.setBigUint64(off + 64, BigInt(items.length), true);
  }
}

// ── Marshalling (decode) ─────────────────────────────────────────────────────

function readReference(view: Deno.UnsafePointerView, off: number): Reference {
  const kind = view.getUint32(off);
  const sub = view.getUint32(off + 4);
  const id = view.getBigUint64(off + 8);
  const promise = sub === REF_SUB_PROMISE;
  switch (kind) {
    case REF_NEAR:
      return { kind: "near", id, promise };
    case REF_FAR:
      return { kind: "far", id, promise };
    case REF_PROMISE:
      return { kind: "promise", answer: id };
    case REF_STURDY:
      return { kind: "sturdy" };
    default:
      return { kind: "broken" };
  }
}

function readBytes(ptrValue: bigint, len: bigint): Uint8Array {
  if (ptrValue === 0n || len === 0n) return new Uint8Array(0);
  const view = new Deno.UnsafePointerView(Deno.UnsafePointer.create(ptrValue)!);
  return new Uint8Array(view.getArrayBuffer(Number(len)));
}

function readArg(view: Deno.UnsafePointerView, off: number): Argument {
  const kind = view.getUint32(off);
  switch (kind) {
    case ARG_INTEGER:
      return view.getBigInt64(off + 8);
    case ARG_FLOAT64:
      return view.getFloat64(off + 16);
    case ARG_BOOLEAN:
      return view.getUint32(off + 4) !== 0;
    case ARG_BYTES:
      return readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32));
    case ARG_STRING:
      return new TextDecoder().decode(readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32)));
    case ARG_SYMBOL:
      return new Sym(new TextDecoder().decode(readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32))));
    case ARG_REFERENCE:
      return readReference(view, off + 40);
    case ARG_LIST:
      return readArgArray(view.getBigUint64(off + 56), view.getBigUint64(off + 64));
    case ARG_SET:
      return new PSet(readArgArray(view.getBigUint64(off + 56), view.getBigUint64(off + 64)));
    case ARG_TAGGED:
      return new Tagged(
        new TextDecoder().decode(readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32))),
        readArgArray(view.getBigUint64(off + 56), view.getBigUint64(off + 64)),
      );
    case ARG_KEYWORD:
      return new Kw(new TextDecoder().decode(readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32))));
    case ARG_VOID:
      return null;
    case ARG_BIG_INTEGER: {
      // Canonical decimal digits + sign flag back to a native bigint (ADR-0049).
      const digits = new TextDecoder().decode(readBytes(view.getBigUint64(off + 24), view.getBigUint64(off + 32)));
      const magnitude = BigInt(digits);
      return view.getUint32(off + 4) !== 0 ? -magnitude : magnitude;
    }
    default:
      throw new PancakeError(INVALID_ARGUMENT, "unrecognized decoded argument kind");
  }
}

function readArgArray(ptrValue: bigint, len: bigint): Argument[] {
  if (ptrValue === 0n || len === 0n) return [];
  const view = new Deno.UnsafePointerView(Deno.UnsafePointer.create(ptrValue)!);
  const out: Argument[] = [];
  for (let i = 0; i < Number(len); i++) out.push(readArg(view, i * ARG_SIZE));
  return out;
}

// ── Allocation context ───────────────────────────────────────────────────────

// Deno's `UnsafeCallback<D>` is invariant in `D`, so a precisely-typed callback
// does not assign to a field annotated with the broad definition. We hold them
// as `AnyCallback` and only ever call `.pointer` / `.close()` off them.
// deno-lint-ignore no-explicit-any
type AnyCallback = Deno.UnsafeCallback<any>;

// An owned inbound frame the library holds: its bytes and the release
// trampoline must outlive the library's ownership and be reclaimed off-stack.
type PinnedFrame = { owned: Uint8Array; release: AnyCallback | null; retired: boolean };

/** A host allocation backend for `Context.withAllocator`. Methods may be called
 * from any thread that touches a handle created in the context. */
export interface HostAllocator {
  /** Return a block of at least `size` bytes aligned to `alignment`. */
  alloc(size: number, alignment: number): Uint8Array;
  /** Release a block previously returned by `alloc`. */
  free(block: Uint8Array, size: number, alignment: number): void;
}

/** An allocation scope. Peers and netlayers created with `Peer.newIn` /
 * `Netlayer.newIn` route every allocation through it. A context must outlive
 * every handle created in it; release it (via `using` / `[Symbol.dispose]`)
 * only after those handles. */
export class Context {
  #raw: Deno.PointerValue;
  // Kept alive while C holds them so the V8 GC cannot reclaim the trampolines
  // or the live allocation blocks the trampolines manage.
  #allocCb: AnyCallback | null = null;
  #freeCb: AnyCallback | null = null;
  #allocStruct: Uint8Array | null = null;
  #live: Map<bigint, Uint8Array> | null = null;

  private constructor(raw: Deno.PointerValue) {
    this.#raw = raw;
  }

  /** A context backed by the library-owned allocator. */
  static default(): Context {
    const out = new Uint8Array(8);
    check(s.pancake_context_new(out));
    return new Context(outPointer(out));
  }

  /** A context that routes every allocation through `allocator`. The host
   * callbacks are kept alive for the context's whole lifetime. */
  static withAllocator(allocator: HostAllocator): Context {
    const ctx = new Context(null);
    // pointer value -> the JS-owned block backing it, so free can reclaim it and
    // GC cannot collect a block C still references.
    const live = new Map<bigint, Uint8Array>();
    ctx.#live = live;

    const allocCb = new Deno.UnsafeCallback(
      { parameters: ["pointer", "usize", "usize"], result: "pointer" },
      (_user: Deno.PointerValue, size: bigint, alignment: bigint): Deno.PointerValue => {
        const n = Number(size);
        if (n === 0) return null;
        const block = allocator.alloc(n, Number(alignment));
        const ptr = Deno.UnsafePointer.of(ab(block));
        if (ptr === null) return null;
        live.set(BigInt(Deno.UnsafePointer.value(ptr)), block);
        return ptr;
      },
    );
    const freeCb = new Deno.UnsafeCallback(
      { parameters: ["pointer", "pointer", "usize", "usize"], result: "void" },
      (_user: Deno.PointerValue, ptr: Deno.PointerValue, size: bigint, alignment: bigint): void => {
        if (ptr === null) return;
        const key = BigInt(Deno.UnsafePointer.value(ptr));
        const block = live.get(key);
        live.delete(key);
        if (block !== undefined) allocator.free(block, Number(size), Number(alignment));
      },
    );
    ctx.#allocCb = allocCb;
    ctx.#freeCb = freeCb;

    // PancakeAllocator { alloc fn-ptr; free fn-ptr; user_data } — three pointers.
    const allocStruct = new Uint8Array(24);
    const dv = new DataView(allocStruct.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(allocCb.pointer)), true);
    dv.setBigUint64(8, BigInt(Deno.UnsafePointer.value(freeCb.pointer)), true);
    dv.setBigUint64(16, 0n, true); // user_data unused; state lives in the closures
    ctx.#allocStruct = allocStruct;

    const out = new Uint8Array(8);
    const rc = s.pancake_context_new_with_allocator(allocStruct, out);
    if (rc !== OK) {
      allocCb.close();
      freeCb.close();
      throw new PancakeError(rc);
    }
    ctx.#raw = outPointer(out);
    return ctx;
  }

  /** Opaque handle, for use by `Peer.newIn` / `Netlayer.newIn`. */
  get pointer(): Deno.PointerValue {
    return this.#raw;
  }

  release(): void {
    if (this.#raw !== null) {
      // Release the context first — it frees its tables through the allocator —
      // then close the callbacks the trampolines borrowed.
      s.pancake_context_release(this.#raw);
      this.#raw = null;
    }
    this.#allocCb?.close();
    this.#freeCb?.close();
    this.#allocCb = null;
    this.#freeCb = null;
    this.#allocStruct = null;
    this.#live = null;
  }

  [Symbol.dispose](): void {
    this.release();
  }
}

// ── The Peer ─────────────────────────────────────────────────────────────────

export class Peer {
  #raw: Deno.PointerValue;

  // Keeps this peer's owned-frame buffers and their release trampolines alive
  // while the library holds them, so the GC cannot reclaim either before the
  // release callback runs. Per-peer so releasing one peer drops only its pins.
  #pinnedFrames = new Set<PinnedFrame>();

  /** An authenticated v1.0 peer in the negotiating state. Use
   * `Peer.negotiated(...)` to choose another profile or codec. */
  constructor(raw?: Deno.PointerValue) {
    if (raw !== undefined) {
      this.#raw = raw;
      return;
    }
    const out = new Uint8Array(8);
    check(s.pancake_peer_new(out));
    this.#raw = Deno.UnsafePointer.create(new DataView(out.buffer).getBigUint64(0, true));
  }

  /** A negotiating peer whose allocations route through `context`; the context must outlive it. */
  static newIn(context: Context): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_in(context.pointer, out));
    return new Peer(outPointer(out));
  }

  /** A negotiating peer carrying an out-of-band negotiated profile and codec.
   * Both ends of a connection must construct with the same pair; the codec
   * must match the one the connection's endpoint frames with. */
  static negotiated(profile: Profile, codec: Codec = "syrup"): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_negotiated(profileId(profile), codecId(codec), out));
    return new Peer(outPointer(out));
  }

  /** Context-backed counterpart of `Peer.negotiated`. */
  static negotiatedIn(context: Context, profile: Profile, codec: Codec = "syrup"): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_negotiated_in(context.pointer, profileId(profile), codecId(codec), out));
    return new Peer(outPointer(out));
  }

  /** Already-open peer for tests and low-level direct-frame fixtures. */
  static rawOpen(): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_raw_open(out));
    return new Peer(outPointer(out));
  }

  /** Context-backed counterpart of `Peer.rawOpen`. */
  static rawOpenIn(context: Context): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_raw_open_in(context.pointer, out));
    return new Peer(outPointer(out));
  }

  release(): void {
    if (this.#raw !== null) {
      // Releasing the peer frees any owned frames still queued in the library,
      // synchronously invoking each release callback (which retires its pin).
      s.pancake_peer_release(this.#raw);
      this.#raw = null;
    }
    // The library no longer holds any of this peer's frames, so reclaim every
    // remaining pin (retired or not) here rather than leaving them dangling
    // until some other peer's next feedOwned sweep runs.
    for (const pin of this.#pinnedFrames) {
      pin.release?.close();
      pin.release = null;
    }
    this.#pinnedFrames.clear();
  }

  [Symbol.dispose](): void {
    this.release();
  }

  registerExport(id: bigint): void {
    check(s.pancake_peer_register_export(this.#raw, id));
  }

  /** Allocate and register the next free export position from the session's
   * one export allocator — the counter that also mints bootstrap and resolver
   * exports, so a spawned position can never alias one of them. */
  nextExport(): bigint {
    const out = new Uint8Array(8);
    check(s.pancake_peer_next_export(this.#raw, out));
    return new DataView(out.buffer).getBigUint64(0, true);
  }

  registerImport(id: bigint): void {
    check(s.pancake_peer_register_import(this.#raw, id));
  }

  /** Allocate the next outbound answer position from the session's one answer
   * allocator — the counter that backs every outbound question, so a
   * privately-counted answer can never alias a live one. */
  nextAnswer(): bigint {
    const out = new Uint8Array(8);
    check(s.pancake_peer_next_answer(this.#raw, out));
    return new DataView(out.buffer).getBigUint64(0, true);
  }

  /** Sign and queue `op:start-session` from this negotiating peer. The
   * handshake speaks the profile the peer was constructed with
   * (`Peer.negotiated("pre-spec")` for upstream OCapN). The 32-byte `seed` is
   * the session key (the library refuses any other length);
   * `transport`/`designator` form the locator the partner verifies, so they
   * must be what it expects — for a Goblins partner, `"tcp"` with
   * `hintsEmptyFalse` true (Goblins emits the empty hints as the boolean
   * `#f`). Flush it with `step` + `takeOutbound`, then pump until
   * `sessionIsOpen`. */
  startSession(opts: {
    transport: string;
    designator: string;
    seed: Uint8Array;
    hintsEmptyFalse?: boolean;
  }): void {
    if (opts.seed.length !== 32) throw new Error("a session seed must be 32 bytes");
    const transport = new TextEncoder().encode(opts.transport);
    const designator = new TextEncoder().encode(opts.designator);
    check(s.pancake_peer_start_session(
      this.#raw,
      ab(transport),
      BigInt(transport.length),
      ab(designator),
      BigInt(designator.length),
      (opts.hintsEmptyFalse ?? true) ? HINTS_EMPTY_FALSE : HINTS_EMPTY_MAP,
      ab(opts.seed),
      BigInt(opts.seed.length),
    ));
  }

  /** Whether the authenticated handshake has completed and the session is open for
   * traffic. Pump the connection and poll this before sending application
   * messages. */
  sessionIsOpen(): boolean {
    const rc = s.pancake_peer_session_is_open(this.#raw);
    if (rc < 0) throw new PancakeError(rc);
    return rc === 1;
  }

  /** The typed cause of this peer's most recent local dispatch failure, or
   * null when none has been recorded. The per-call `PancakeError` code names
   * the failure family; this names the member. Errors thrown by `feed`,
   * `feedOwned`, and `recvStream` carry it already as `err.abort`. */
  lastAbort(): AbortDetail | null {
    // PancakeLastAbort { domain(0) u32; has_kind(4) u32; kind_name(8);
    //   kind_name_len(16); message(24); message_len(32); error_name(40);
    //   error_name_len(48) } = 56 bytes, LP64.
    const buf = new Uint8Array(56);
    const rc = s.pancake_peer_last_abort(this.#raw, buf);
    if (rc === WOULD_BLOCK) return null;
    check(rc);
    const dv = new DataView(buf.buffer);
    const text = (off: number): string =>
      new TextDecoder().decode(readBytes(dv.getBigUint64(off, true), dv.getBigUint64(off + 8, true)));
    const domainNum = dv.getUint32(0, true);
    return {
      domain: domainNum === ABORT_DOMAIN_CODEC
        ? "codec"
        : domainNum === ABORT_DOMAIN_SESSION
        ? "session"
        : "foreign",
      kind: dv.getUint32(4, true) !== 0 ? text(8) : null,
      message: text(24),
      errorName: text(40),
    };
  }

  // A PancakeError for a refused frame, carrying the typed abort cause. The
  // error is constructed first so it captures the thread-local message before
  // any later call clobbers it.
  #dispatchError(code: number): PancakeError {
    const err = new PancakeError(code);
    try {
      err.abort = this.lastAbort();
    } catch {
      // A peer that cannot report leaves the flat code on its own.
    }
    return err;
  }

  feed(frame: Uint8Array): void {
    const f = new Uint8Array(24);
    const dv = new DataView(f.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(Deno.UnsafePointer.of(ab(frame)))), true);
    dv.setBigUint64(8, BigInt(frame.length), true);
    dv.setUint32(16, FRAME_SHAPE_BYTE, true);
    const rc = s.pancake_peer_feed_borrowed(this.#raw, f);
    if (rc !== OK) throw this.#dispatchError(rc);
  }

  /** Frame and dispatch one whole frame out of a streaming buffer. `data` is a
   * borrowed slice of bytes read from the wire, possibly spanning more or less
   * than one frame. Returns the number of bytes consumed (the length of the one
   * frame framed and dispatched), `null` when `data` holds only a partial frame
   * (read more bytes and retry), and throws `PancakeError` on a malformed or
   * oversized frame. */
  recvStream(data: Uint8Array): number | null {
    const out = new Uint8Array(8);
    const rc = s.pancake_peer_recv_stream(this.#raw, ab(data), BigInt(data.length), ab(out));
    if (rc === WOULD_BLOCK) return null;
    if (rc !== OK) throw this.#dispatchError(rc);
    return Number(new DataView(out.buffer).getBigUint64(0, true));
  }

  /** Transfer owned `data` into the inbound queue for the next `step` — no
   * borrow to keep alive past the call, no copy by the library. On success the
   * library owns the bytes and frees them via the release callback; on failure
   * the bytes are reclaimed here before throwing. */
  feedOwned(data: Uint8Array): void {
    // Reclaim trampolines for frames the library already released.
    this.#sweepRetired();

    // Own a private copy so the caller's `data` lifetime is irrelevant.
    const owned = new Uint8Array(data.length);
    owned.set(data);
    const bytesPtr = Deno.UnsafePointer.of(ab(owned));

    // PancakeManagedFrame { bytes(0); len(8); shape(16,+pad); release(24); private(32) } = 40.
    const mf = new Uint8Array(40);
    const dv = new DataView(mf.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(bytesPtr)), true);
    dv.setBigUint64(8, BigInt(owned.length), true);
    dv.setUint32(16, FRAME_SHAPE_BYTE, true);

    // The release callback runs synchronously inside `feed_owned` / `step`.
    // Closing an UnsafeCallback from inside its own invocation frees the
    // trampoline mid-call (a crash), so the callback only retires the entry; the
    // owning buffer and the trampoline are reclaimed later, off the C stack.
    const pin: PinnedFrame = { owned, release: null, retired: false };
    const cb = new Deno.UnsafeCallback(
      { parameters: ["pointer"], result: "void" },
      (_frame: Deno.PointerValue): void => {
        pin.retired = true; // library handed ownership back; reclaim off-stack
      },
    );
    pin.release = cb;
    dv.setBigUint64(24, BigInt(Deno.UnsafePointer.value(cb.pointer)), true);
    dv.setBigUint64(32, 0n, true); // private_data unused; state lives in the closure
    this.#pinnedFrames.add(pin);

    const rc = s.pancake_peer_feed_owned(this.#raw, mf);
    if (rc !== OK) {
      // Not adopted: our descriptor still names our bytes; the library did not
      // call release. Build the error (capturing the typed abort cause), then
      // retire and reclaim ourselves before throwing.
      const err = this.#dispatchError(rc);
      pin.retired = true;
      this.#sweepRetired();
      throw err;
    }
  }

  // Close trampolines and drop buffers for frames the library released. Always
  // runs off the C stack (next feedOwned, the failure path, or release), never
  // from inside a release callback.
  #sweepRetired(): void {
    for (const pin of this.#pinnedFrames) {
      if (pin.retired) {
        pin.release?.close();
        pin.release = null;
        this.#pinnedFrames.delete(pin);
      }
    }
  }

  step(): void {
    check(s.pancake_peer_step(this.#raw));
  }

  /** Publish a local capability behind `swissnum`; returns the export id. */
  registerBootstrapCap(swissnum: Uint8Array): bigint {
    const out = new Uint8Array(8);
    check(s.pancake_peer_register_bootstrap_cap(this.#raw, ab(swissnum), BigInt(swissnum.length), out));
    return new DataView(out.buffer).getBigUint64(0, true);
  }

  /** Queue the canonical bootstrap `fetch` for the capability published
   * behind `name`, returning the answer position the partner's resolution
   * arrives on (as a typed resolve event). Registers the bootstrap import and
   * allocates the answer from the session's own counters. */
  sendBootstrapFetch(name: Uint8Array): bigint {
    const out = new Uint8Array(8);
    check(s.pancake_peer_send_bootstrap_fetch(this.#raw, ab(name), BigInt(name.length), out));
    return new DataView(out.buffer).getBigUint64(0, true);
  }

  /** The codec the session speaks (a `CODEC_*` value), so an opaque `other`
   * frame drained after a typed-poll refusal can be interpreted. */
  codec(): number {
    const out = new Uint8Array(4);
    check(s.pancake_peer_codec(this.#raw, out));
    return new DataView(out.buffer).getUint32(0, true);
  }

  /** Queue an `op:gc-export` releasing wire-delta counts on imports this peer
   * holds: `positions[i]` is released by `deltas[i]`. The arrays are parallel
   * and must be non-empty and the same length. */
  sendGcExport(positions: bigint[], deltas: bigint[]): void {
    if (positions.length !== deltas.length) {
      throw new PancakeError(INVALID_ARGUMENT, "positions and deltas must be the same length");
    }
    const pos = new Uint8Array(8 * positions.length);
    const del = new Uint8Array(8 * deltas.length);
    const posView = new DataView(pos.buffer);
    const delView = new DataView(del.buffer);
    for (let i = 0; i < positions.length; i++) {
      posView.setBigUint64(8 * i, positions[i], true);
      delView.setBigUint64(8 * i, deltas[i], true);
    }
    check(s.pancake_peer_send_gc_export(this.#raw, pos, del, BigInt(positions.length)));
  }

  /** Queue an `op:gc-answer` releasing an answer this peer no longer needs. */
  sendGcAnswer(answer: bigint): void {
    check(s.pancake_peer_send_gc_answer(this.#raw, answer));
  }

  sendDeliver(target: Reference, args: Argument[], answer: bigint | null = null): void {
    const keep: Uint8Array[] = [];
    const t = refStruct(target);
    const argsBuf = encodeArgs(args, keep);
    check(s.pancake_peer_send_deliver(
      this.#raw,
      ab(t),
      args.length ? ab(argsBuf) : new Uint8Array(0),
      BigInt(args.length),
      answer !== null ? 1 : 0,
      answer ?? 0n,
    ));
  }

  sendResolve(answer: bigint, resolution: Resolution): void {
    if ("fulfill" in resolution) {
      const keep: Uint8Array[] = [];
      const buf = encodeArgs([resolution.fulfill], keep);
      check(s.pancake_peer_send_resolve(this.#raw, answer, RESOLUTION_FULFILL, ab(buf), new Uint8Array(0), 0n));
    } else {
      const msg = new TextEncoder().encode(resolution.break);
      check(s.pancake_peer_send_resolve(this.#raw, answer, RESOLUTION_BREAK, new Uint8Array(0), msg, BigInt(msg.length)));
    }
  }

  takeOutbound(): Uint8Array | null {
    const frame = new Uint8Array(40);
    const rc = s.pancake_peer_take_outbound(this.#raw, frame);
    if (rc === WOULD_BLOCK) return null;
    // Any other non-OK code (e.g. an OOM after the frame was dequeued and freed)
    // is a real failure: throw instead of silently dropping an outbound frame
    // and ending the drain as if the queue were empty.
    check(rc);
    const dv = new DataView(frame.buffer);
    const ptr = dv.getBigUint64(0, true);
    const len = dv.getBigUint64(8, true);
    const out = readBytes(ptr, len).slice();
    s.pancake_managed_frame_release(frame);
    return out;
  }

  poll(): Event | null {
    const kind = s.pancake_peer_peek_event(this.#raw);
    if (kind === EVENT_DELIVER) return this.#pollDeliver();
    if (kind === EVENT_RESOLVE) return this.#pollResolve();
    if (kind === WOULD_BLOCK) return null;
    // A negative code is a peek failure (e.g. a released peer), not an event
    // kind; fail closed rather than fabricating an `other` event with kind 0.
    if (kind < 0) throw new PancakeError(kind);
    return this.#pollOther();
  }

  #pollDeliver(): Event {
    const buf = new Uint8Array(56);
    const rc = s.pancake_peer_poll_event_deliver(this.#raw, buf);
    if (rc === UNSUPPORTED_VALUE) {
      // The typed projection cannot carry this deliver (e.g. a handoff
      // argument). The event stays queued, so drain it as an opaque `other` —
      // throwing here would peek the same event forever.
      return this.#pollOther();
    }
    check(rc);
    const dv = new DataView(buf.buffer);
    const view = new Deno.UnsafePointerView(Deno.UnsafePointer.of(buf)!);
    const target = readReference(view, 0);
    const args = readArgArray(dv.getBigUint64(16, true), dv.getBigUint64(24, true));
    const hasAnswer = dv.getUint32(32, true) !== 0;
    const answer = dv.getBigUint64(40, true);
    s.pancake_deliver_release(buf);
    return { kind: "deliver", target, args, answer: hasAnswer ? answer : null };
  }

  #pollResolve(): Event {
    const buf = new Uint8Array(ARG_SIZE + 48);
    const rc = s.pancake_peer_poll_event_resolve(this.#raw, buf);
    if (rc === UNSUPPORTED_VALUE) {
      // Same leave-queued contract as #pollDeliver: drain the refused resolve
      // as an opaque `other` so the loop survives.
      return this.#pollOther();
    }
    check(rc);
    const dv = new DataView(buf.buffer);
    const view = new Deno.UnsafePointerView(Deno.UnsafePointer.of(buf)!);
    const answer = dv.getBigUint64(0, true);
    const resKind = dv.getUint32(8, true);
    let resolution: Resolution;
    if (resKind === RESOLUTION_FULFILL) {
      resolution = { fulfill: readArg(view, 16) };
    } else {
      const ptr = dv.getBigUint64(16 + ARG_SIZE, true);
      const len = dv.getBigUint64(16 + ARG_SIZE + 8, true);
      resolution = { break: new TextDecoder().decode(readBytes(ptr, len)) };
    }
    s.pancake_resolve_release(buf);
    return { kind: "resolve", answer, resolution };
  }

  #pollOther(): Event {
    const buf = new Uint8Array(48);
    check(s.pancake_peer_poll_event(this.#raw, buf));
    const dv = new DataView(buf.buffer);
    const eventKind = dv.getUint32(0, true);
    const ptr = dv.getBigUint64(8, true);
    const len = dv.getBigUint64(16, true);
    const frame = readBytes(ptr, len).slice();
    s.pancake_event_release(buf);
    return { kind: "other", eventKind, frame };
  }
}

// ── Actors ───────────────────────────────────────────────────────────────────

// Goblins-shaped actors over the pancake peer, in native TypeScript. This mirrors
// pancake's Zig actor layer (`src/actors/vat.zig`) and the Goblins-faithful Racket
// binding: one unified `Ref` for a local actor or far partner object, one `Vow`
// for a local result or far wire answer, and a peer-aware `Vat` that routes
// between them.
//
// An actor is a TypeScript callback, not a wrapped C vat. Likewise,
// `AsyncConnection` is Deno networking rather than a foreign reactor. The vat
// holds local actors, each a closure over a method verb and its arguments. When it
// is bound to a peer, it routes eventual-sends to far objects over the wire. A
// leading `Sym` argument is the method verb, matching Goblins's
// `($ obj 'method arg ...)`; the rest are the call's arguments.
//
// Two verbs match Goblins and the Zig actor layer:
//   * `call` is the synchronous near-call (`$`). It runs a local actor's handler
//     immediately and returns its value. A far ref throws; near-call is local only.
//   * `send` is the eventual send (`<-`). It is location-transparent: a local
//     target queues a turn for `drive`, and a far target sends an `op:deliver`
//     over the bound peer with a fresh answer. Either way it returns a `Vow` you
//     observe with `on`.

/** An actor behavior: handle a `(verb, args)` call, returning a reply. Throw to
 * signal a broken resolution; the thrown error's message becomes the break. */
export type Behavior = (verb: string, args: Argument[]) => Argument;

/** A reference the vat can eventual-send to, wherever the object lives. A
 * `LocalRef` names an actor in this vat; a `FarRef` wraps a `far` reference to
 * a partner-hosted object the bound peer holds as an import. */
type VatRef = LocalRef | FarRef;

/** An actor living in this vat. `call` and `send` run its turns here. */
export class LocalRef {
  readonly location = "local" as const;
  constructor(public readonly id: number) {}
}

/** A partner-hosted object the bound peer holds as an import. `send` routes to
 * it as an `op:deliver`; `call` (near) is illegal. */
export class FarRef {
  readonly location = "far" as const;
  constructor(public readonly reference: Reference) {}
}

/** How a vow settled. */
export type Settlement = { fulfilled: Argument } | { broken: string };

/** A one-shot listener on a vow: `onFulfilled` runs with the value on a
 * fulfill, `onBroken` with the message on a break. */
export type VowListener = {
  onFulfilled?: (value: Argument) => void;
  onBroken?: (message: string) => void;
};

/** A handle to the eventual result of a `Vat.send`. A `LocalVow` settles during
 * `drive`; a `FarVow` settles when the peer surfaces the partner's resolution
 * event and the application hands it to `serve`. */
export type Vow = LocalVow | FarVow;

// A vow is awaitable: `await vat.send(...)` resolves with the value, or rejects
// with a typed `VowBroken` carrying the break message. The promise is registered
// lazily, the first time the vow is awaited (or `.then`'d), so a fire-and-forget
// send that no one observes settles into nothing — no stray unhandled rejection.
// `vat.on` is still here for the callback style.
function settle(vat: Vat, vow: Vow): Promise<Argument> {
  return new Promise<Argument>((resolve, reject) => {
    vat.on(vow, (value) => resolve(value), (message) => reject(new VowBroken(message)));
  });
}

/** The result of a local send; settled by `Vat.drive`. Await it for the value,
 * or observe it with `Vat.on`. */
export class LocalVow {
  readonly location = "local" as const;
  constructor(public readonly id: number, private readonly vat: Vat) {}
  then<R1 = Argument, R2 = never>(
    onFulfilled?: ((value: Argument) => R1 | PromiseLike<R1>) | null,
    onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
  ): Promise<R1 | R2> {
    return settle(this.vat, this).then(onFulfilled, onRejected);
  }
}

/** The result of a far send, keyed by the outbound answer position the partner
 * resolves. Await it for the value, or observe it with `Vat.on`. */
export class FarVow {
  readonly location = "far" as const;
  constructor(public readonly answer: bigint, private readonly vat: Vat) {}
  then<R1 = Argument, R2 = never>(
    onFulfilled?: ((value: Argument) => R1 | PromiseLike<R1>) | null,
    onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
  ): Promise<R1 | R2> {
    return settle(this.vat, this).then(onFulfilled, onRejected);
  }
}

/** A turn loop over local and far actors. A pure-local vat (`new Vat()`) drives
 * local actors only; a peer-bound vat (`new Vat(peer)`) also routes far sends
 * over the wire and hosts published actors for inbound delivery via `serve`.
 *
 * The vat owns no I/O and no scheduler; you drive it. Around `serve`, callers
 * feed frames to the peer, step it, take outbound frames, and hand surfaced
 * events back to the vat. */
export class Vat {
  #peer: Peer | null;
  #actors = new Map<number, Behavior>();
  #queue: Array<{ id: number; verb: string; args: Argument[]; vow: number }> = [];
  #localListeners = new Map<number, VowListener>();
  #farListeners = new Map<bigint, VowListener>(); // outbound answer -> listener
  #exports = new Map<bigint, number>(); // export id -> local actor id
  #nextActor = 1;
  #nextVow = 1;

  /** A pure-local vat, or, when given a peer, one that routes far sends and hosts
   * published actors. */
  constructor(peer?: Peer) {
    this.#peer = peer ?? null;
  }

  /** The bound peer, or null for a pure-local vat. */
  get peer(): Peer | null {
    return this.#peer;
  }

  /** Spawn a local actor, returning a `LocalRef`. */
  spawn(behavior: Behavior): LocalRef {
    const id = this.#nextActor++;
    this.#actors.set(id, behavior);
    return new LocalRef(id);
  }

  /** The synchronous near-call (`$`): run `ref`'s handler now and return its
   * value. Legal only for a local ref — a far ref must be reached with `send`.
   * Throws if `ref` names no actor; an actor that throws propagates here. */
  call(ref: VatRef, verb: string, args: Argument[]): Argument {
    if (ref.location === "far") {
      throw new Error("cannot near-call a far ref; use send");
    }
    return this.#callLocal(ref.id, verb, args);
  }

  #callLocal(id: number, verb: string, args: Argument[]): Argument {
    const behavior = this.#actors.get(id);
    if (behavior === undefined) throw new Error(`no such actor: ${id}`);
    return behavior(verb, args);
  }

  /** The eventual send (`<-`): location-transparent. A local target queues a
   * turn for `drive`; a far target sends an `op:deliver` over the bound peer
   * with a fresh answer (a leading symbol carries the verb, matching Goblins's
   * `($ obj 'method …)`). Returns a `Vow` for the result. */
  send(ref: VatRef, verb: string, args: Argument[]): Vow {
    if (ref.location === "local") {
      const vow = this.#nextVow++;
      this.#queue.push({ id: ref.id, verb, args, vow });
      return new LocalVow(vow, this);
    }
    const peer = this.#peer;
    if (peer === null) throw new Error("this vat has no peer; far sends need new Vat(peer)");
    const answer = peer.nextAnswer();
    const payload: Argument[] = verb.length > 0 ? [new Sym(verb), ...args] : args;
    peer.sendDeliver(ref.reference, payload, answer);
    return new FarVow(answer, this);
  }

  /** Register a one-shot listener on `vow`. A local vow fires during `drive`; a
   * far vow fires when `serve` dispatches the matching typed resolve event. */
  on(vow: Vow, onFulfilled?: (value: Argument) => void, onBroken?: (message: string) => void): void {
    const listener: VowListener = { onFulfilled, onBroken };
    if (vow.location === "local") {
      this.#localListeners.set(vow.id, listener);
    } else {
      this.#farListeners.set(vow.answer, listener);
    }
  }

  /** Break every outstanding far vow with `message`, firing each listener's
   * `onBroken`. A far vow settles only when the peer surfaces the partner's
   * resolution, so once the connection is gone those replies can never come.
   * The connection driver calls this on disconnect, so an awaiting `send` rejects
   * instead of hanging forever. Local vows are untouched: they settle
   * synchronously in `drive` and never wait on the wire. */
  breakFarVows(message: string): void {
    // Snapshot then clear before firing: a listener may react by registering
    // another far vow, and mutating the map mid-iteration would lose it.
    const pending = [...this.#farListeners.values()];
    this.#farListeners.clear();
    for (const listener of pending) listener.onBroken?.(message);
  }

  /** Run queued local eventual-sends to quiescence, settling each vow with the
   * handler's value (or a break on a thrown error) and firing its listener.
   * Turns a turn queues run in the same drive (FIFO). */
  drive(): void {
    while (this.#queue.length > 0) {
      const queued = this.#queue.shift()!;
      const settlement = this.#runLocal(queued.id, queued.verb, queued.args);
      this.#settleLocal(queued.vow, settlement);
    }
  }

  #runLocal(id: number, verb: string, args: Argument[]): Settlement {
    try {
      return { fulfilled: this.#callLocal(id, verb, args) };
    } catch (err) {
      return { broken: err instanceof Error ? err.message : String(err) };
    }
  }

  #settleLocal(vowId: number, settlement: Settlement): void {
    const listener = this.#localListeners.get(vowId);
    if (listener === undefined) return;
    this.#localListeners.delete(vowId); // one-shot
    fire(listener, settlement);
  }

  /** Publish a local actor at export position `exportId` so a partner's
   * deliveries to it run the actor (dispatched by `serve`). Requires a bound
   * peer. Returns the published `LocalRef`. */
  publish(exportId: bigint | number, behavior: Behavior): LocalRef {
    const peer = this.#peer;
    if (peer === null) throw new Error("this vat has no peer; publish needs new Vat(peer)");
    const id = BigInt(exportId);
    const ref = this.spawn(behavior);
    peer.registerExport(id);
    this.#exports.set(id, ref.id);
    return ref;
  }

  /** Dispatch one inbound peer event. A deliver to a published export runs its
   * actor (the leading `Sym` is the verb) and resolves the answer; a resolve
   * for a pending far vow fires its listener. Returns whether the event
   * belonged to this vat; `false` means it is not ours and the caller handles
   * it. */
  serve(event: Event): boolean {
    if (event.kind === "deliver") return this.#serveDeliver(event);
    if (event.kind === "resolve") return this.#serveResolve(event);
    return false;
  }

  #serveDeliver(event: Event & { kind: "deliver" }): boolean {
    if (event.target.kind !== "near") return false;
    const actorId = this.#exports.get(event.target.id);
    if (actorId === undefined) return false;

    // A leading symbol is the method verb; the rest are its arguments.
    let verb = "";
    let rest = event.args;
    if (event.args.length > 0 && event.args[0] instanceof Sym) {
      verb = event.args[0].value;
      rest = event.args.slice(1);
    }

    const peer = this.#peer;
    if (event.answer !== null && peer !== null) {
      const settlement = this.#runLocal(actorId, verb, rest);
      if ("fulfilled" in settlement) {
        peer.sendResolve(event.answer, { fulfill: settlement.fulfilled });
      } else {
        peer.sendResolve(event.answer, { break: settlement.broken });
      }
    } else {
      // A deliver-only send still runs the actor for its effects.
      this.#callLocal(actorId, verb, rest);
    }
    return true;
  }

  #serveResolve(event: Event & { kind: "resolve" }): boolean {
    const listener = this.#farListeners.get(event.answer);
    if (listener === undefined) return false;
    this.#farListeners.delete(event.answer); // one-shot
    const settlement: Settlement = "fulfill" in event.resolution
      ? { fulfilled: event.resolution.fulfill }
      : { broken: event.resolution.break };
    fire(listener, settlement);
    return true;
  }
}

function fire(listener: VowListener, settlement: Settlement): void {
  if ("fulfilled" in settlement) {
    listener.onFulfilled?.(settlement.fulfilled);
  } else {
    listener.onBroken?.(settlement.broken);
  }
}

// ── Blocking TCP endpoints ───────────────────────────────────────────────────

function outPointer(buf: Uint8Array): Deno.PointerValue {
  return Deno.UnsafePointer.create(new DataView(buf.buffer).getBigUint64(0, true));
}

/** A blocking TCP endpoint: the `pancake_tcp_*` frame shuttle, one
 * layer below `Connection`. Closed on `close` / `[Symbol.dispose]`. */
export class Endpoint {
  #raw: Deno.PointerValue;
  constructor(raw: Deno.PointerValue) {
    this.#raw = raw;
  }
  close(): void {
    if (this.#raw !== null) {
      s.pancake_tcp_conn_release(this.#raw);
      this.#raw = null;
    }
  }
  [Symbol.dispose](): void {
    this.close();
  }
  /** Block for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF. */
  readFrame(): Uint8Array {
    const mf = new Uint8Array(40);
    check(s.pancake_tcp_conn_read_frame(this.#raw, mf));
    const dv = new DataView(mf.buffer);
    const out = readBytes(dv.getBigUint64(0, true), dv.getBigUint64(8, true)).slice();
    s.pancake_managed_frame_release(mf);
    return out;
  }
  writeFrame(frame: Uint8Array): void {
    const f = new Uint8Array(24);
    const dv = new DataView(f.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(Deno.UnsafePointer.of(ab(frame)))), true);
    dv.setBigUint64(8, BigInt(frame.length), true);
    dv.setUint32(16, FRAME_SHAPE_BYTE, true);
    check(s.pancake_tcp_conn_write_frame(this.#raw, f));
  }
}

/** A bound TCP listener. Closed on `close` / `[Symbol.dispose]`. */
export class Listener {
  #raw: Deno.PointerValue;
  constructor(raw: Deno.PointerValue) {
    this.#raw = raw;
  }
  close(): void {
    if (this.#raw !== null) {
      s.pancake_tcp_listener_release(this.#raw);
      this.#raw = null;
    }
  }
  [Symbol.dispose](): void {
    this.close();
  }
  port(): number {
    const out = new Uint8Array(2);
    check(s.pancake_tcp_listener_port(this.#raw, out));
    return new DataView(out.buffer).getUint16(0, true);
  }
  accept(codec: Codec = "syrup", maxFrameBytes = 4096): Endpoint {
    const out = new Uint8Array(8);
    check(s.pancake_tcp_accept(this.#raw, codecId(codec), BigInt(maxFrameBytes), out));
    return new Endpoint(outPointer(out));
  }
}

/** Owns the blocking-TCP I/O backend; outlives the endpoints made from it. */
export class Netlayer {
  #raw: Deno.PointerValue;
  constructor(raw?: Deno.PointerValue) {
    if (raw !== undefined) {
      this.#raw = raw;
      return;
    }
    const out = new Uint8Array(8);
    check(s.pancake_tcp_netlayer_new(out));
    this.#raw = outPointer(out);
  }

  /** A netlayer whose allocations route through `context`; the context must
   * outlive it and every endpoint made from it. */
  static newIn(context: Context): Netlayer {
    const out = new Uint8Array(8);
    check(s.pancake_tcp_netlayer_new_in(context.pointer, out));
    return new Netlayer(outPointer(out));
  }
  release(): void {
    if (this.#raw !== null) {
      s.pancake_tcp_netlayer_release(this.#raw);
      this.#raw = null;
    }
  }
  [Symbol.dispose](): void {
    this.release();
  }
  listen(host: string, port = 0): Listener {
    const h = new TextEncoder().encode(host);
    const out = new Uint8Array(8);
    check(s.pancake_tcp_listen(this.#raw, h, BigInt(h.length), port, out));
    return new Listener(outPointer(out));
  }
  connect(host: string, port: number, codec: Codec = "syrup", maxFrameBytes = 4096): Endpoint {
    const h = new TextEncoder().encode(host);
    const out = new Uint8Array(8);
    check(s.pancake_tcp_connect(this.#raw, h, BigInt(h.length), port, codecId(codec), BigInt(maxFrameBytes), out));
    return new Endpoint(outPointer(out));
  }
}

// ── iroh transport (separate libpancake_iroh artifact) ──────────────────────
//
// iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
// out of libpancake so the gate stays hermetic and the core stays pure Zig. So
// it ships as its own optional superset library, loaded lazily here: a consumer
// that never touches iroh never needs it built (it needs cargo: `zig build
// iroh-abi`). The frame unit is identical to TCP's — one codec-self-delimited
// CapTP message — so the same `AsyncConnection` pump drives a peer over it; only
// the addressing differs (an endpoint id + direct-address hints, no host:port).

const irohSymbolDefs = {
  pancake_iroh_netlayer_new: { parameters: ["buffer", "usize", "u32", "buffer"], result: "i32" },
  pancake_iroh_netlayer_close: { parameters: ["pointer"], result: "void" },
  pancake_iroh_netlayer_release: { parameters: ["pointer"], result: "void" },
  pancake_iroh_netlayer_node_id: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  pancake_iroh_netlayer_direct_addrs: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  // Blocking sidecar calls: nonblocking FFI so an accept loop or a parked read
  // never stalls the Deno event loop.
  pancake_iroh_netlayer_connect: {
    parameters: ["pointer", "buffer", "usize", "buffer", "usize", "u32", "usize", "buffer"],
    result: "i32",
    nonblocking: true,
  },
  pancake_iroh_netlayer_accept: { parameters: ["pointer", "u32", "usize", "buffer"], result: "i32", nonblocking: true },
  pancake_iroh_conn_read_frame: { parameters: ["pointer", "buffer"], result: "i32", nonblocking: true },
  pancake_iroh_conn_write_frame: { parameters: ["pointer", "buffer"], result: "i32", nonblocking: true },
  pancake_iroh_conn_release: { parameters: ["pointer"], result: "void" },
} as const;

const irohLibFile = Deno.build.os === "darwin"
  ? "libpancake_iroh.dylib"
  : Deno.build.os === "windows"
  ? "pancake_iroh.dll"
  : "libpancake_iroh.so";

let irohSyms: Deno.DynamicLibrary<typeof irohSymbolDefs>["symbols"] | null = null;

// Open the iroh ABI library on first use. It is optional — absent unless built
// with cargo — so a clear error names how to produce it rather than a raw
// dlopen failure.
function irohS(): Deno.DynamicLibrary<typeof irohSymbolDefs>["symbols"] {
  if (irohSyms !== null) return irohSyms;
  const path = new URL(`../../zig-out/lib/${irohLibFile}`, import.meta.url).pathname;
  try {
    irohSyms = Deno.dlopen(path, irohSymbolDefs).symbols;
  } catch (e) {
    throw new Error(
      `iroh transport unavailable: could not load ${irohLibFile} from zig-out/lib. ` +
        "Build it with `zig build iroh-abi` (needs cargo). " +
        (e instanceof Error ? e.message : String(e)),
    );
  }
  return irohSyms;
}

// As `check`, but for iroh ABI calls: the iroh library carries its own
// thread-local last-error, so pass an explicit detail rather than scraping
// libpancake's unrelated one.
function irohCheck(code: number): void {
  if (code !== OK) throw new PancakeError(code, `iroh transport call failed (code ${code})`);
}

function readUsize(buf: Uint8Array): number {
  return Number(new DataView(buf.buffer).getBigUint64(0, true));
}

/** How an iroh endpoint becomes reachable — a required, explicit posture with
 * no default. The caller owns the reach/privacy tradeoff at every constructor:
 * - `Direct`: dial by id + direct-address hints; relay-less, no discovery.
 * - `Discovery`: n0 relays + DNS discovery; dial by id alone.
 * - `DiscoveryNoRelay`: DNS discovery, no relays.
 * - `LocalDiscovery`: in-process address book (tests / same process). */
export enum Reachability {
  Direct = 0,
  Discovery = 1,
  DiscoveryNoRelay = 2,
  LocalDiscovery = 3,
}

/** A bound iroh QUIC endpoint plus the sidecar runtime driving it — the iroh
 * sibling of the TCP `Netlayer`, but it is also its own listener (there is no
 * host:port to bind, so `accept` lives here). Dial a partner by endpoint id +
 * direct-address hints; `accept` blocks for an inbound dial. Release every
 * `IrohConn` it mints before releasing it. */
export class IrohNetlayer {
  #raw: Deno.PointerValue;

  /** Bind an endpoint. `reachability` is required — the caller owns the
   * reach/privacy posture, there is no default. `secretSeed` is a 32-byte
   * Ed25519 secret key for a stable id, or omitted for a fresh random key. */
  constructor(reachability: Reachability, secretSeed?: Uint8Array) {
    if (secretSeed !== undefined && secretSeed.length !== 32) {
      throw new Error("an iroh secret seed must be 32 bytes");
    }
    const seed = secretSeed ?? new Uint8Array(0);
    const out = new Uint8Array(8);
    irohCheck(irohS().pancake_iroh_netlayer_new(ab(seed), BigInt(seed.length), reachability, out));
    this.#raw = outPointer(out);
  }

  /** This endpoint's id — its Ed25519 public key as lowercase hex, the dialable
   * designator a keyed locator signs and a partner passes to `connect`. */
  nodeId(): string {
    const cap = 64;
    const out = new Uint8Array(cap);
    const len = new Uint8Array(8);
    irohCheck(irohS().pancake_iroh_netlayer_node_id(this.#raw, out, BigInt(cap), len));
    return new TextDecoder().decode(out.subarray(0, readUsize(len)));
  }

  /** This endpoint's comma-separated direct socket addresses — the dialing hint
   * a partner needs because the sidecar binds relay-less and lookup-less. Empty
   * when the endpoint has no direct addresses yet. */
  directAddresses(): string {
    const cap = 1024;
    const out = new Uint8Array(cap);
    const len = new Uint8Array(8);
    irohCheck(irohS().pancake_iroh_netlayer_direct_addrs(this.#raw, out, BigInt(cap), len));
    return new TextDecoder().decode(out.subarray(0, readUsize(len)));
  }

  /** Dial a partner by endpoint id (`addrHints` its comma-separated
   * direct-address list) and complete a framed connection. */
  async connect(
    nodeId: string,
    addrHints: string,
    codec: Codec = "syrup",
    maxFrameBytes = 4096,
  ): Promise<IrohConn> {
    const id = new TextEncoder().encode(nodeId);
    const hints = new TextEncoder().encode(addrHints);
    const out = new Uint8Array(8);
    irohCheck(
      await irohS().pancake_iroh_netlayer_connect(
        this.#raw,
        ab(id),
        BigInt(id.length),
        ab(hints),
        BigInt(hints.length),
        codecId(codec),
        BigInt(maxFrameBytes),
        out,
      ),
    );
    return new IrohConn(outPointer(out));
  }

  /** Block until a partner dials this endpoint, returning the framed
   * connection. Rejects when the endpoint is closed (the shutdown lever). */
  async accept(codec: Codec = "syrup", maxFrameBytes = 4096): Promise<IrohConn> {
    const out = new Uint8Array(8);
    irohCheck(await irohS().pancake_iroh_netlayer_accept(this.#raw, codecId(codec), BigInt(maxFrameBytes), out));
    return new IrohConn(outPointer(out));
  }

  /** Close the endpoint without freeing the handle: a parked `accept` rejects
   * and later dials fail. Idempotent — the shutdown lever for an accept loop on
   * its own task. */
  close(): void {
    if (this.#raw !== null) irohS().pancake_iroh_netlayer_close(this.#raw);
  }

  release(): void {
    if (this.#raw !== null) {
      irohS().pancake_iroh_netlayer_release(this.#raw);
      this.#raw = null;
    }
  }

  [Symbol.dispose](): void {
    this.release();
  }
}

/** One iroh QUIC connection carrying one OCapN session, framed on the
 * netlayer's codec — the iroh sibling of the TCP `Endpoint`. */
export class IrohConn {
  #raw: Deno.PointerValue;
  constructor(raw: Deno.PointerValue) {
    this.#raw = raw;
  }

  /** Block for one whole frame; `null` on a clean end of stream. */
  async readFrame(): Promise<Uint8Array | null> {
    const mf = new Uint8Array(40);
    const code = await irohS().pancake_iroh_conn_read_frame(this.#raw, mf);
    if (code === CLOSED) return null;
    irohCheck(code);
    const dv = new DataView(mf.buffer);
    const out = readBytes(dv.getBigUint64(0, true), dv.getBigUint64(8, true)).slice();
    s.pancake_managed_frame_release(mf);
    return out;
  }

  async writeFrame(frame: Uint8Array): Promise<void> {
    const f = new Uint8Array(24);
    const dv = new DataView(f.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(Deno.UnsafePointer.of(ab(frame)))), true);
    dv.setBigUint64(8, BigInt(frame.length), true);
    dv.setUint32(16, FRAME_SHAPE_BYTE, true);
    irohCheck(await irohS().pancake_iroh_conn_write_frame(this.#raw, f));
  }

  release(): void {
    if (this.#raw !== null) {
      irohS().pancake_iroh_conn_release(this.#raw);
      this.#raw = null;
    }
  }
}

// ── Native async I/O over Deno networking ────────────────────────────────────

const READ_CHUNK = 64 * 1024;

/** Write every byte of `data` to `conn`; `conn.write` may write partially. */
async function writeAll(conn: Deno.Conn, data: Uint8Array): Promise<void> {
  let off = 0;
  while (off < data.length) {
    off += await conn.write(data.subarray(off));
  }
}

/** The locator a keyed `op:start-session` signs for a transport. A dialer signs
 * an empty designator (its identity is the random session key); a listener signs
 * its own dialable designator. */
interface KeyedLocator {
  transport: string;
  designator: string;
  hintsEmptyFalse?: boolean;
}

/** What the `AsyncConnection` pump needs of a transport. A frame is one
 * complete, codec-self-delimited CapTP message — the same unit `Peer.takeOutbound`
 * yields and `Peer.feed`/`recvStream` consume — so a transport differs only in
 * how it moves that unit, never in the pump that drives the peer over it. TCP
 * buffers raw bytes and lets the peer frame them; iroh sources whole frames
 * through the sidecar FFI. */
interface FramePump {
  /** The locator a keyed `op:start-session` signs for this transport. */
  locator(): KeyedLocator;
  /** Dispatch one already-buffered inbound frame into `peer` without blocking;
   * true when one was dispatched (the caller loops). A stream transport frames
   * its byte buffer here; a transport that delivers exactly one frame per
   * `receive` returns false. */
  dispatchBuffered(peer: Peer): boolean;
  /** Block for more inbound and dispatch it into `peer`; resolve false on a
   * clean end of stream. */
  receive(peer: Peer): Promise<boolean>;
  /** Write one whole outbound frame to the wire. */
  writeFrame(frame: Uint8Array): Promise<void>;
  close(): void;
}

/** The TCP pump: a raw `Deno.Conn` plus the inbound byte buffer the peer frames.
 * The keyed locator signs the socket's own `host:port`, which a Goblins partner
 * accepts as a true `tcp` locator. */
class TcpPump implements FramePump {
  #conn: Deno.Conn;
  // Inbound bytes read from the wire but not yet framed into whole frames.
  #inbox: Uint8Array = new Uint8Array(0);

  constructor(conn: Deno.Conn) {
    this.#conn = conn;
  }

  locator(): KeyedLocator {
    const la = this.#conn.localAddr as Deno.NetAddr;
    return { transport: "tcp", designator: `${la.hostname}:${la.port}`, hintsEmptyFalse: true };
  }

  dispatchBuffered(peer: Peer): boolean {
    if (this.#inbox.length === 0) return false;
    const consumed = peer.recvStream(this.#inbox);
    if (consumed === null) return false;
    this.#inbox = this.#inbox.subarray(consumed);
    return true;
  }

  async receive(_peer: Peer): Promise<boolean> {
    const chunk = new Uint8Array(READ_CHUNK);
    const n = await this.#conn.read(chunk);
    if (n === null) return false; // clean EOF
    this.#appendInbox(chunk.subarray(0, n));
    return true;
  }

  async writeFrame(frame: Uint8Array): Promise<void> {
    await writeAll(this.#conn, frame);
  }

  #appendInbox(bytes: Uint8Array): void {
    if (this.#inbox.length === 0) {
      // Copy out of the read buffer so the next read can reuse `chunk`.
      this.#inbox = bytes.slice();
      return;
    }
    const grown = new Uint8Array(this.#inbox.length + bytes.length);
    grown.set(this.#inbox, 0);
    grown.set(bytes, this.#inbox.length);
    this.#inbox = grown;
  }

  close(): void {
    try {
      this.#conn.close();
    } catch {
      // Already closed.
    }
  }
}

/** The iroh pump: an `IrohConn` that delivers and accepts whole frames through
 * the sidecar FFI. The keyed locator signs the `iroh` transport with the local
 * endpoint id as designator (empty for a dialer, matching the Zig driver). When
 * this pump minted its own dialing netlayer, it owns that netlayer's lifetime
 * too; an accepted connection's netlayer belongs to the `IrohServer`. */
class IrohPump implements FramePump {
  #conn: IrohConn;
  #designator: string;
  #ownedNetlayer: IrohNetlayer | null;

  constructor(conn: IrohConn, designator: string, ownedNetlayer: IrohNetlayer | null = null) {
    this.#conn = conn;
    this.#designator = designator;
    this.#ownedNetlayer = ownedNetlayer;
  }

  locator(): KeyedLocator {
    return { transport: "iroh", designator: this.#designator, hintsEmptyFalse: true };
  }

  dispatchBuffered(_peer: Peer): boolean {
    // Each `receive` reads exactly one whole frame, so nothing is ever buffered
    // ahead.
    return false;
  }

  async receive(peer: Peer): Promise<boolean> {
    const frame = await this.#conn.readFrame();
    if (frame === null) return false; // clean EOF
    peer.feed(frame);
    return true;
  }

  async writeFrame(frame: Uint8Array): Promise<void> {
    await this.#conn.writeFrame(frame);
  }

  close(): void {
    this.#conn.release();
    this.#ownedNetlayer?.release();
  }
}

/** An OCapN/CapTP peer driven asynchronously over a transport `FramePump`.
 *
 * The sync `Peer` is sans-io: it never blocks and never owns a socket. This
 * class owns one peer and one pump and drives the peer over it — sources whole
 * frames (or raw bytes the peer frames), lets the peer dispatch them, writes the
 * peer's outbound frames back, and surfaces typed events. The pump is the only
 * thing that differs between transports (TCP today, iroh through the sidecar);
 * the drive loop is identical. One `AsyncConnection` owns one peer, so it lives
 * on one task; the peer is a single-owner state machine, never shared across
 * tasks. This is the pump layer `Connection` builds on; an application usually
 * holds a `Connection`. */
export class AsyncConnection {
  #peer: Peer;
  #pump: FramePump;
  #vat: Vat | null = null;

  private constructor(peer: Peer, pump: FramePump) {
    this.#peer = peer;
    this.#pump = pump;
  }

  /** Connect to `hostname:port` and complete the keyed OCapN handshake. */
  static async connect(hostname: string, port: number): Promise<AsyncConnection> {
    const conn = await Deno.connect({ hostname, port });
    const ac = new AsyncConnection(new Peer(), new TcpPump(conn));
    await openKeyedSession(ac);
    return ac;
  }

  /** Wrap an already-connected conn and a peer you have configured (registered
   * exports/imports, bootstrap caps, …). */
  static fromConn(peer: Peer, conn: Deno.Conn): AsyncConnection {
    return new AsyncConnection(peer, new TcpPump(conn));
  }

  /** Wrap a peer and an already-built frame pump — the transport-neutral
   * constructor the iroh path uses. */
  static fromPump(peer: Peer, pump: FramePump): AsyncConnection {
    return new AsyncConnection(peer, pump);
  }

  /** The locator this connection's transport signs in its keyed start-session. */
  get locator(): KeyedLocator {
    return this.#pump.locator();
  }

  /** Borrow the owned peer — e.g. to register exports/imports before driving. */
  get peer(): Peer {
    return this.#peer;
  }

  /** A `Vat` bound to this connection's peer, created once and cached. This is
   * how you drive actors over the wire: `publish` an actor to host it, `send` to
   * a `FarRef` to call a remote object, and hand each event from `nextEvent` to
   * `vat.serve`. The vat enqueues on the peer; `nextEvent` and `flush` move the
   * bytes. */
  vat(): Vat {
    if (this.#vat === null) this.#vat = new Vat(this.#peer);
    return this.#vat;
  }

  /** Queue a call to `target` and flush it to the wire. `answer` requests a reply. */
  async sendDeliver(target: Reference, args: Argument[], answer: bigint | null = null): Promise<void> {
    this.#peer.sendDeliver(target, args, answer);
    await this.#pumpOutbound();
  }

  /** Queue a reply settling `answer` and flush it to the wire. */
  async sendResolve(answer: bigint, resolution: Resolution): Promise<void> {
    this.#peer.sendResolve(answer, resolution);
    await this.#pumpOutbound();
  }

  /** Flush whatever is already queued on the peer's outbound to the wire.
   *
   * The peer is sans-io: a `Vat.send` (or any direct `peer.sendDeliver` /
   * `sendResolve`) only enqueues; the bytes leave only when something pumps the
   * peer. `nextEvent` pumps at the top of its loop, so a reply queued while
   * serving an inbound event leaves on the next turn. But work a *different*
   * task queues onto this peer — a server pushing a broadcast to a subscriber
   * whose own task is parked in `read()` — would otherwise sit unsent until that
   * task happened to wake. Call `flush` right after such a cross-task `Vat.send`
   * to put the bytes on the wire now. */
  async flush(): Promise<void> {
    await this.#pumpOutbound();
  }

  /** The connection as a native stream of events: `for await (const event of
   * conn) …`. It yields each event the peer surfaces and ends on a clean
   * disconnect, so the idiomatic receive loop is just a `for await`. (It is the
   * same thing as looping on `nextEvent` until it returns null.) */
  async *[Symbol.asyncIterator](): AsyncGenerator<Event> {
    let event = await this.nextEvent();
    while (event !== null) {
      yield event;
      event = await this.nextEvent();
    }
  }

  /** Await the next application event, driving the transport as needed. Returns
   * `null` on a clean end of stream. */
  async nextEvent(): Promise<Event | null> {
    for (;;) {
      // A surfaced event takes priority.
      const ev = this.#peer.poll();
      if (ev) return ev;
      // Flush anything the last dispatch queued (replies, aborts).
      await this.#pumpOutbound();
      // Dispatch every whole frame already buffered; each may surface an event
      // or queue outbound, so loop back to re-check.
      if (this.#pump.dispatchBuffered(this.#peer)) continue;
      // Block for more inbound; a clean end of stream ends the loop.
      if (!(await this.#pump.receive(this.#peer))) return null;
    }
  }

  /** Drive the keyed handshake without consuming application events. */
  async driveUntilSessionOpen(): Promise<void> {
    while (!this.#peer.sessionIsOpen()) {
      await this.#pumpOutbound();
      while (this.#pump.dispatchBuffered(this.#peer)) {
        if (this.#peer.sessionIsOpen()) return;
      }
      if (this.#peer.sessionIsOpen()) return;
      if (!(await this.#pump.receive(this.#peer))) {
        throw new Error("connection closed during the OCapN handshake");
      }
    }
  }

  // Encode pending outbound work and write every queued frame to the wire.
  async #pumpOutbound(): Promise<void> {
    this.#peer.step();
    let f: Uint8Array | null;
    while ((f = this.#peer.takeOutbound()) !== null) {
      await this.#pump.writeFrame(f);
    }
  }

  close(): void {
    this.#pump.close();
    this.#peer.release();
  }

  [Symbol.asyncDispose](): Promise<void> {
    this.close();
    return Promise.resolve();
  }
}

// ── Connection: the application surface ──────────────────────────────────────
//
// This is what an application holds. It composes a peer, a vat, and the async
// I/O driver into one object, so a consumer never stitches those three together
// by hand. The verbs — `connect`/`listen`, `fetch`/`publish`, `spawn`,
// `send`, `tell`, `serve`, `close` — are the whole common surface. The raw `Peer`,
// `Vat`, and `AsyncConnection` are still here for power users (reach `conn.peer`
// for handoff/pipeline/session control), but no application needs them.

/** A capability — a reference to an object you can `send` to, wherever it lives.
 *
 * You get a `Ref` two ways: `conn.spawn(behavior)` (a local actor you host) or
 * `conn.fetch(name)` (a capability a partner published). A `Ref` is opaque: pass
 * it as an argument to `send` and it marshals to the right wire reference
 * automatically. You never construct `near`/`far` references by hand. */
export class Ref {
  constructor(
    /** The wire reference this marshals to when passed as a `send` argument. */
    readonly reference: Reference,
    /** The local actor id, if this `Ref` names an actor we host; else null. */
    readonly localActorId: number | null = null,
  ) {}
}

/** A value an application sends or receives: any OCapN `Argument`, a capability
 * `Ref`, or a list of those. The binding marshals `Ref`s to/from wire references
 * at the boundary, so applications work with capabilities as ordinary values. */
export type AppValue =
  | bigint
  | number
  | boolean
  | Uint8Array
  | string
  | Sym
  | Kw
  | null
  | Ref
  | AppValue[]
  | PSet
  | Tagged;

// Lower an application value to the wire vocabulary: a `Ref` becomes its
// underlying `Reference`; everything else passes through, recursing into
// lists, set items, and a tagged record's value so a capability nested in any
// of them marshals.
function lowerArg(arg: AppValue): Argument {
  if (arg instanceof Ref) return arg.reference;
  if (Array.isArray(arg)) return arg.map(lowerArg);
  if (arg instanceof PSet) return new PSet((arg.items as AppValue[]).map(lowerArg));
  if (arg instanceof Tagged) return new Tagged(arg.tag, (arg.value as AppValue[]).map(lowerArg));
  return arg;
}

// Lift a decoded argument to the application vocabulary: a wire `Reference`
// becomes a `Ref` the app can `send` to or pass on; lists, set items, and a
// tagged record's value recurse, so a capability arrives as a `Ref` wherever
// it is nested.
function liftArg(arg: Argument): AppValue {
  if (isReference(arg)) return new Ref(arg);
  if (Array.isArray(arg)) return arg.map(liftArg);
  if (arg instanceof PSet) return new PSet(arg.items.map(liftArg) as Argument[]);
  if (arg instanceof Tagged) return new Tagged(arg.tag, arg.value.map(liftArg) as Argument[]);
  return arg;
}

/** An actor: handle a `(verb, args)` call and return a reply. `args` may contain
 * `Ref`s (capabilities you were handed). Throw to break the caller's promise. */
export type Actor = (verb: string, args: AppValue[]) => AppValue | void;

// Complete the keyed `op:start-session` handshake over a negotiating peer: sign
// the transport's own locator (with a per-connection random session key), flush
// it, and pump until the partner's start-session opens the session. Entropy is
// generated here, at the I/O boundary, never in the sans-io core. The locator is
// what a partner verifies; the pump provides it — a true `tcp` host:port a
// Goblins partner accepts, or an `iroh` endpoint id.
async function openKeyedSession(ac: AsyncConnection): Promise<void> {
  const loc = ac.locator;
  const seed = crypto.getRandomValues(new Uint8Array(32));
  ac.peer.startSession({
    transport: loc.transport,
    designator: loc.designator,
    seed,
    hintsEmptyFalse: loc.hintsEmptyFalse ?? true,
  });
  await ac.flush();
  await ac.driveUntilSessionOpen();
}

/** A live connection to one OCapN partner — the one object an application holds.
 *
 *   const conn = await connect("127.0.0.1", 9099);
 *   conn.serve().catch((e) => console.error(e));
 *   const room = await conn.fetch("room");
 *   const inbox = conn.spawn((verb, args) => { ...; });
 *   await conn.send(room, "subscribe", ["alice", inbox]);
 */
export class Connection {
  #ac: AsyncConnection;
  #vat: Vat;
  #serving: Promise<void> | null = null;
  #closing = false;

  private constructor(ac: AsyncConnection) {
    this.#ac = ac;
    this.#vat = ac.vat();
  }

  /** Dial `host:port`, complete the keyed OCapN handshake, and return a ready
   * connection. The session is open (the `op:start-session` exchange has
   * completed) before this resolves, so a `fetch`/`send` rides an established
   * session — the same handshake a real Goblins peer requires. (TCP today; a
   * future transport is a constructor option, never a different `Connection`
   * type.) */
  static async connect(host: string, port: number): Promise<Connection> {
    const tcp = await Deno.connect({ hostname: host, port });
    const ac = AsyncConnection.fromConn(new Peer(), tcp);
    await openKeyedSession(ac);
    return new Connection(ac);
  }

  /** Wrap a socket a server already accepted and complete the keyed handshake
   * from the responder side (used by `listen`). Resolves once the session is
   * open. */
  static async accept(tcp: Deno.Conn): Promise<Connection> {
    const ac = AsyncConnection.fromConn(new Peer(), tcp);
    await openKeyedSession(ac);
    return new Connection(ac);
  }

  /** Dial an iroh partner by endpoint id and direct-address hints, complete the
   * keyed OCapN handshake over the encrypted-QUIC transport, and return a ready
   * connection — the iroh sibling of `connect`. The local endpoint is ephemeral
   * (a fresh key) and released with the connection. `reachability` is required —
   * the caller owns the dialer's reach posture, there is no default. Needs the
   * iroh ABI library (`zig build iroh-abi`). */
  static async connectIroh(
    nodeId: string,
    directAddresses: string,
    reachability: Reachability,
  ): Promise<Connection> {
    const netlayer = new IrohNetlayer(reachability);
    let conn: IrohConn;
    try {
      conn = await netlayer.connect(nodeId, directAddresses);
    } catch (e) {
      netlayer.release();
      throw e;
    }
    // A dialer signs an empty designator (its identity is the session key),
    // matching the Zig driver; the pump owns the ephemeral netlayer's lifetime.
    const ac = AsyncConnection.fromPump(new Peer(), new IrohPump(conn, "", netlayer));
    await openKeyedSession(ac);
    return new Connection(ac);
  }

  /** Complete the responder handshake over an accepted iroh connection, signing
   * the server's endpoint id as the locator designator (used by `IrohServer`).
   * The accepted connection's netlayer belongs to the server, not this
   * connection. */
  static async acceptIroh(conn: IrohConn, localNodeId: string): Promise<Connection> {
    const ac = AsyncConnection.fromPump(new Peer(), new IrohPump(conn, localNodeId));
    await openKeyedSession(ac);
    return new Connection(ac);
  }

  /** The underlying sans-io peer — the escape hatch for handoff, pipelining, and
   * session control. Applications do not need it. */
  get peer(): Peer {
    return this.#ac.peer;
  }

  /** Spawn a local actor and return a capability to it. The `Ref` auto-marshals
   * when passed as a `send` argument, so handing a partner a callback is just
   * `send(target, verb, [..., conn.spawn(behavior)])`. The position comes from
   * the session's one export allocator, so it can never alias a bootstrap or
   * resolver export. */
  spawn(behavior: Actor): Ref {
    const position = this.#ac.peer.nextExport();
    const local = this.#vat.publish(position, this.#wrap(behavior));
    return new Ref(near(position), local.id);
  }

  /** Publish an actor so a partner can `fetch` it by `name`. The name is a
   * swiss-number: a readable string for a discoverable service, a cryptographic
   * secret where the name itself is the authorization. */
  publish(name: string, behavior: Actor): Ref {
    const swiss = new TextEncoder().encode(name);
    const position = this.#ac.peer.registerBootstrapCap(swiss);
    const local = this.#vat.publish(position, this.#wrap(behavior));
    return new Ref(near(position), local.id);
  }

  /** Fetch a partner's published capability by `name`. Returns a `Ref` you can
   * `send` to. Drives the inbound loop itself, so a `fetch` straight after
   * `connect` works without a separate `serve()` call (which stays the way to
   * keep serving until close). Rejects with `VowBroken` when the partner
   * breaks the fetch, and with `FetchFailed` when it fulfills with something
   * that is not a capability. */
  async fetch(name: string): Promise<Ref> {
    this.serve(); // idempotent; the resolution arrives on the inbound loop
    // The canonical fetch lives in the library: one call registers the
    // bootstrap import, allocates the answer, and queues the deliver.
    const answer = this.#ac.peer.sendBootstrapFetch(new TextEncoder().encode(name));
    // Subscribe before flushing: the resolution can land on the serve loop the
    // instant `flush` yields the event loop.
    const settled = settle(this.#vat, new FarVow(answer, this.#vat));
    await this.#ac.flush();
    const result = await settled;
    if (!isReference(result)) {
      throw new FetchFailed(name);
    }
    return new Ref(result, null);
  }

  /** Call `verb(args)` on the capability `target` and await the reply. Flushes
   * the call to the wire immediately. `args` may contain `Ref`s. The returned
   * promise resolves with the reply (a `Ref` if the partner returned a
   * capability) or rejects with `VowBroken` if the partner breaks it. */
  async send(target: Ref, verb: string, args: AppValue[] = []): Promise<AppValue> {
    const wireArgs = args.map(lowerArg);
    const vatTarget: VatRef = target.localActorId !== null
      ? new LocalRef(target.localActorId)
      : new FarRef(target.reference);
    if (!(vatTarget instanceof LocalRef)) this.serve(); // far reply arrives on the inbound loop
    const vow = this.#vat.send(vatTarget, verb, wireArgs);
    // Register the listener before any pump: a local `drive` settles the vow
    // synchronously, and a far reply can arrive on the serve loop the instant
    // `flush` yields — either would fire before a later `await` could subscribe.
    const result = settle(this.#vat, vow);
    if (vatTarget instanceof LocalRef) this.#vat.drive();
    else await this.#ac.flush();
    return liftArg(await result);
  }

  /** Send `verb(args)` to `target` without awaiting a reply — the fire-and-forget
   * eventual-send (Goblins `<-np`). No answer is allocated and none comes back,
   * so it is the right call for a notification or a broadcast: it costs one
   * deliver, not a deliver plus a reply. Flushes immediately. */
  async tell(target: Ref, verb: string, args: AppValue[] = []): Promise<void> {
    if (target.localActorId !== null) {
      this.#vat.send(new LocalRef(target.localActorId), verb, args.map(lowerArg));
      this.#vat.drive();
      return;
    }
    const payload: Argument[] = verb.length > 0
      ? [new Sym(verb), ...args.map(lowerArg)]
      : args.map(lowerArg);
    this.#ac.peer.sendDeliver(target.reference, payload, null);
    await this.#ac.flush();
  }

  /** Run the inbound event loop: dispatch each arriving call to the published or
   * spawned actor it targets, and settle the promises of `send`s awaiting a
   * reply. Resolves when the connection closes cleanly; rejects on a transport
   * or protocol error. Started once; calling again returns the same promise. */
  serve(): Promise<void> {
    if (this.#serving === null) this.#serving = this.#serveLoop();
    return this.#serving;
  }

  /** Close the connection. A running `serve()` resolves cleanly. */
  close(): void {
    this.#closing = true;
    this.#ac.close();
  }

  [Symbol.dispose](): void {
    this.close();
  }

  // Drive inbound events to quiescence. A read cancelled by our own `close()` is
  // a clean shutdown (resolve); any other failure is a real fault (reject), so a
  // caller's `serve().catch(...)` sees genuine connection loss and nothing else.
  // Either way the wire is gone when the loop ends, so break any `send` still
  // awaiting a reply rather than leaving its promise pending forever.
  async #serveLoop(): Promise<void> {
    try {
      for await (const event of this.#ac) {
        this.#vat.serve(event);
      }
    } catch (err) {
      if (!this.#closing) throw err;
    } finally {
      this.#vat.breakFarVows("connection closed");
    }
  }

  // Wrap an application actor so the vat sees a raw `Behavior`: lift incoming
  // reference args to `Ref`s, lower a returned `Ref` to its wire reference, and
  // normalize a `void` return to `null` (a bare ack).
  #wrap(behavior: Actor): Behavior {
    return (verb: string, rawArgs: Argument[]): Argument => {
      const result = behavior(verb, rawArgs.map(liftArg));
      return result === undefined || result === null ? null : lowerArg(result);
    };
  }
}

/** A listening server. Iterate it for an accepted `Connection` per partner —
 * `for await (const conn of listen(host, port)) { ... }` — and read `port` for
 * the bound port (useful when you pass port 0 for an ephemeral one). */
export class Server {
  #listener: Deno.Listener;

  constructor(listener: Deno.Listener) {
    this.#listener = listener;
  }

  /** The bound TCP port. */
  get port(): number {
    return (this.#listener.addr as Deno.NetAddr).port;
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<Connection> {
    for await (const tcp of this.#listener) {
      // A handshake failure belongs to that one connection — a client that
      // dialed and died, or a stray port probe. Throwing here would end the
      // iteration, and ending a Deno.Listener's iteration closes the listener,
      // so one rude caller would take the whole server down. Skip it instead;
      // the listener keeps accepting.
      let conn: Connection;
      try {
        conn = await Connection.accept(tcp);
      } catch {
        continue;
      }
      yield conn;
    }
  }

  /** Stop accepting new connections. */
  close(): void {
    this.#listener.close();
  }
}

/** Accept connections on `host:port`, returning a `Server` you iterate for each
 * accepted `Connection`. */
export function listen(host: string, port: number): Server {
  return new Server(Deno.listen({ hostname: host, port }));
}

/** Dial `host:port` and return a ready connection — the module-level shorthand
 * for `Connection.connect`. */
export function connect(host: string, port: number): Promise<Connection> {
  return Connection.connect(host, port);
}

// ── OCapN locator URIs ───────────────────────────────────────────────────────
//
// The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
// vocabulary, defined once in libpancake's `pancake_uri_*` / `pancake_locator_*`
// surface (so no binding hand-rolls a percent codec). These helpers wrap that
// FFI: parse copies every borrowed view into JS strings before releasing the
// handle, and format renders through the same grammar.

/** A parsed OCapN locator: the structured fields a `pancake_uri_parse_*` yields. */
export interface Locator {
  transport: string;
  designator: string;
  /** Empty for a peer URI; the swiss bytes for a sturdyref. */
  swissnum: string;
  hints: Map<string, string>;
}

// Read a (pointer, length) view pair the locator accessors fill, decoding the
// borrowed bytes into a JS string. A zero length (or NULL pointer) is "".
function readLocatorView(ptrBuf: Uint8Array<ArrayBuffer>, lenBuf: Uint8Array<ArrayBuffer>): string {
  const len = Number(new DataView(lenBuf.buffer).getBigUint64(0, true));
  if (len === 0) return "";
  const ptr = Deno.UnsafePointer.create(new DataView(ptrBuf.buffer).getBigUint64(0, true));
  if (ptr === null) return "";
  return new TextDecoder().decode(new Uint8Array(new Deno.UnsafePointerView(ptr).getArrayBuffer(len)));
}

function readLocatorField(
  fn: (loc: Deno.PointerValue, p: Uint8Array<ArrayBuffer>, l: Uint8Array<ArrayBuffer>) => number,
  loc: Deno.PointerValue,
): string {
  const ptrBuf = new Uint8Array(8), lenBuf = new Uint8Array(8);
  check(fn(loc, ab(ptrBuf), ab(lenBuf)));
  return readLocatorView(ptrBuf, lenBuf);
}

/** Parse an `ocapn://` URI into its structured locator fields. `sturdyref`
 * selects the `/s/<swiss>` grammar; the default reads a peer URI (empty
 * swissnum). Throws `PancakeError` for a malformed URI. */
export function parseLocator(uri: string, sturdyref = false): Locator {
  const uriBytes = new TextEncoder().encode(uri);
  const outLoc = new Uint8Array(8);
  const rc = sturdyref
    ? s.pancake_uri_parse_sturdyref(ab(uriBytes), BigInt(uriBytes.length), ab(outLoc))
    : s.pancake_uri_parse_peer(ab(uriBytes), BigInt(uriBytes.length), ab(outLoc));
  check(rc);
  const loc = Deno.UnsafePointer.create(new DataView(outLoc.buffer).getBigUint64(0, true));
  if (loc === null) throw new PancakeError(INVALID_ARGUMENT, `uri parse returned no locator: ${uri}`);
  try {
    const hints = new Map<string, string>();
    const countBuf = new Uint8Array(8);
    check(s.pancake_locator_hint_count(loc, ab(countBuf)));
    const count = Number(new DataView(countBuf.buffer).getBigUint64(0, true));
    for (let i = 0; i < count; i++) {
      const kPtr = new Uint8Array(8), kLen = new Uint8Array(8), vPtr = new Uint8Array(8), vLen = new Uint8Array(8);
      check(s.pancake_locator_hint_at(loc, BigInt(i), ab(kPtr), ab(kLen), ab(vPtr), ab(vLen)));
      hints.set(readLocatorView(kPtr, kLen), readLocatorView(vPtr, vLen));
    }
    return {
      transport: readLocatorField(s.pancake_locator_transport, loc),
      designator: readLocatorField(s.pancake_locator_designator, loc),
      swissnum: readLocatorField(s.pancake_locator_swissnum, loc),
      hints,
    };
  } finally {
    s.pancake_locator_release(loc);
  }
}

/** Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
 * through the core grammar. */
export function formatPeerUri(transport: string, designator: string, hints: Map<string, string> = new Map()): string {
  const enc = new TextEncoder();
  const t = enc.encode(transport), d = enc.encode(designator);
  const keys: Uint8Array<ArrayBuffer>[] = [], vals: Uint8Array<ArrayBuffer>[] = [];
  for (const [k, v] of hints) {
    keys.push(enc.encode(k));
    vals.push(enc.encode(v));
  }
  const keyPtrs = pointerArray(keys), keyLens = lengthArray(keys);
  const valPtrs = pointerArray(vals), valLens = lengthArray(vals);

  // Size with a generous buffer; the call reports the exact length, so a
  // too-small buffer is retried at the reported size.
  let cap = 256;
  for (let attempt = 0; attempt < 2; attempt++) {
    const out = new Uint8Array(cap), outLen = new Uint8Array(8);
    const rc = s.pancake_uri_format_peer(
      ab(t), BigInt(t.length), ab(d), BigInt(d.length),
      keyPtrs, keyLens, valPtrs, valLens, BigInt(keys.length),
      ab(out), BigInt(cap), ab(outLen),
    );
    const need = Number(new DataView(outLen.buffer).getBigUint64(0, true));
    if (rc === OK) return new TextDecoder().decode(out.subarray(0, need));
    if (rc === INVALID_ARGUMENT && need > cap) {
      cap = need;
      continue;
    }
    check(rc);
  }
  throw new PancakeError(INVALID_ARGUMENT, `formatPeerUri: could not size buffer for ${transport}/${designator}`);
}

// Build a `const uint8_t **` array of pointers into the given byte buffers, and
// the parallel `const size_t *` length array, for the format FFI. The buffers
// must outlive the call (they do — they are locals of the caller above).
function pointerArray(bufs: Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
  const arr = new BigUint64Array(bufs.length);
  for (let i = 0; i < bufs.length; i++) {
    const ptr = Deno.UnsafePointer.of(bufs[i]);
    arr[i] = ptr === null ? 0n : Deno.UnsafePointer.value(ptr);
  }
  return new Uint8Array(arr.buffer) as Uint8Array<ArrayBuffer>;
}

function lengthArray(bufs: Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
  const arr = new BigUint64Array(bufs.length);
  for (let i = 0; i < bufs.length; i++) arr[i] = BigInt(bufs[i].length);
  return new Uint8Array(arr.buffer) as Uint8Array<ArrayBuffer>;
}

// ── iroh addressing + server ─────────────────────────────────────────────────

/** A listening iroh endpoint. Iterate it for an accepted `Connection` per
 * partner — `for await (const conn of listenIroh()) { ... }` — and read `uri`
 * for the dialable address (endpoint id + direct-address hints) to hand a
 * client. The iroh sibling of `Server`. */
export class IrohServer {
  #netlayer: IrohNetlayer;
  #closed = false;
  #nodeId: string;

  constructor(netlayer: IrohNetlayer) {
    this.#netlayer = netlayer;
    this.#nodeId = netlayer.nodeId();
  }

  /** This endpoint's id — the keyed locator designator and the URI host. */
  get nodeId(): string {
    return this.#nodeId;
  }

  /** This endpoint's comma-separated direct-address hints. */
  get directAddresses(): string {
    return this.#netlayer.directAddresses();
  }

  /** The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials. */
  get uri(): string {
    const hints = new Map<string, string>();
    if (this.directAddresses.length > 0) hints.set("direct-addresses", this.directAddresses);
    return formatPeerUri("iroh", this.#nodeId, hints);
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<Connection> {
    while (!this.#closed) {
      let conn: IrohConn;
      try {
        conn = await this.#netlayer.accept();
      } catch (e) {
        // `close()` rejects a parked accept; that is a clean shutdown.
        if (this.#closed) return;
        throw e;
      }
      // A handshake failure belongs to that one connection (a partner that
      // dialed and died), never the server — release it and keep accepting.
      let connection: Connection;
      try {
        connection = await Connection.acceptIroh(conn, this.#nodeId);
      } catch {
        conn.release();
        continue;
      }
      yield connection;
    }
  }

  /** Stop accepting and release the endpoint. */
  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#netlayer.close();
    this.#netlayer.release();
  }

  [Symbol.dispose](): void {
    this.close();
  }
}

/** Bind an iroh endpoint and return an `IrohServer` you iterate for each
 * accepted `Connection`. `reachability` is required — the caller owns the reach
 * posture, there is no default. `secretSeed` is a 32-byte Ed25519 secret key
 * for a stable endpoint id, or omitted for a fresh random one. Needs the iroh
 * ABI library (`zig build iroh-abi`). */
export function listenIroh(reachability: Reachability, secretSeed?: Uint8Array): IrohServer {
  return new IrohServer(new IrohNetlayer(reachability, secretSeed));
}

/** Dial an iroh partner by endpoint id and direct-address hints — the
 * module-level shorthand for `Connection.connectIroh`. `reachability` is
 * required; the caller owns the dialer's reach posture, there is no default. */
export function connectIroh(
  nodeId: string,
  directAddresses: string,
  reachability: Reachability,
): Promise<Connection> {
  return Connection.connectIroh(nodeId, directAddresses, reachability);
}

/** Dial a partner from its published `ocapn://` URI, dispatching on the
 * locator's transport: `iroh` dials the endpoint id with its `direct-addresses`
 * hints, `tcp` dials the `host:port` designator. The transport-agnostic entry
 * point; a binding parses once and the core grammar decides the netlayer. An
 * `iroh` URI requires `reachability` — the caller owns the dialer's reach
 * posture, there is no default — and rejects the dial when it is absent. */
export function connectUri(uri: string, reachability?: Reachability): Promise<Connection> {
  const loc = parseLocator(uri);
  switch (loc.transport) {
    case "iroh": {
      if (reachability === undefined) {
        throw new PancakeError(INVALID_ARGUMENT, "connectUri: an iroh URI requires an explicit reachability");
      }
      return Connection.connectIroh(loc.designator, loc.hints.get("direct-addresses") ?? "", reachability);
    }
    case "tcp": {
      const colon = loc.designator.lastIndexOf(":");
      if (colon < 0) {
        throw new PancakeError(INVALID_ARGUMENT, `tcp locator designator is not host:port: ${loc.designator}`);
      }
      return Connection.connect(loc.designator.slice(0, colon), Number(loc.designator.slice(colon + 1)));
    }
    default:
      throw new PancakeError(INVALID_ARGUMENT, `connectUri: unsupported transport "${loc.transport}"`);
  }
}

/** Dial an iroh partner from its published `ocapn://<nodeid>.iroh?…` URI — a
 * thin wrapper over the transport-dispatching `connectUri`. `reachability` is
 * required; the caller owns the dialer's reach posture, there is no default. */
export function connectIrohUri(uri: string, reachability: Reachability): Promise<Connection> {
  return connectUri(uri, reachability);
}
