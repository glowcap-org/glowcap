# @pancake/web

The browser entry for the pancake stack. A browser tab becomes a real OCapN peer: the same sans-io
protocol core the native archives link, compiled to `wasm32`, with the byte channel on a WebSocket.
This is [ADR-0070] Milestone 1: the same `@pancake/stack` surface every dlopen runtime uses, on top
of a swapped runtime adapter, with no protocol reimplemented in JavaScript. The build check covers
the keyed handshake, fetch and call, a call back into a wasm-hosted object, and both wire grammars
(Syrup and Cap'n Proto); handoff redeem through a browser dial is compiled in but has no
browser-path check yet.

[ADR-0070]: ../../../docs/decisions/adr/ADR-0070-browser-binding-via-wasm.md

```ts
import { init } from "@pancake/web";

const stack = await init({ wasm: fetch("/pancake_host.wasm") });
const session = await stack.connect(stack.keyedTcpLocator(key, host, port));
session.serve().catch((err) => console.error("session ended:", err));
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
```

`init` instantiates `pancake_host.wasm` (built by `zig build wasm-driver`), builds the runtime
adapter over it, installs the adapter, and only then loads `@pancake/stack`, which binds to it
instead of probing for Deno or Bun. The returned value is the stack module itself, so everything in
[`@pancake/stack`'s README](../stack/README.md) applies: `Session`, `spawn`, `publish`, pipelining,
proxies, three-party redemption.

## The adapter

[`adapter.ts`](adapter.ts) implements the stack's two runtime seams:

- **FFI over linear memory.** The wasm module exports the same `pancake_*` C ABI the dlopen runtimes
  load. JavaScript cannot lend wasm a view of its own buffers, so every buffer argument is copied
  into linear memory before a call and copied back after it (that is how C out-parameters land);
  both copies are the named cost of the linear-memory boundary. Staged copies live in a generational
  arena freed two call-windows later, because a call's returned views legally alias its staged
  inputs.
- **Struct layout from the module itself.** Field offsets differ between the 64-bit dlopen targets
  and wasm32, so the adapter reads the module's own layout descriptor (`pancake_wasm_abi_layout`)
  and hands the stack a layout the marshallers read through (`stack/internal/layout.ts`). The
  descriptor, the generated manifest in `@pancake/abi`, and the 64-bit mirror are held in lockstep
  by `zig build wasm-abi-layout-check`.
- **One callback seam.** The module imports exactly `env.pancake_behavior_trampoline`
  (`zig build wasm-import-check` pins it). Every wasm-hosted object dispatches through it by ctx id,
  so `spawn` and `publish` work in the browser; a custom-allocator `Context` is the one dlopen-only
  feature and refuses loudly.
- **Sockets over WebSocket.** `connect` opens a WebSocket to `ws://host:port/` by default; pass
  `wsUrl` to route every dial through a byte gateway instead. The socket carries raw OCapN frames
  (the host's stream delimiter owns framing), so the accepting side is a byte bearer, never a
  protocol translator. A browser cannot bind a listener; `listen` refuses. Neither direction is
  bounded yet: `write` resolves when the socket buffers the bytes, and inbound chunks queue until
  read, so a peer streaming faster than its partner processes grows tab memory.

## Byte-transparent relay

Browser peers cannot dial native sockets directly. A relay endpoint accepts a WebSocket connection
and forwards bytes to a target TCP locator without parsing CapTP frames, so the keyed handshake and
session authority run end to end unchanged. Pass `wsUrl` to `init()` with a function that maps
`(host, port)` to the relay's URL, for example `` (h, p) => `ws://relay/relay?to=${h}:${p}` ``. The
reference relay ships as [`@pancake/relay`](../relay/README.md). The rooms app wraps it at
[`apps/rooms/web/relay.ts`](../../../apps/rooms/web/relay.ts), which allow-lists the room server's
own port for TCP targets, checks the `Origin` header on the upgrade, caps live sessions, times out
idle pairs, and bounds bytes per session. `zig build deno-relay-test` proves a keyed OCapN session
from this binding through that relay to a native TCP host.

## The proof

`zig build web-peer-test` runs [`test/web_peer_test.ts`](test/web_peer_test.ts): a native host
([`test/serve_ws_host.ts`](test/serve_ws_host.ts)) accepts WebSocket connections straight into
`Session.establishAccepted`, and a second process loads the stack through `@pancake/web` — wasm
module, linear-memory FFI, WebSocket channel, no `Deno.dlopen` anywhere in its graph — completes the
keyed handshake inside the wasm peer, fetches and calls a published object, and receives a call back
into an object the wasm peer hosts. Deno supplies the same `WebAssembly`/`WebSocket` globals a
browser does, which keeps the check in-tree and socket-real at once.

[`test/wasm_handshake_smoke.ts`](test/wasm_handshake_smoke.ts) (`zig build
wasm-driver-test`) is the layer
below: two wasm Hosts complete the keyed handshake over an in-memory byte pipe, driven through raw
exports with no binding at all.

## What a real page needs

Serve `pancake_host.wasm` (from `zig-out/wasm/` or a release) and bundle this package plus
`@pancake/stack` and `@pancake/abi`, using [`browser-bundle.json`](browser-bundle.json) as the
bundler config. The stack's module graph is browser-clean: the archive-resolution cascade loads its
host built-ins dynamically and degrades away when they are absent, so a bundler ships no `node:`
shims.

Keep the stack free of module-level top-level `await`. `deno bundle` (esbuild) flattens every
module's top-level await into one file, where the stack's import graph deadlocks around one. That is
why `internal/ffi/runtime.ts` resolves its adapter synchronously and the archive symbol tables
`dlopen` lazily on first use rather than at module load.

Browser-to-browser transport ships as [`@pancake/webrtc`](../webrtc/README.md), a direct DTLS
DataChannel opened through a signaling capability; `zig build webrtc-browser-to-browser` holds two
Chromium peers on one.
