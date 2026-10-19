# @glowcap/web

Use this package to run a browser tab as an OCapN peer. It is the same protocol core the Zig
libraries use, compiled to WebAssembly (`wasm32`), with the byte channel on a WebSocket. It offers
the same `@glowcap/runtime` API that Deno and Bun use, through a browser adapter, and the protocol
stays in Wasm ([ADR-0070]).

The tests cover:

- the keyed handshake, fetch and call, and a call back into an object hosted in Wasm
- both wire encodings, Syrup and Cap'n Proto
- a non-browser peer dialing a Chromium-hosted object over `noise-relay`
- `zig build rooms-web-dm-noise`, which has one browser follow a room introduction by dialing
  another browser over that encrypted relay path and then carry the reply back

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

`init` loads `glowcap_host.wasm` (built by `zig build wasm-driver`), installs the browser adapter
over it, and only then loads `@glowcap/runtime`, which uses that adapter instead of probing for
Deno or Bun. It returns the runtime module plus a default `Runtime`, so
[`@glowcap/runtime`'s README](../runtime/README.md) applies in full: `Session`, `spawn`, `publish`,
promise pipelining, proxies, and three-party handoffs.

## How the adapter works

[`adapter.ts`](adapter.ts) connects the
shared runtime to the browser. It supplies what Deno and Bun get from the operating system:

- **Calls into Wasm.** The Wasm module exports the same `glowcap_*` C functions that Deno and Bun
  load. JavaScript cannot lend Wasm a view of its own buffers, so each buffer argument is copied
  into Wasm memory before a call and copied back afterwards, which is also how out-parameters
  return. Those copies live in a scratch area that is freed two calls later, because a call's
  returned views may point into its copied inputs.
- **Struct layout from the module itself.** Field offsets differ between the
  64-bit targets and wasm32, so the adapter reads the module's own
  layout descriptor (`glowcap_wasm_abi_layout`) and gives the runtime a layout
  its marshallers read through (`runtime/internal/layout.ts`).
  `zig build wasm-abi-layout-check` keeps the descriptor, the generated
  manifest in `@glowcap/abi`, and the 64-bit mirror in agreement.
- **Two callbacks for hosted objects.** The module imports two
  functions: behavior dispatch and hosted actor retirement.
  `zig build wasm-import-check` pins both. Every Wasm-hosted object dispatches
  by context id, and retirement drops its JavaScript owner when the actor's
  last root goes, so repeated aliases do not pile up behavior entries. A
  `Context` with a custom allocator works only in Deno and Bun, and is
  refused with an error here.
- **Sockets over WebSocket.** `connect` opens a WebSocket to `ws://host:port/`
  by default. Pass `wsUrl` to route every dial through a byte gateway instead.
  - The socket carries raw OCapN frames, and the Host's stream delimiter does
    the framing, so the accepting side only passes bytes along.
  - A browser cannot bind a listener, so `listen` refuses.
  - Outbound writes wait until the browser's send buffer drops below its
    high-water mark.
  - Browser WebSockets cannot pause the sender, so inbound bytes go into a
    bounded queue. If it overflows, the socket closes instead of growing the
    tab's memory.

## Byte-transparent relay

Browser peers cannot dial TCP sockets directly. A relay endpoint accepts a WebSocket connection
and forwards bytes without parsing CapTP frames, so the keyed or Noise handshake and the session run end
to end unchanged. Pass `wsUrl` to `init()` with a function that maps
`(host, port)` to the relay's URL, for example `` (h, p) => `ws://relay/relay?to=${h}:${p}` ``. The
reference relay ships as [`@glowcap/relay`](../relay/README.md). The rooms app wraps it at
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs), which allow-lists the room server's
own port for TCP targets, checks the `Origin` header on the upgrade, caps live sessions, times out
idle pairs, and bounds bytes per session. `zig build deno-relay-test` checks a keyed OCapN session
from this binding through that relay to a TCP host.

## What the tests cover

`zig build web-peer-test` runs [`test/web_peer_test.ts`](test/web_peer_test.ts) in three steps:

1. A Deno host ([`test/serve_ws_host.ts`](test/serve_ws_host.ts)) accepts WebSocket connections
   straight into `Session.establishAccepted`.
2. A second process loads the runtime through `@glowcap/web`, with the Wasm module and a WebSocket
   channel and no `Deno.dlopen` anywhere in its graph.
3. That peer completes the keyed handshake, fetches and calls a published object, and receives a
   call back into an object it hosts. The same check then launches Chromium, registers the page's Wasm Host at the
reference relay under `noise-relay`, and has the installed CLI cold-dial and call it.
That rendezvous leg is WSS with a test certificate authority supplied independently to the browser and the CLI
process. The relay also audits a plaintext canary.

[`test/wasm_handshake_smoke.ts`](test/wasm_handshake_smoke.ts) (`zig build
wasm-driver-test`) is the layer
below: two wasm Hosts complete the keyed handshake over an in-memory byte pipe, driven through raw
exports with no binding at all.

## Shipping a page

1. Serve `glowcap_host.wasm` from `zig-out/wasm/` after `zig build wasm-driver`.
2. Bundle this package with `@glowcap/runtime` and `@glowcap/abi`. Start from
   the adapter-only [`browser-bundle.json`](browser-bundle.json) and add the
   application's framework and data dependencies to it.

The browser mapping in `browser-bundle.json` points `@glowcap/runtime/ffi` at the Wasm adapter, so
the code that looks up local C libraries stays out of the browser bundle. The remaining stubs cover
Deno and Bun adapters that a bundler may find through a dynamic import, and the web adapter never
selects them. Rooms uses its own Rust Wasm and a separate bundle map.

Keep module-level top-level `await` out of the runtime. `deno bundle` (esbuild)
flattens every module's top-level await into one file, and the runtime's import
graph deadlocks there. `internal/ffi/runtime.ts` resolves its adapter
synchronously, and the archive symbol tables `dlopen` lazily on first use.

Browser-to-browser transport ships as [`@glowcap/webrtc`](../webrtc/README.md), a direct DTLS
DataChannel opened through a signaling capability. `zig build webrtc-browser-to-browser` runs two
Chromium peers over one.
