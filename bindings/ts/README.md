# TypeScript binding

This workspace runs one TypeScript API on Deno and Bun, with a WebAssembly
entry for browsers. The packages are not published yet; use them from a pinned
checkout after running `zig build`.

```ts
import { connect, tcpLocator } from "@pancake/stack";

const session = await connect(tcpLocator("127.0.0.1", 9099));
session.serve().catch((err) => console.error("session ended:", err));

const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));

await session.close();
```

## Packages

| Package | Purpose |
| --- | --- |
| [`@pancake/stack`](stack/README.md) | The native `Session`, `Host`, values, locators, TCP, and in-process transports. |
| [`@pancake/iroh`](iroh/README.md) | Optional encrypted QUIC transport. It is loaded only for an iroh locator. |
| [`@pancake/web`](web/README.md) | The same host and session API compiled to WebAssembly. |
| `@pancake/webrtc` | A WebRTC DataChannel opened through a signaling capability. |
| [`@pancake/relay`](relay/README.md) | A byte-transparent relay for browser peers that cannot open sockets. |
| `@pancake/abi` | Generated ABI constants used by the other packages. |

Runtime-specific FFI and socket code stays behind an adapter selected at load
time, so Deno never loads Bun FFI and Bun never loads Deno FFI.

On the native path the stack loads the symbol-disjoint `libpancake_host` and
`libpancake_driver` archives. The driver adopts a quiescent Host and receives
archive-owned provider packages: one TCP package owns TCP, keyed TCP, and
Noise TCP, while the optional iroh package owns its dial and listener halves.
On Deno those providers run on one stepping driver loop that owns readiness,
pumping, and admission. Explicit keyed-relay channels, Bun, and the browser
keep the byte-fed Host path.

## What is checked

| Runtime | Recurring evidence | Still manual |
| --- | --- | --- |
| Deno | Application round trips, live Goblins client and listener, handoff, relay, and iroh checks. | None known in the supported native path. |
| Bun | Host identity/lifetime, locator and sturdyref ABI, and fail-closed native-loop/transport admission. | Hosted application round trips, live Goblins, and iroh checks. |
| Browser | WebAssembly handshake, ABI layout, and import checks. | Real Chromium, WebRTC, mesh, and cold-dial scenarios. |

`@pancake/web` uses the same byte-fed host as the native binding. JavaScript
supplies the channel, whether that is a WebSocket relay or a WebRTC
DataChannel.

## Run the checks

```sh
zig build deno-dogfood
zig build bun-dogfood
zig build wasm-driver-test
zig build wasm-abi-layout-check
zig build wasm-import-check
```

`zig build bindings` runs the native binding checks together. The
[binding overview](../README.md) describes the shared session API.
