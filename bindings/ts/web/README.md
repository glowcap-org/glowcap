# @glowcap/web

Run a browser tab as an OCapN peer over WebSocket or WebRTC. The protocol core
runs in WebAssembly (`wasm32`) through the `@glowcap/runtime` Session and Host
API ([ADR-0034]).

[ADR-0034]: ../../../docs/decisions/adr/ADR-0034-browser-peers.md

```ts
import { init } from "@glowcap/web";
import { connector, noise } from "@glowcap/relay";

const web = await init({
	wasm: fetch("/glowcap_host.wasm"),
	connectors: [connector()],
});
await using runtime = web.runtime;
const peerKey = "<64 lowercase hex characters from the peer>";
await using session = await runtime.connect(
	noise.locator(peerKey, "wss://relay.example/relay"),
);
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
```

The peer must register at that relay under its key. `noise-relay` encrypts the
session between the browser and the peer, including through the relay.

Build `glowcap_host.wasm` with `zig build wasm-driver`. The
[`runtime` guide](../runtime/README.md) covers hosting objects, promise
pipelining, and handoffs. The [complete browser example](../../../site/examples/browser/noise-relay.ts)
shows this fetch-and-call with its relay configuration.

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
  - A browser cannot bind a socket, so the TCP `listen` API refuses. It can
    accept sessions through WebRTC or a registered relay route.
  - Outbound writes wait until the browser's send buffer drops below its
    high-water mark.
  - Browser WebSockets cannot pause the sender, so inbound bytes go into a
    bounded queue. If it overflows, the socket closes instead of growing the
    tab's memory.

## Byte-transparent relay

Browser peers cannot dial TCP sockets directly. A relay endpoint accepts a WebSocket connection
and forwards CapTP bytes. Pass `wsUrl` to `init()` with a function that maps
`(host, port)` to the relay's URL, for example `` (h, p) => `ws://relay/relay?to=${h}:${p}` ``. The
reference relay ships as [`@glowcap/relay`](../relay/README.md). The rooms app wraps it at
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs), which allow-lists the room server's
own port for TCP targets, checks the `Origin` header on the upgrade, caps live sessions, times out
idle pairs, and bounds bytes per session. `zig build deno-relay-test` checks a keyed OCapN session
from this binding through that relay to a TCP host.

An [iroh gateway](https://glowcap.org/relay/) selected by `relayUrl` can read
traffic and vouches for the far peer's key. Use `noise-relay` when the relay
must not read the session.

## What the tests cover

`zig build web-peer-test` checks both codecs through
[`test/web_peer_test.ts`](test/web_peer_test.ts):

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

`zig build rooms-web-dm-noise` checks browser-to-browser handoff over an encrypted relay.

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
