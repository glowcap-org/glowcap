# pancake-deno

A [Deno](https://deno.com) FFI consumer for the pancake CapTP runtime, bound through `Deno.dlopen`
against the prebuilt C-ABI cdylib family. It is the TypeScript sibling of the Racket binding in
[`../pancake-goblins/racket/pancake-ffi.rkt`](../pancake-goblins/racket/pancake-ffi.rkt) and mirrors
its structure: env-driven three-library load, per-library last-error slots, fixed-size tagged-union
marshalling, copy-out-then-free receive projection, and a single-thread cooperative poll pump.

## What pancake is

pancake is a Rust codec-neutral CapTP runtime for OCapN, exposed as a family of C-ABI cdylibs. This
binding loads three of them:

| Library                   | Env var                | Surface                                                                                                                      |
| ------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `libpancake_ffi_runtime`  | `PANCAKE_LIB`          | protocol core: peer lifecycle, step/queues, typed values, send/recv, cross-peer, keypair, OCapN-URI parse, Syrup frame probe |
| `libpancake_ffi_net_tcp`  | `PANCAKE_NET_TCP_LIB`  | cleartext + TLS TCP endpoints                                                                                                |
| `libpancake_ffi_net_iroh` | `PANCAKE_NET_IROH_LIB` | QUIC-over-iroh endpoints                                                                                                     |

The C ABI it binds is generated from
[`crates/ffi/pancake-ffi-abi/include/pancake_abi.h`](../../../crates/ffi/pancake-ffi-abi/include/pancake_abi.h),
[`pancake.h`](../../../crates/ffi/pancake-ffi-runtime/include/pancake.h),
[`pancake_net_tcp.h`](../../../crates/ffi/pancake-ffi-net-tcp/include/pancake_net_tcp.h), and
[`pancake_net_iroh.h`](../../../crates/ffi/pancake-ffi-net-iroh/include/pancake_net_iroh.h).

## Running

Deno's FFI requires `--allow-ffi --allow-env --unstable-ffi`. Point the three env vars at the
absolute `target/release/*.so` paths:

```bash
R="$(git rev-parse --show-toplevel)/target/release"
PANCAKE_LIB="$R/libpancake_ffi_runtime.so" \
PANCAKE_NET_TCP_LIB="$R/libpancake_ffi_net_tcp.so" \
PANCAKE_NET_IROH_LIB="$R/libpancake_ffi_net_iroh.so" \
deno run --allow-ffi --allow-env --unstable-ffi src/scenarios.ts
```

Or via the task (set the env vars first):

```bash
deno task verify
```

The cdylibs are prebuilt by
`cargo build --release -p pancake-ffi-runtime
-p pancake-ffi-net-tcp -p pancake-ffi-net-iroh`.

## Library API

```ts
import {
  argInteger,
  argSymbol,
  IrohNetlayer,
  loadNetIroh,
  loadNetTcp,
  loadRuntime,
  PANCAKE_CODEC_SYRUP,
  Peer,
  refNear,
  refSturdy,
  runUntilAllOpen,
  TcpNetlayer,
} from "./mod.ts";

const rt = loadRuntime(); // PANCAKE_LIB
const netTcp = loadNetTcp(); // PANCAKE_NET_TCP_LIB
const tcp = TcpNetlayer.cleartext(netTcp);

const { listener, boundAddr } = tcp.listen("127.0.0.1:0");
const dialerConn = tcp.connect(boundAddr);
const listenerConn = tcp.acceptTimed(listener, 2000);

const dialer = Peer.create(rt, PANCAKE_CODEC_SYRUP); // fresh Ed25519 keypair, V1.0 + Goblins profile
const listenerPeer = Peer.create(rt, PANCAKE_CODEC_SYRUP);
// dialer.sendStartSession(...), pump both via runUntilAllOpen([...]) until SESSION_OPEN.
```

## Layout

```
pancake-deno/
├── deno.json              # tasks (verify / check / fmt / lint), fmt + lint config
├── mod.ts                 # public re-exports
├── README.md
└── src/
    ├── constants.ts       # PANCAKE_* ABI vocabulary + LP64 struct offsets
    ├── values.ts          # typed-value model + tagged-union marshal/project
    ├── host.ts            # Peer wrapper, keypair, URI parse, frame probe, cross-peer
    ├── netlayer.ts        # transport-agnostic Conn over TCP / TLS / iroh
    ├── pump.ts            # single-thread cooperative poll pump
    ├── scenarios.ts       # runnable verification (entry point)
    └── ffi/
        ├── abi.ts         # shared plumbing: Arena, cstr, last-error, byte copy-out
        ├── runtime.ts     # libpancake_ffi_runtime symbol table
        ├── net_tcp.ts     # libpancake_ffi_net_tcp symbol table
        └── net_iroh.ts    # libpancake_ffi_net_iroh symbol table
```

## ABI contracts honored

These are the load-bearing rules the binding obeys (mirrored from the Racket template and the C
headers):

1. **Three libraries, three last-error slots.** The panic seam is statically linked into each
   cdylib, so every library has its own per-thread `pancake_last_error`. The binding binds it 3×
   (`runtime`/`net_tcp`/`net_iroh`) and surfaces the matching library's diagnostic on failure. The
   runtime's `feed_inbound` / send paths populate a typed diagnostic on the `-3/-4/-5/-6` error
   codes, which `PancakeError` surfaces.

2. **One frame model per direction.** Inbound (`feed_inbound`) lends a bare `PancakeFrame`
   `(bytes,len)` the runtime borrows for the call (zero-copy, nothing to free). Outbound
   (`take_outbound`) and netlayer `read_frame` hand back a self-describing `PancakeManagedFrame`
   carrying its own release; every such buffer — from the runtime or either netlayer cdylib — is
   freed via the single `pancake_managed_frame_release`, never a host free.

3. **Copy out before releasing.** `Deno.UnsafePointerView.getArrayBuffer` aliases native memory
   rather than copying, so `readBytes` forces an owned copy while the native allocation is still
   live, before `pancake_managed_frame_release`. (Skipping this reads allocator free-list bytes back
   — the binding was written against that trap.)

4. **Fixed-size tagged-union marshalling (LP64, 64-bit little-endian).** `PancakeReference` payload
   = 32 bytes, `PancakeArgument` = 40, `PancakeResolution` = 48; `kind` at offset 0, payload at
   offset 8; `Far`/`Sturdy` payloads are `{ptr, len, …}` triples. The send side pins every leaf
   buffer in an `Arena` until the FFI call returns (pancake copies on push).

5. **Single-thread cooperative pump.** Deno is single-threaded, so a blocking FFI call freezes the
   isolate. Each connection's read timeout is set to 50 ms via `set_read_timeout_ms` so `read_frame`
   returns `WOULD_BLOCK` instead of blocking, and the pump `await`s a `setTimeout` between ticks to
   yield the event loop — faithful to the Racket `tcp-bridge.rkt` pump.

## Verification

`src/scenarios.ts` verifies, end to end against the real cdylibs:

1. `pancake_version`.
2. `pancake_ocapn_uri_parse`.
3. a typed-value round-trip — build an `Argument` list, marshal it into the exact LP64 tagged-union
   byte layout the C ABI consumes, and project it back.
4. a pancake↔pancake handshake over **TCP loopback** that reaches `PANCAKE_SESSION_OPEN` on **both**
   peers.
5. the iroh netlayer loads and constructs an endpoint.

Sample output (paths abbreviated):

```
[1] pancake_version
  pancake_version → "pancake-ffi 0.1.0"

[2] OCapN URI parse
  pancake_ocapn_uri_parse("ocapn://abcd1234.tcp-testing-only") → transport=tcp-testing-only designator=abcd1234 swissnum=none

[3] typed-value round-trip (marshal ⇄ project)
  [0] Symbol(ping) ⇄ Symbol(ping) ✓
  [1] String("hello pancake") ⇄ String("hello pancake") ✓
  [2] Integer(-42) ⇄ Integer(-42) ✓
  [3] Bool(true) ⇄ Bool(true) ✓
  [4] Bytes(deadbeef) ⇄ Bytes(deadbeef) ✓
  [5] List[Symbol(nested), Integer(7), Bool(false)] ⇄ List[Symbol(nested), Integer(7), Bool(false)] ✓
  [6] List[] ⇄ List[] ✓

[4] pancake↔pancake handshake over TCP loopback → SESSION_OPEN
  listening on 127.0.0.1:17248
  TCP loopback connection established
  dialer  session state: OPEN (partner peer-id 87dbb76a4e6239d1… (32B))
  listener session state: OPEN (partner peer-id 08bf6faac43402ff… (32B))
  ✓ BOTH peers reached PANCAKE_SESSION_OPEN

[5] iroh netlayer load
  iroh endpoint id: 24a6255a8903f177…

ALL CHECKS PASSED ✓
```
