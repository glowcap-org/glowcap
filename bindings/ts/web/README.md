# @glowcap/web

The browser entry for the glowcap runtime. A browser tab becomes a real OCapN peer: the same I/O-free
protocol core the native archives link, compiled to `wasm32`, with the byte channel on a WebSocket.
This is [ADR-0070] Milestone 1: the same `@glowcap/runtime` surface every dlopen runtime uses, on top
of a swapped runtime adapter, with no protocol reimplemented in JavaScript. The build check covers
the keyed handshake, fetch and call, a call back into a wasm-hosted object, both wire grammars
(Syrup and Cap'n Proto), and a native peer cold-dialing a Chromium-hosted object over
`noise-relay`. `zig build rooms-web-dm-noise` additionally has one browser redeem a room
introduction by dialing another browser over that sealed relay path, then carries the reply back.

[ADR-0070]: ../../../docs/decisions/adr/ADR-0070-browser-binding-via-wasm.md

```ts
import { init } from "@glowcap/web";
import { noise } from "@glowcap/tcp";

const runtime = await init({ wasm: fetch("/glowcap_host.wasm") });
const session = await runtime.connect(noise.locator(key, host, port));
session.serve().catch((err) => console.error("session ended:", err));
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
```

`init` instantiates `glowcap_host.wasm` (built by `zig build wasm-driver`), builds the runtime
adapter over it, installs the adapter, and only then loads `@glowcap/runtime`, which binds to it
instead of probing for Deno or Bun. The returned value is the runtime module plus its managed
default `Runtime`, so everything in
[`@glowcap/runtime`'s README](../runtime/README.md) applies: `Session`, `spawn`, `publish`, pipelining,
proxies, three-party redemption.

## The adapter

[`adapter.ts`](adapter.ts) connects the shared runtime to the browser. It
supplies four things the native runtimes get from the operating system:

- **FFI over linear memory.** The Wasm module exports the same `glowcap_*` C
  ABI that the native runtimes load. JavaScript cannot lend Wasm a view of its
  own buffers, so every buffer argument is copied into linear memory before a
  call and copied back afterwards; that is how C out-parameters return. Both
  copies are the named cost of crossing into linear memory. Staged copies live
  in an arena that is freed two calls later, because a call's returned views
  may point into its staged inputs.
- **Struct layout from the module itself.** Field offsets differ between the
  64-bit native targets and wasm32. So the adapter reads the module's own
  layout descriptor (`glowcap_wasm_abi_layout`) and gives the runtime a layout
  its marshallers read through (`runtime/internal/layout.ts`).
  `zig build wasm-abi-layout-check` keeps the descriptor, the generated
  manifest in `@glowcap/abi`, and the 64-bit mirror in agreement.
- **Two callbacks for hosted objects.** The module imports exactly two
  functions: behavior dispatch and hosted actor retirement.
  `zig build wasm-import-check` pins both. Every Wasm-hosted object dispatches
  by context id, and retirement drops its JavaScript owner when the actor's
  last root goes, so repeated aliases do not pile up behavior entries. A
  `Context` with a custom allocator works only in the native runtimes, and is
  refused with an error here.
- **Sockets over WebSocket.** `connect` opens a WebSocket to `ws://host:port/`
  by default. Pass `wsUrl` to route every dial through a byte gateway instead.
  - The socket carries raw OCapN frames, and the Host's stream delimiter does
    the framing. So the accepting side only passes bytes along; it never
    translates the protocol.
  - A browser cannot bind a listener, so `listen` refuses.
  - Outbound writes wait until the browser's send buffer drops below its
    high-water mark.
  - Browser WebSockets cannot pause the sender, so inbound bytes go into a
    bounded queue. If it overflows, the socket closes instead of growing the
    tab's memory.

## Byte-transparent relay

Browser peers cannot dial native sockets directly. A relay endpoint accepts a WebSocket connection
and forwards bytes without parsing CapTP frames, so the keyed or Noise handshake and session
authority run end to end unchanged. Pass `wsUrl` to `init()` with a function that maps
`(host, port)` to the relay's URL, for example `` (h, p) => `ws://relay/relay?to=${h}:${p}` ``. The
reference relay ships as [`@glowcap/relay`](../relay/README.md). The rooms app wraps it at
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs), which allow-lists the room server's
own port for TCP targets, checks the `Origin` header on the upgrade, caps live sessions, times out
idle pairs, and bounds bytes per session. `zig build deno-relay-test` proves a keyed OCapN session
from this binding through that relay to a native TCP host.

## The proof

`zig build web-peer-test` runs [`test/web_peer_test.ts`](test/web_peer_test.ts): a native host
([`test/serve_ws_host.ts`](test/serve_ws_host.ts)) accepts WebSocket connections straight into
`Session.establishAccepted`, and a second process loads the runtime through `@glowcap/web` (wasm
module, linear-memory FFI, WebSocket channel, and no `Deno.dlopen` anywhere in its graph). That peer
completes the keyed handshake, fetches and calls a published object, and receives a call back into
an object it hosts. The same check then launches Chromium, registers the page's Wasm Host at the
reference relay under `noise-relay`, and has the installed native CLI cold-dial and call it.
That rendezvous leg is WSS with a test authority supplied independently to the browser and native
process; the relay also audits a plaintext canary.

[`test/wasm_handshake_smoke.ts`](test/wasm_handshake_smoke.ts) (`zig build
wasm-driver-test`) is the layer
below: two wasm Hosts complete the keyed handshake over an in-memory byte pipe, driven through raw
exports with no binding at all.

## What a real page needs

Serve `glowcap_host.wasm` (from `zig-out/wasm/` or a release) and bundle this package plus
`@glowcap/runtime` and `@glowcap/abi`. Extend the adapter-only
[`browser-bundle.json`](browser-bundle.json) from the application config, then add that application's
framework and data dependencies there. Rooms uses its linked Rust application Wasm
and has a separate presentation-only bundle map. The TypeScript binding's
browser mapping sends `@glowcap/runtime/ffi` to the wasm adapter's stem-only resolver, so
the native archive-resolution cascade is absent from the browser module graph. The only host stubs
left cover non-browser runtime adapters a bundler may discover through their dynamic import; the
injected web adapter never selects them.

Keep the runtime free of module-level top-level `await`. `deno bundle` (esbuild) flattens every
module's top-level await into one file, where the runtime's import graph deadlocks around one. That is
why `internal/ffi/runtime.ts` resolves its adapter synchronously and the archive symbol tables
`dlopen` lazily on first use rather than at module load.

Browser-to-browser transport ships as [`@glowcap/webrtc`](../webrtc/README.md), a direct DTLS
DataChannel opened through a signaling capability; `zig build webrtc-browser-to-browser` holds two
Chromium peers on one.
