# bindings/ts

This is the multi-runtime JavaScript/TypeScript consumer of the pancake C ABI archives: one
TypeScript source that runs on Deno and Bun. All runtime coupling (FFI and sockets) lives behind a
thin seam that detects the host at load time and `import()`s the matching adapter, so `bun:ffi`
never loads on the wrong runtime. See [`../README.md`](../README.md) for the shipped C ABI surface
and how every binding is checked.

The API you want is [`@pancake/stack`](stack/README.md), one directory down. The other packages are
optional transports, the browser entry, and generated constants.

```ts
import { connect, tcpLocator } from "@pancake/stack";

const session = await connect(tcpLocator("127.0.0.1", 9099));
session.serve().catch((err) => console.error("session ended:", err));

const greeter = await session.fetch("greeter"); // a capability, by name
console.log(await session.send(greeter, "greet", ["world"]));

session.close();
```

## Packages

The binding is a Deno workspace of six packages, split along the dependency graph. The core and its
built-in transports version together; the optional, externally-cadenced transports iroh and webrtc
version on their own; the browser entry swaps the runtime, not the surface:

| Package                             | Dir                  | What it is                                                                                                                                                                                                                                     |
| ----------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`@pancake/stack`](stack/README.md) | [`stack/`](stack/)   | A full OCapN host over the byte-fed host archive (`libpancake_driver`, ADR-0072): values, capabilities, locators, the async `Session`/`Server`, plus the built-in `tcp` and `inproc` transports and the native seam `@pancake/stack/ffi`       |
| [`@pancake/iroh`](iroh/README.md)   | [`iroh/`](iroh/)     | Optional encrypted-QUIC transport (`libpancake_net_transport_iroh`). Depends on `@pancake/stack`. The core's `connect` reaches it lazily for an `iroh` locator.                                                                                |
| [`@pancake/web`](web/README.md)     | [`web/`](web/)       | The browser entry (ADR-0070 Milestone 1): the same `@pancake/stack` surface over the byte-fed host compiled to `wasm32`, with the byte channel on a WebSocket                                                                                  |
| `@pancake/webrtc`                   | [`webrtc/`](webrtc/) | Optional WebRTC DataChannel transport (`libpancake_net_transport_webrtc`, ADR-0089): a direct DTLS-encrypted channel between two browsers, or a browser and a native peer, opened through a signaling capability. Depends on `@pancake/stack`. |
| [`@pancake/relay`](relay/README.md) | [`relay/`](relay/)   | The byte-transparent relay (ADR-0086) an embedder runs so a socket-less browser can carry its keyed session to a peer that has a socket. Depends on `@pancake/stack`.                                                                          |
| `@pancake/abi`                      | [`abi/`](abi/)       | Generated ABI constants (`zig build gen-ts-abi`), consumed by the packages above                                                                                                                                                               |

## Runtimes

| Runtime                                   | Tier                 | FFI seam           |
| ----------------------------------------- | -------------------- | ------------------ |
| [Deno](https://deno.com)                  | tested (build check) | `Deno.dlopen`      |
| [Bun](https://bun.sh)                     | tested (build check) | `bun:ffi`          |
| Browser ([`@pancake/web`](web/README.md)) | tested (build check) | wasm linear memory |

## Build checks

[`dogfood/zig_smoke.ts`](dogfood/zig_smoke.ts) is the one consumer both `zig build deno-dogfood` and
`zig build bun-dogfood` run. The same source runs on both runtimes, driving real OCapN conversations
through the application API and shuttling a frame through both built-in transports.
[`dogfood/gifter_handoff.ts`](dogfood/gifter_handoff.ts) is the `zig build deno-gifter-handoff`
consumer: a pancake-only three-party handoff where a broker's introduction is redeemed transparently
and the recipient messages the exporter directly.

The browser binding ships as [`@pancake/web`](web/README.md)
([ADR-0070](../../docs/decisions/adr/ADR-0070-browser-binding-via-wasm.md) Milestone 1).
`zig build wasm-driver` compiles the byte-fed host to WebAssembly; `zig build web-peer-test` proves
the browser peer holds a keyed OCapN session over WebSocket against a native host, with
`zig build wasm-abi-layout-check` and `zig build wasm-import-check` holding the wasm module's layout
descriptor and import set. The lower-level seed check remains:
[`web/wasm_handshake_smoke.ts`](web/wasm_handshake_smoke.ts) (`zig build wasm-driver-test`) drives
two Hosts through a keyed handshake entirely from JavaScript over an in-memory byte pipe.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
