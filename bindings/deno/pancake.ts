// Idiomatic Deno API for libpancake — an OCapN/CapTP peer you drive.
//
// The raw Deno.dlopen FFI is private to this module. What you use is a `Peer`
// class (disposable via `using`), discriminated-union value types, and typed
// `Event` objects out of `poll`. Integers are `bigint`, floats are `number`.
//
//   using peer = new Peer();
//   peer.registerImport(5n);
//   peer.sendDeliver(far(5n), [42n, new Uint8Array([1, 2])], 9n);
//   peer.step();
//   const frame = peer.takeOutbound();

const OK = 0;
const WOULD_BLOCK = -7;
const FRAME_SHAPE_BYTE = 0;
const EVENT_DELIVER = 1;
const EVENT_RESOLVE = 2;

const REF_NEAR = 0, REF_FAR = 1, REF_PROMISE = 2, REF_STURDY = 3, REF_BROKEN = 4;
const REF_OBJECT = 0, REF_PROMISE_KIND = 1;
const ARG_INTEGER = 0, ARG_FLOAT64 = 1, ARG_BOOLEAN = 2, ARG_BYTES = 3;
const ARG_STRING = 4, ARG_SYMBOL = 5, ARG_VOID = 6, ARG_REFERENCE = 7, ARG_LIST = 8;
const ARG_SET = 9, ARG_TAGGED = 10, ARG_KEYWORD = 11;
const RESOLUTION_FULFILL = 0, RESOLUTION_BREAK = 1;

const ARG_SIZE = 72; // sizeof(PancakeArgument), LP64
const REF_SIZE = 16;

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
  pancake_context_new_default: { parameters: ["buffer"], result: "i32" },
  pancake_context_new_with_allocator: { parameters: ["buffer", "buffer"], result: "i32" },
  pancake_context_release: { parameters: ["pointer"], result: "void" },
  pancake_peer_new_in: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_tcp_netlayer_new_in: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_feed_owned: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_new: { parameters: ["buffer"], result: "i32" },
  pancake_peer_new_negotiating: { parameters: ["buffer"], result: "i32" },
  pancake_peer_start_session_keyed: {
    parameters: ["pointer", "u32", "buffer", "usize", "buffer", "usize", "u32", "buffer"],
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
  pancake_peer_register_export: { parameters: ["pointer", "u64"], result: "i32" },
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
  pancake_deliver_free: { parameters: ["buffer"], result: "void" },
  pancake_resolve_free: { parameters: ["buffer"], result: "void" },
  pancake_peer_register_bootstrap_cap: { parameters: ["pointer", "buffer", "usize", "buffer"], result: "i32" },
  pancake_tcp_netlayer_new: { parameters: ["buffer"], result: "i32" },
  pancake_tcp_netlayer_release: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_tcp_testing_connect: {
    parameters: ["pointer", "buffer", "usize", "u16", "u32", "usize", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_testing_listen: {
    parameters: ["pointer", "buffer", "usize", "u16", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_listener_port: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_endpoint_tcp_testing_accept: { parameters: ["pointer", "u32", "usize", "buffer"], result: "i32" },
  pancake_endpoint_tcp_read_frame: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_endpoint_tcp_write_frame: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_endpoint_tcp_conn_close: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_tcp_listener_close: { parameters: ["pointer"], result: "void" },
});

const s = lib.symbols;

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
  const buf = new Uint8Array(len);
  const written = Number(s.pancake_last_error(buf, BigInt(buf.length)));
  return new TextDecoder().decode(buf.subarray(0, Math.min(written, buf.length)));
}

/** Clear the calling thread's last error. */
export function clearLastError(): void {
  s.pancake_clear_last_error();
}

export class PancakeError extends Error {
  /** The thread-local diagnostic captured when this error was raised, if any. */
  readonly detail: string | null;
  constructor(public code: number) {
    const detail = lastError();
    super(detail ? `pancake error ${code}: ${detail}` : `pancake error ${code}`);
    this.detail = detail;
    this.name = "PancakeError";
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
      sub = ref.promise ? REF_PROMISE_KIND : REF_OBJECT;
      id = ref.id;
      break;
    case "far":
      kind = REF_FAR;
      sub = ref.promise ? REF_PROMISE_KIND : REF_OBJECT;
      id = ref.id;
      break;
    case "promise":
      kind = REF_PROMISE;
      id = ref.answer;
      break;
    default:
      throw new PancakeError(-13); // sturdy/broken not carried on send
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
    dv.setUint32(off, ARG_INTEGER, true);
    dv.setBigInt64(off + 8, arg, true);
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
    throw new PancakeError(-13);
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
  const promise = sub === REF_PROMISE_KIND;
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
    default:
      throw new PancakeError(-3); // PANCAKE_ERR_INVALID_ARGUMENT: unrecognized arg kind
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
    check(s.pancake_context_new_default(out));
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

  /** A peer using the library-owned allocator. Pass a `Context` to route its
   * allocations through that context instead (prefer `Peer.newIn`). */
  constructor(raw?: Deno.PointerValue) {
    if (raw !== undefined) {
      this.#raw = raw;
      return;
    }
    const out = new Uint8Array(8);
    check(s.pancake_peer_new(out));
    this.#raw = Deno.UnsafePointer.create(new DataView(out.buffer).getBigUint64(0, true));
  }

  /** A peer whose allocations route through `context`; the context must outlive it. */
  static newIn(context: Context): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_in(context.pointer, out));
    return new Peer(outPointer(out));
  }

  /** A negotiating peer, awaiting the keyed `op:start-session` handshake — the
   * peer to drive when the partner requires it (a real Goblins vat). Pair it
   * with `startSessionKeyed`, then pump the connection until `sessionIsOpen`. */
  static newNegotiating(): Peer {
    const out = new Uint8Array(8);
    check(s.pancake_peer_new_negotiating(out));
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

  registerImport(id: bigint): void {
    check(s.pancake_peer_register_import(this.#raw, id));
  }

  /** Sign and queue a keyed `op:start-session` from this negotiating peer. The
   * 32-byte `seed` is the session key; `transport`/`designator` form the locator
   * the partner verifies, so they must be what it expects — for a Goblins
   * partner, `"tcp"` with `hintsEmptyFalse` true (an empty hints map encoded as
   * `#f`). `version` is the canonical `"v1.0"` (default) or `"pre-spec"`. Flush
   * it with `step` + `takeOutbound`, then pump until `sessionIsOpen`. */
  startSessionKeyed(opts: {
    transport: string;
    designator: string;
    seed: Uint8Array;
    hintsEmptyFalse?: boolean;
    version?: "v1.0" | "pre-spec";
  }): void {
    if (opts.seed.length !== 32) throw new Error("a session seed must be 32 bytes");
    const transport = new TextEncoder().encode(opts.transport);
    const designator = new TextEncoder().encode(opts.designator);
    check(s.pancake_peer_start_session_keyed(
      this.#raw,
      opts.version === "pre-spec" ? 1 : 0,
      ab(transport),
      BigInt(transport.length),
      ab(designator),
      BigInt(designator.length),
      (opts.hintsEmptyFalse ?? true) ? 1 : 0,
      ab(opts.seed),
    ));
  }

  /** Whether the keyed handshake has completed and the session is open for
   * traffic. Pump the connection and poll this before sending application
   * messages. */
  sessionIsOpen(): boolean {
    const rc = s.pancake_peer_session_is_open(this.#raw);
    if (rc < 0) throw new PancakeError(rc);
    return rc === 1;
  }

  feed(frame: Uint8Array): void {
    const f = new Uint8Array(24);
    const dv = new DataView(f.buffer);
    dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(Deno.UnsafePointer.of(ab(frame)))), true);
    dv.setBigUint64(8, BigInt(frame.length), true);
    dv.setUint32(16, FRAME_SHAPE_BYTE, true);
    check(s.pancake_peer_feed_borrowed(this.#raw, f));
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
    check(rc);
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
      // call release. Retire and reclaim ourselves before throwing.
      pin.retired = true;
      this.#sweepRetired();
      throw new PancakeError(rc);
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
    if (s.pancake_peer_take_outbound(this.#raw, frame) !== OK) return null;
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
    return this.#pollOther();
  }

  #pollDeliver(): Event {
    const buf = new Uint8Array(56);
    check(s.pancake_peer_poll_event_deliver(this.#raw, buf));
    const dv = new DataView(buf.buffer);
    const view = new Deno.UnsafePointerView(Deno.UnsafePointer.of(buf)!);
    const target = readReference(view, 0);
    const args = readArgArray(dv.getBigUint64(16, true), dv.getBigUint64(24, true));
    const hasAnswer = dv.getUint32(32, true) !== 0;
    const answer = dv.getBigUint64(40, true);
    s.pancake_deliver_free(buf);
    return { kind: "deliver", target, args, answer: hasAnswer ? answer : null };
  }

  #pollResolve(): Event {
    const buf = new Uint8Array(ARG_SIZE + 48);
    check(s.pancake_peer_poll_event_resolve(this.#raw, buf));
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
    s.pancake_resolve_free(buf);
    return { kind: "resolve", answer, resolution };
  }

  #pollOther(): Event {
    const buf = new Uint8Array(48);
    s.pancake_peer_poll_event(this.#raw, buf);
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

// Goblins-shaped actors over the pancake peer, in native TypeScript. This is
// pancake's Zig actor seam (`src/actors/vat.zig`) and the Goblins-faithful
// Racket binding, expressed in TS: one unified `Ref` (local actor or far
// partner object) and one `Vow` (local result or far wire-answer), with a
// peer-aware `Vat` that routes between them.
//
// An actor is a TS callback, not a wrapped C vat — the way `AsyncConnection`
// is Deno networking rather than a foreign reactor. The vat holds local actors
// (each a closure over a method verb and its arguments) and, when bound to a
// peer, routes eventual-sends to far objects over the wire. A leading `Sym`
// argument is the method verb (matching Goblins's `($ obj 'method arg …)`); the
// rest are the call's arguments.
//
// Two verbs, matching Goblins and the Zig seam:
//   * `call` — the synchronous near-call (`$`): run a local actor's handler now
//     and return its value. A far ref throws; near-call is local only.
//   * `send` — the eventual send (`<-`): location-transparent. A local target
//     queues a turn `drive` runs; a far target sends an `op:deliver` over the
//     bound peer with a fresh answer. Either way it returns a `Vow` you observe
//     with `on`.

/** An actor behavior: handle a `(verb, args)` call, returning a reply. Throw to
 * signal a broken resolution; the thrown error's message becomes the break. */
export type Behavior = (verb: string, args: Argument[]) => Argument;

/** A reference the vat can eventual-send to, wherever the object lives. A
 * `LocalRef` names an actor in this vat; a `FarRef` wraps a `far` reference to
 * a partner-hosted object the bound peer holds as an import. */
type VatRef = LocalRef | FarRef;

/** An actor living in this vat — `call`/`send` run its turns here. */
export class LocalRef {
  readonly location = "local" as const;
  constructor(public readonly id: number) {}
}

/** A partner-hosted object the bound peer holds as an import — `send` routes to
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
 * `drive`; a `FarVow` settles when the partner's `op:resolve` arrives and the
 * application hands it to `serve`. */
export type Vow = LocalVow | FarVow;

// A vow is awaitable: `await vat.send(...)` resolves with the value, or rejects
// with an Error carrying the break message. The promise is registered lazily, the
// first time the vow is awaited (or `.then`'d), so a fire-and-forget send that no
// one observes settles into nothing — no stray unhandled rejection. `vat.on` is
// still here for the callback style.
function settle(vat: Vat, vow: Vow): Promise<Argument> {
  return new Promise<Argument>((resolve, reject) => {
    vat.on(vow, (value) => resolve(value), (message) => reject(new Error(message)));
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
 * The vat owns no I/O and no scheduler — you drive it. Around `serve` you
 * feed/step/takeOutbound on the peer yourself, exactly as the Zig seam expects
 * its caller to poll the peer and hand events in. */
export class Vat {
  #peer: Peer | null;
  #actors = new Map<number, Behavior>();
  #queue: Array<{ id: number; verb: string; args: Argument[]; vow: number }> = [];
  #localListeners = new Map<number, VowListener>();
  #farListeners = new Map<bigint, VowListener>(); // outbound answer -> listener
  #exports = new Map<bigint, number>(); // export id -> local actor id
  #nextActor = 1;
  #nextVow = 1;
  // Far-send answers start high to stay clear of the answers a partner
  // allocates for its own calls; the C ABI has no allocateAnswer, so the vat
  // tracks its own outbound-answer counter (matching the Racket binding).
  #nextAnswer = 1000n;

  /** A pure-local vat, or — given a peer — one that routes far sends and hosts
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
    const answer = this.#nextAnswer++;
    const payload: Argument[] = verb.length > 0 ? [new Sym(verb), ...args] : args;
    peer.sendDeliver(ref.reference, payload, answer);
    return new FarVow(answer, this);
  }

  /** Register a one-shot listener on `vow`. A local vow fires during `drive`; a
   * far vow fires when `serve` dispatches the matching `op:resolve`. */
  on(vow: Vow, onFulfilled?: (value: Argument) => void, onBroken?: (message: string) => void): void {
    const listener: VowListener = { onFulfilled, onBroken };
    if (vow.location === "local") {
      this.#localListeners.set(vow.id, listener);
    } else {
      this.#farListeners.set(vow.answer, listener);
    }
  }

  /** Break every outstanding far vow with `message`, firing each listener's
   * `onBroken`. A far vow settles only when the partner's `op:resolve` arrives
   * over the wire, so once the connection is gone those replies can never come.
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

export const CODEC_SYRUP = 0;

function outPointer(buf: Uint8Array): Deno.PointerValue {
  return Deno.UnsafePointer.create(new DataView(buf.buffer).getBigUint64(0, true));
}

/** A blocking TCP connection. Closed on `close` / `[Symbol.dispose]`. */
export class Conn {
  #raw: Deno.PointerValue;
  constructor(raw: Deno.PointerValue) {
    this.#raw = raw;
  }
  close(): void {
    if (this.#raw !== null) {
      s.pancake_endpoint_tcp_conn_close(this.#raw);
      this.#raw = null;
    }
  }
  [Symbol.dispose](): void {
    this.close();
  }
  /** Block for one whole frame. Throws PancakeError(-8) on clean EOF. */
  readFrame(): Uint8Array {
    const mf = new Uint8Array(40);
    check(s.pancake_endpoint_tcp_read_frame(this.#raw, mf));
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
    check(s.pancake_endpoint_tcp_write_frame(this.#raw, f));
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
      s.pancake_endpoint_tcp_listener_close(this.#raw);
      this.#raw = null;
    }
  }
  [Symbol.dispose](): void {
    this.close();
  }
  port(): number {
    const out = new Uint8Array(2);
    check(s.pancake_endpoint_tcp_listener_port(this.#raw, out));
    return new DataView(out.buffer).getUint16(0, true);
  }
  accept(codec = CODEC_SYRUP, maxFrameBytes = 4096): Conn {
    const out = new Uint8Array(8);
    check(s.pancake_endpoint_tcp_testing_accept(this.#raw, codec, BigInt(maxFrameBytes), out));
    return new Conn(outPointer(out));
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
    check(s.pancake_endpoint_tcp_testing_listen(this.#raw, h, BigInt(h.length), port, out));
    return new Listener(outPointer(out));
  }
  connect(host: string, port: number, codec = CODEC_SYRUP, maxFrameBytes = 4096): Conn {
    const h = new TextEncoder().encode(host);
    const out = new Uint8Array(8);
    check(s.pancake_endpoint_tcp_testing_connect(this.#raw, h, BigInt(h.length), port, codec, BigInt(maxFrameBytes), out));
    return new Conn(outPointer(out));
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

/** An OCapN/CapTP peer driven asynchronously over a Deno TCP connection.
 *
 * The sync `Peer` is sans-io: it never blocks and never owns a socket. This
 * class owns one peer and one `Deno.Conn` and drives the peer over it — reads
 * bytes, lets the peer frame and dispatch them (`Peer.recvStream`), writes the
 * peer's outbound frames back, and surfaces typed events. One `AsyncConnection`
 * owns one peer, so it lives on one task; the peer is a single-owner state
 * machine, never shared across tasks. */
export class AsyncConnection {
  #peer: Peer;
  #conn: Deno.Conn;
  #vat: Vat | null = null;
  // Inbound bytes read from the wire but not yet framed into whole frames.
  #inbox: Uint8Array = new Uint8Array(0);

  private constructor(peer: Peer, conn: Deno.Conn) {
    this.#peer = peer;
    this.#conn = conn;
  }

  /** Connect to `hostname:port` and wrap a fresh peer driven over the connection. */
  static async connect(hostname: string, port: number): Promise<AsyncConnection> {
    const conn = await Deno.connect({ hostname, port });
    return new AsyncConnection(new Peer(), conn);
  }

  /** Wrap an already-connected conn and a peer you have configured (registered
   * exports/imports, bootstrap caps, …). */
  static fromConn(peer: Peer, conn: Deno.Conn): AsyncConnection {
    return new AsyncConnection(peer, conn);
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

  /** Await the next application event, driving the socket as needed. Returns
   * `null` on a clean end of stream. */
  async nextEvent(): Promise<Event | null> {
    for (;;) {
      // A surfaced event takes priority.
      const ev = this.#peer.poll();
      if (ev) return ev;
      // Flush anything the last dispatch queued (replies, aborts).
      await this.#pumpOutbound();
      // Consume every whole frame already buffered; each may surface an event
      // or queue outbound, so loop back to re-check.
      if (this.#consumeBuffered()) continue;
      // Need more bytes from the wire.
      const chunk = new Uint8Array(READ_CHUNK);
      const n = await this.#conn.read(chunk);
      if (n === null) return null; // clean EOF
      this.#appendInbox(chunk.subarray(0, n));
    }
  }

  // Dispatch one buffered frame if a whole one is present. Returns true when a
  // frame was consumed (loop again), false when more bytes are needed.
  #consumeBuffered(): boolean {
    if (this.#inbox.length === 0) return false;
    const consumed = this.#peer.recvStream(this.#inbox);
    if (consumed === null) return false;
    this.#inbox = this.#inbox.subarray(consumed);
    return true;
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

  // Encode pending outbound work and write every queued frame to the socket.
  async #pumpOutbound(): Promise<void> {
    this.#peer.step();
    let f: Uint8Array | null;
    while ((f = this.#peer.takeOutbound()) !== null) {
      await writeAll(this.#conn, f);
    }
  }

  close(): void {
    try {
      this.#conn.close();
    } catch {
      // Already closed.
    }
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
// by hand. The seven verbs — `connect`/`listen`, `fetch`/`publish`, `spawn`,
// `send`, `serve`, `close` — are the whole common surface. The raw `Peer`,
// `Vat`, and `AsyncConnection` are still here for power users (reach `conn.peer`
// for handoff/pipeline/session control), but no application needs them.

/** The well-known bootstrap export every OCapN peer answers `fetch` on. */
const BOOTSTRAP_POSITION = 0n;

/** App-allocated export positions start clear of the bootstrap object (0) and a
 * band of low well-known slots, so a `spawn` never collides with the bootstrap
 * export. */
const FIRST_SPAWN_POSITION = 32n;

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
// underlying `Reference`; everything else passes through (recursing into lists).
function lowerArg(arg: AppValue): Argument {
  if (arg instanceof Ref) return arg.reference;
  if (Array.isArray(arg)) return arg.map(lowerArg);
  return arg;
}

// Lift a decoded argument to the application vocabulary: a wire `Reference`
// becomes a `Ref` the app can `send` to or pass on; lists recurse.
function liftArg(arg: Argument): AppValue {
  if (isReference(arg)) return new Ref(arg);
  if (Array.isArray(arg)) return arg.map(liftArg);
  return arg;
}

/** An actor: handle a `(verb, args)` call and return a reply. `args` may contain
 * `Ref`s (capabilities you were handed). Throw to break the caller's promise. */
export type Actor = (verb: string, args: AppValue[]) => AppValue | void;

// Complete the keyed `op:start-session` handshake over a negotiating peer: sign
// a `tcp` locator naming `designator` (with a per-connection random session
// key), flush it, and pump until the partner's start-session opens the session.
// Entropy is generated here, at the I/O boundary, never in the sans-io core. The
// locator is what a partner verifies; signing the socket's real local address
// keeps it a true `tcp` locator, which a Goblins partner accepts.
async function openKeyedSession(ac: AsyncConnection, designator: string): Promise<void> {
  const seed = crypto.getRandomValues(new Uint8Array(32));
  ac.peer.startSessionKeyed({ transport: "tcp", designator, seed, hintsEmptyFalse: true });
  await ac.flush();
  while (!ac.peer.sessionIsOpen()) {
    if ((await ac.nextEvent()) === null) {
      throw new Error("connection closed during the OCapN handshake");
    }
  }
}

// The `host:port` of a socket's own end, the locator a peer signs in its keyed
// start-session.
function localDesignator(tcp: Deno.Conn): string {
  const la = tcp.localAddr as Deno.NetAddr;
  return `${la.hostname}:${la.port}`;
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
  #nextSpawn = FIRST_SPAWN_POSITION;
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
    const ac = AsyncConnection.fromConn(Peer.newNegotiating(), tcp);
    await openKeyedSession(ac, localDesignator(tcp));
    return new Connection(ac);
  }

  /** Wrap a socket a server already accepted and complete the keyed handshake
   * from the responder side (used by `listen`). Resolves once the session is
   * open. */
  static async accept(tcp: Deno.Conn): Promise<Connection> {
    const ac = AsyncConnection.fromConn(Peer.newNegotiating(), tcp);
    await openKeyedSession(ac, localDesignator(tcp));
    return new Connection(ac);
  }

  /** The underlying sans-io peer — the escape hatch for handoff, pipelining, and
   * session control. Applications do not need it. */
  get peer(): Peer {
    return this.#ac.peer;
  }

  /** Spawn a local actor and return a capability to it. The `Ref` auto-marshals
   * when passed as a `send` argument, so handing a partner a callback is just
   * `send(target, verb, [..., conn.spawn(behavior)])`. */
  spawn(behavior: Actor): Ref {
    const position = this.#nextSpawn++;
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
   * `send` to. Requires `serve()` to be running so the resolution arrives. */
  async fetch(name: string): Promise<Ref> {
    this.#ac.peer.registerImport(BOOTSTRAP_POSITION);
    const swiss = new TextEncoder().encode(name);
    const vow = this.#vat.send(new FarRef(far(BOOTSTRAP_POSITION)), "fetch", [swiss]);
    // Subscribe before flushing: the resolution can land on the serve loop the
    // instant `flush` yields the event loop.
    const settled = settle(this.#vat, vow);
    await this.#ac.flush();
    const result = await settled;
    if (!isReference(result)) {
      throw new Error(`fetch("${name}") did not resolve to a capability`);
    }
    return new Ref(result, null);
  }

  /** Call `verb(args)` on the capability `target` and await the reply. Flushes
   * the call to the wire immediately. `args` may contain `Ref`s. The returned
   * promise resolves with the reply (a `Ref` if the partner returned a
   * capability) or rejects if the partner breaks it. */
  async send(target: Ref, verb: string, args: AppValue[] = []): Promise<AppValue> {
    const wireArgs = args.map(lowerArg);
    const vatTarget: VatRef = target.localActorId !== null
      ? new LocalRef(target.localActorId)
      : new FarRef(target.reference);
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
      yield await Connection.accept(tcp);
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
