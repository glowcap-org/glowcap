# TypeScript binding

These packages let TypeScript and JavaScript connect to OCapN peers, call their
objects, and host objects of their own. Deno supports the full session API,
with a WebAssembly entry for browsers. Bun supports synchronous Host and locator
calls and byte-fed clients, but cannot run the driver loop or blocking transports.

```sh
deno add jsr:@glowcap/runtime jsr:@glowcap/tcp
```

On first use the runtime package downloads the C libraries of its version from
the GitHub release and verifies them against its checksum file. Set
`GLOWCAP_LIB_DIR` to an extracted C SDK's `lib/` directory to use a local copy.
Run your client with `deno run --allow-all client.ts`. In a checkout of the
repository, run `zig build` and save the client in the repository root, where
the checkout's `deno.json` maps the package names to the tree's sources.

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
| `@glowcap/tcp` | TCP locators and listeners. `/transport` exposes provider installation and blocking frame handles. |
| `@glowcap/inproc` | Socket-free in-process frame transport for tests and programs that keep every peer in one process. |
| `@glowcap/abi` | Generated ABI constants used by the other packages. |

Deno, Bun, and the browser each need their own way to call C library code and open
sockets. The runtime picks the matching adapter when it loads.

On Deno, TCP, iroh, onion, WebRTC, and relay connections run on glowcap's
driver loop, an event loop in the C library that owns the sockets. Bun, the
browser, and explicit keyed-relay channels use the byte-fed Host instead, where
your JavaScript supplies the bytes. [Developing a binding](../DEVELOPING.md)
explains both paths.

## Run the tests

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

`@glowcap/web` uses the same byte-fed Host as Bun. JavaScript supplies
the channel, either a WebSocket relay or a WebRTC DataChannel.
