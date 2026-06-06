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

const libPath = new URL("../../zig-out/lib/libpancake.so", import.meta.url).pathname;

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

  release(): void {
    if (this.#raw !== null) {
      s.pancake_peer_release(this.#raw);
      this.#raw = null;
    }
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
    Peer.#sweepRetired();

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
    Peer.#pinnedFrames.add(pin);

    const rc = s.pancake_peer_feed_owned(this.#raw, mf);
    if (rc !== OK) {
      // Not adopted: our descriptor still names our bytes; the library did not
      // call release. Retire and reclaim ourselves before throwing.
      pin.retired = true;
      Peer.#sweepRetired();
      throw new PancakeError(rc);
    }
  }

  // Keeps owned-frame buffers and their release trampolines alive while C holds
  // them, so the GC cannot reclaim either before the release callback runs.
  static #pinnedFrames = new Set<PinnedFrame>();

  // Close trampolines and drop buffers for frames the library released. Always
  // runs off the C stack (next feedOwned, or the failure path), never from
  // inside a release callback.
  static #sweepRetired(): void {
    for (const pin of Peer.#pinnedFrames) {
      if (pin.retired) {
        pin.release?.close();
        pin.release = null;
        Peer.#pinnedFrames.delete(pin);
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
    s.pancake_peer_poll_event_deliver(this.#raw, buf);
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
    s.pancake_peer_poll_event_resolve(this.#raw, buf);
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
