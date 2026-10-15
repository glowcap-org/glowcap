# TypeScript binding

This workspace runs one TypeScript API on Deno and Bun, with a WebAssembly
entry for browsers. Pin a checkout, run `zig build`, and use the packages from
the tree.

```ts
import { Runtime } from "@glowcap/runtime";
import { noise, provider } from "@glowcap/tcp";

const peerKey = "<64 lowercase hex characters from the server>";
await using runtime = await Runtime.open({ providers: [provider()] });
await using session = await runtime.connect(
	noise.locator(peerKey, "127.0.0.1", 9099),
);
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
```

## Packages

| Package | Purpose |
| --- | --- |
| [`@glowcap/runtime`](runtime/README.md) | The `Session`, `Host`, OCapN values, and generic driver. |
| [`@glowcap/iroh`](iroh/README.md) | Optional encrypted QUIC provider and listener. |
| `@glowcap/onion` | Tor onion provider, listener, and raw transport handles. |
| [`@glowcap/relay`](relay/README.md) | A byte-transparent relay for browser peers that cannot open sockets. |
| [`@glowcap/webrtc`](webrtc/README.md) | A WebRTC DataChannel opened through a signaling capability. `/driver` is the Deno provider and listener: it dials a `webrtc` locator and accepts offers on the driver loop. |
| [`@glowcap/web`](web/README.md) | The same host and session API compiled to WebAssembly. |
| `@glowcap/tcp` | TCP-profile locator constructors and C driver listeners. `/transport` exposes provider installation and blocking frame handles. |
| `@glowcap/inproc` | Socket-free in-process frame transport for tests and programs that keep every peer in one process. |
| `@glowcap/abi` | Generated ABI constants used by the other packages. |

An adapter selected at load time holds the runtime-specific FFI and socket
code, so Deno never loads Bun FFI and Bun never loads Deno FFI.

On Deno, TCP, iroh, and WebRTC connections run on glowcap's driver loop. Bun, the
browser, and explicit keyed-relay channels use the byte-fed Host instead.
[Developing a binding](../DEVELOPING.md) explains both paths.

## Run the checks

[Stability](../../docs/stability.md) says what is checked on Deno, Bun, and
the browser.

```sh
zig build deno-dogfood
zig build bun-dogfood
zig build wasm-driver-test
zig build wasm-abi-layout-check
zig build wasm-import-check
```

`zig build bindings` runs the binding checks together. The
[binding overview](../README.md) describes the shared session API.

`@glowcap/web` uses the same byte-fed Host as Deno and Bun. JavaScript supplies
the channel, either a WebSocket relay or a WebRTC DataChannel.
