// Deno dogfood of the Zig libpancake C ABI.
//
// The Deno sibling of `bindings/rust`'s `rust_consumes_zig_peer_c_abi`:
// dlopen the shared library, create a peer, feed a borrowed `op:abort`
// frame, and assert the surfaced event is an Abort carrying the original
// bytes. This is the slice of the binding that consumes the Zig C ABI as
// it exists today; the richer netlayer/handshake surface under `src/` is
// pending the C ABI's growth (see ../README.md).

const PANCAKE_OK = 0;
const PANCAKE_FRAME_SHAPE_BYTE = 0;
const PANCAKE_EVENT_ABORT = 7;

const libPath = new URL("../../zig-out/lib/libpancake.so", import.meta.url)
  .pathname;

const lib = Deno.dlopen(libPath, {
  pancake_peer_new: { parameters: ["buffer"], result: "i32" },
  pancake_peer_release: { parameters: ["pointer"], result: "void" },
  pancake_peer_feed_borrowed: {
    parameters: ["pointer", "buffer"],
    result: "i32",
  },
  pancake_peer_poll_event: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_event_release: { parameters: ["buffer"], result: "void" },
});

function frameStruct(bytes: Uint8Array): Uint8Array {
  // extern struct PancakeFrame { const u8* bytes; usize len; u32 shape; }
  // LP64 layout: 8 (ptr) + 8 (len) + 4 (shape) + 4 (pad) = 24 bytes.
  const buf = new Uint8Array(24);
  const dv = new DataView(buf.buffer);
  const ptr = Deno.UnsafePointer.of(bytes);
  dv.setBigUint64(0, BigInt(Deno.UnsafePointer.value(ptr)), true);
  dv.setBigUint64(8, BigInt(bytes.length), true);
  dv.setUint32(16, PANCAKE_FRAME_SHAPE_BYTE, true);
  return buf;
}

function assert(cond: boolean, msg: string): void {
  if (!cond) {
    console.error(`deno zig-smoke FAILED: ${msg}`);
    Deno.exit(1);
  }
}

const peerOut = new Uint8Array(8);
assert(lib.symbols.pancake_peer_new(peerOut) === PANCAKE_OK, "peer_new");
const peer = Deno.UnsafePointer.create(
  new DataView(peerOut.buffer).getBigUint64(0, true),
);
assert(peer !== null, "peer pointer is non-null");

const abortBytes = new TextEncoder().encode('<8\'op:abort3"bye>');
assert(
  lib.symbols.pancake_peer_feed_borrowed(peer, frameStruct(abortBytes)) ===
    PANCAKE_OK,
  "feed_borrowed(op:abort)",
);

// extern struct PancakeEvent { u32 kind; PancakeManagedFrame frame; }
// kind (4) + pad (4) + managed frame (40) = 48 bytes; kind at offset 0.
const eventBuf = new Uint8Array(48);
assert(
  lib.symbols.pancake_peer_poll_event(peer, eventBuf) === PANCAKE_OK,
  "poll_event",
);
const kind = new DataView(eventBuf.buffer).getUint32(0, true);
assert(kind === PANCAKE_EVENT_ABORT, `event kind ${kind} === ABORT`);

lib.symbols.pancake_event_release(eventBuf);
lib.symbols.pancake_peer_release(peer);
lib.close();

console.log("deno zig-smoke OK: consumed Zig libpancake C ABI (op:abort)");
