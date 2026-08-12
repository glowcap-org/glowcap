# @pancake/stack

The core multi-runtime JavaScript/TypeScript consumer of the pancake C ABI archives: a full OCapN
node over the separate `libpancake_host` and `libpancake_driver` archives (ADR-0112). The Host
archive owns the byte-fed family; the driver exports only its loop verbs, adopts a Host through
`pancake_driver_take_host`, and starts with zero providers. The TCP archive supplies the complete
plain, keyed, and sealed provider package through the common provider ABI. The relay archive does
the same for keyed and sealed relay profiles. It covers values,
capabilities, actors, and locator URIs. It exposes the async `Session` and `Server` — on Deno an
ordinary `connect`/`listen` runs on a stepping native loop, and the byte-fed pump over the runtime's
own networking remains for the shapes the loop does not carry. `listenNoiseTcp` returns its
key-plus-address locator. The low-level
blocking transports remain `tcp` and `inproc`. The optional
encrypted-QUIC transport ships separately as [`@pancake/iroh`](../iroh/README.md).

One source, three runtimes: all runtime coupling (the FFI, the sockets, and the struct layout) lives
behind a thin seam in [`internal/ffi/runtime.ts`](internal/ffi/runtime.ts), which binds an injected
adapter when one was installed before load (that is how [`@pancake/web`](../web/README.md) runs this
same module in a browser over WebAssembly) and otherwise detects the host and `import()`s the
matching adapter, so `bun:ffi` never loads on the wrong runtime. The binding is à-la-carte, exactly
like the archives it rides (ADR-0059): you import the core plus whichever transports you want, and
each module opens only its own archive. See [`../../README.md`](../../README.md) for the shipped C
ABI surface and how the bindings are gated.

## Runtimes

| Runtime                  | Tier                 | FFI seam               | How it runs                               |
| ------------------------ | -------------------- | ---------------------- | ----------------------------------------- |
| [Deno](https://deno.com) | tested (build check) | `Deno.dlopen`          | `deno run --allow-ffi --allow-read`       |
| [Bun](https://bun.sh)    | tested (build check) | `bun:ffi`              | `bun run`                                 |
| Browser                  | tested (build check) | WebAssembly (ADR-0070) | [`@pancake/web`](../web/README.md) `init` |

Deno and Bun each have a `zig build` binding check (`deno-dogfood`, `bun-dogfood`), and the browser
path has `web-peer-test`. Deno's check covers the native-loop application surface. Bun's check
covers the synchronous Host and locator ABI and proves that native-loop and blocking transport
lifecycles fail closed; any other runtime is refused at load with a clear error rather than
half-working.

## The modules

The public surface is one core module plus one module per built-in transport, declared in
[`deno.json`](deno.json)'s `exports` map (the JSR manifest; the same `exports` reach Bun). Each maps
to an archive and opens only that archive through the runtime shim's `dlopen`, so importing the core
never loads a transport and importing one transport never loads another.

| Import                            | File                                         | Archive it opens                                                                                                                                                                 |
| --------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@pancake/stack`                  | [`mod.ts`](mod.ts)                           | `libpancake_host` and `libpancake_driver` (the byte-fed Host plus the native loop) plus `libpancake_ocapn`'s shared vocabulary (values, locator URIs, the allocation context) |
| `@pancake/stack/transport/tcp`    | [`transport/tcp.ts`](transport/tcp.ts)       | `libpancake_net_transport_tcp`: the complete TCP provider package plus the blocking `Netlayer`/`Listener`/`Connection` frame shuttle |
| `@pancake/stack/transport/inproc` | [`transport/inproc.ts`](transport/inproc.ts) | `libpancake_net_transport_inproc`: the socket-free in-process `Netlayer`/`Listener`/`Connection`                                                                                   |
| `@pancake/stack/transport/onion`  | [`transport/onion.ts`](transport/onion.ts)   | `libpancake_net_transport_onion`: Tor SOCKS/control operations dispatched through Deno's off-thread FFI                                                                         |
| `@pancake/stack/transport/relay`  | [`transport/relay.ts`](transport/relay.ts)   | `libpancake_net_transport_relay`: the complete `keyed-relay`/`noise-relay` provider package for the native driver loop                                                          |
| `@pancake/stack/ffi`              | [`ffi.ts`](ffi.ts)                           | the native seam (`ffi`, `Ptr`, `Symbols`, `libPath`, ABI constants) a transport-companion package such as `@pancake/iroh` plugs into, not for applications                       |

The optional encrypted-QUIC transport is a separate package, [`@pancake/iroh`](../iroh/README.md),
so a consumer that never speaks iroh never installs the Rust-sidecar artifact. `connect` reaches it
lazily (`import("@pancake/iroh/internal")` on the first `iroh` locator), so the core never
hard-depends on it. Application code never imports that internal dial entry.

The core is usable standalone. The transport modules build on it (they share the `Context` pointer
and the frame/context type layout, and they are symbol-disjoint), but never on each other. Inside
the core, sibling modules split by responsibility: `promise`, `gc`, `dial`, `listen`, `session`,
`pump`, `action`, `driver_loop`, and `host`. `mod.ts` is only the barrel. The internal loaders live under
[`internal/ffi/`](internal/ffi/) (one per archive). The generated ABI mirror splits by target
dependence: `zig build gen-ts-abi` writes the target-independent constant values into the
`@pancake/abi` package (`bindings/ts/abi/constants.ts`) and the 64-bit struct layouts into
[`internal/abi.ts`](internal/abi.ts); [`internal/layout.ts`](internal/layout.ts) holds the active
layout (that 64-bit mirror, or the wasm module's own descriptor under the browser adapter), and
every struct marshaller reads through it. A consumer never imports any of those.

## The core

`mod.ts` is the idiomatic JavaScript/TypeScript API over the byte-fed host. An application holds a
`Session`: `publish`/`fetch` name capabilities, `send` returns an awaitable (and pipelinable)
`RemotePromise`, `spawn` hosts a plain callback as an actor, and `serve` runs the inbound loop. The
library owns every CapTP decision: routing, three-party redemption, gift origination, and far vows.
The binding moves bytes and honors the host's action queue. Integers are `bigint`, floats are
`number`:

```ts
import { connect, tcpLocator } from "@pancake/stack";

// tcp: the peer is a place, a cleartext host and port.
const partner = tcpLocator("127.0.0.1", 9099);

const session = await connect(partner);
session.serve().catch((err) => console.error("session ended:", err));

const greeter = await session.fetch("greeter"); // a capability, by name
try {
	const reply = await session.send(greeter, "greet", ["world"]);
	console.log(reply);
} catch (reason) {
	console.error("the greeter refused:", reason);
}

await session.close();
```

The high-level `connect`/`listen` ride the runtime's networking, so a program that dials a `tcp`
locator or hosts a `Server` needs only the core module. `connect` imports `@pancake/iroh` lazily on
the first `iroh` locator, so a program that never speaks iroh never loads
`libpancake_net_transport_iroh`.

`listenNoiseTcp` accepts an optional 32-byte durable seed and exposes `uri()`;
ordinary `connect` routes that locator through the same native loop on Deno.

A routed relay locator carries a `rendezvous-relay` hint. On Deno, `connect`
loads the relay archive lazily and installs its provider into the native loop.
A bare relay locator instead uses the Host's configured rendezvous callback and
the runtime WebSocket byte channel; this is an explicit deployment fallback,
not transport dispatch duplicated in the binding.

`listen` and `listenKeyedTcp` accept `ListenOptions` for the optional
`advertisedHost`. A wildcard bind requires it; binding an interface does not
prove a dialable route and pancake will not sign the wildcard into a Host
locator. The native driver owns admission and handshake concurrency.

## The transports

`transport/tcp.ts` and `transport/inproc.ts` expose the C ABI's frame shuttle directly: a
`Netlayer` binds a `Listener` and asynchronously dials a `Connection`; accepting, reading, and
writing are asynchronous because a supported runtime moves each potentially parking native call
off its JavaScript reactor.
TCP binds a `host:port`; inproc binds a string designator and moves frames through in-process pipes
with no kernel transport.

`writeFrame` takes ownership through one immediate copy, so its caller may
mutate the supplied bytes as soon as the method returns. Concurrent writes are
serialized under a bounded queue: its byte waterline is the connection's
`maxFrameBytes`, no single write or admitted set may cross that line, and at
most 16 writes may be pending. A call beyond either bound rejects instead of
retaining more payloads or promise closures.

```ts
import { Netlayer } from "@pancake/stack/transport/inproc";

await using net = new Netlayer();
await using listener = net.listen("rooms");
await using client = await net.connect("rooms");
await using server = await listener.accept();
await client.writeFrame(frame);
const got = await server.readFrame();
```

Child disposal requests shutdown synchronously. `await using` on the netlayer
also waits for every child release and the borrowed native backend to retire.

Each transport routes its own failures through its own `pancake_<t>_last_error` slot, so a transport
call's diagnostic never scrapes the core's unrelated one.

The raw TCP, inproc, and onion shuttles are asynchronous only on a runtime that
really moves a potentially parking native call off the JavaScript event loop.
Deno does; Bun's FFI currently executes the call synchronously, so those
native transports refuse construction before allocating a handle: even an idle
release may join backend work. Core TCP/inproc sessions remain supported on both
runtimes through their runtime-native adapters. A Bun raw-transport adapter
needs a worker-owned native executor with handle lifetime, cancellation, and
release kept inside that executor.

## Build checks

[`../dogfood/zig_smoke.ts`](../dogfood/zig_smoke.ts) is the one consumer both
`zig build deno-dogfood` and `zig build bun-dogfood` run. Deno drives real OCapN conversations
through the application API (fetch/send, pipelining, projections, proxies, GC, both codecs) and
shuttles a frame through both the TCP and in-process transports. Bun proves the common synchronous
Host, locator, and sturdyref surface and the explicit refusal boundary for operations its FFI
cannot move off the JavaScript event loop. Deno's FFI needs `--allow-ffi --allow-read`; the build
step passes them and resolves the shared libraries relative to `zig-out/`.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
