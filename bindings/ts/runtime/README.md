# @glowcap/runtime

`@glowcap/runtime` is the core JavaScript and TypeScript package for glowcap.
It runs a full OCapN node on Deno and Bun over the glowcap C ABI. It covers
values, capabilities, actors, and locator URIs, and offers the async `Session`
and `Host` API, which does not depend on any transport.

It is built as follows:

- It loads the separate `libglowcap_host` and `libglowcap_driver` archives
  (ADR-0112). The Host archive handles byte-fed sessions. The driver exports
  only its loop functions, adopts a Host through `glowcap_driver_take_host`,
  and starts with no providers.
- The TCP archive supplies the plain, keyed, and sealed TCP providers through
  the common provider ABI. The relay archive does the same for the keyed and
  sealed relay profiles.
- On Deno, a `Runtime.connect` that uses a provider runs on a driver loop that
  the binding steps. Transport packages build their listeners and return a
  `Server` on that same loop.
- The byte-fed pump serves channels the runtime owns, and the low-level
  blocking transports are available for programs that run their own loop.

The optional encrypted-QUIC transport ships separately as
[`@glowcap/iroh`](../iroh/README.md), so an application that never uses iroh
never installs its Rust library. Pass its `provider(config)` or
`connector(config)` when opening a Runtime.

The same source runs on Deno, Bun, and the browser. Everything that differs between them (the FFI,
the sockets, and the struct layout) lives in
[`internal/ffi/runtime.ts`](internal/ffi/runtime.ts). That module uses an
adapter injected before load, which is how [`@glowcap/web`](../web/README.md)
runs this package in a browser over WebAssembly. Otherwise it detects the
runtime and `import()`s the matching adapter, so `bun:ffi` never loads on the
wrong runtime.

[`../../README.md`](../../README.md) describes the API all bindings share.

## Runtimes

| Runtime                  | Tier                 | FFI                    | How it runs                               |
| ------------------------ | -------------------- | ---------------------- | ----------------------------------------- |
| [Deno](https://deno.com) | tested (build check) | `Deno.dlopen`          | `deno run --allow-ffi --allow-read`       |
| [Bun](https://bun.sh)    | tested (build check) | `bun:ffi`              | `bun run`                                 |
| Browser                  | tested (build check) | WebAssembly (ADR-0070) | [`@glowcap/web`](../web/README.md) `init` |

Deno and Bun each have a `zig build` binding check (`deno-dogfood`, `bun-dogfood`), and the browser
path has `web-peer-test`. Deno's check covers the driver-loop application API. Bun's check
covers the synchronous Host and locator ABI and shows that driver-loop and blocking transport
lifecycles refuse with an error. Any other runtime is refused at load with an error.

## The modules

The public API is one core module plus one module per built-in transport, declared in
[`deno.json`](deno.json)'s `exports` map (the JSR manifest, which Bun also reads). Each maps
to an archive and opens only that archive through the runtime shim's `dlopen`, as the C libraries
do (ADR-0059), so an import loads only what it needs.

| Import                            | File                                         | Archive it opens                                                                                                                                                                 |
| --------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@glowcap/runtime` | [`mod.ts`](mod.ts) | `libglowcap_host`, `libglowcap_driver`, and the shared OCapN vocabulary |
| `@glowcap/runtime/transport` | [`transport.ts`](transport.ts) | Transport-package authoring contract, not an application import |
| `@glowcap/tcp` | [`../tcp/mod.ts`](../tcp/mod.ts) | TCP-profile locators, provider construction, and listeners |
| `@glowcap/tcp/transport` | [`../tcp/transport.ts`](../tcp/transport.ts) | TCP provider package plus blocking frame handles |
| `@glowcap/inproc` | [`../inproc/mod.ts`](../inproc/mod.ts) | Socket-free in-process frame transport |
| `@glowcap/onion` | [`../onion/mod.ts`](../onion/mod.ts) | Tor provider, listener, and raw transport handles |
| `@glowcap/relay` | [`../relay/mod.ts`](../relay/mod.ts) | `keyed-relay` and `noise-relay` provider package |
| `@glowcap/runtime/ffi` | [`ffi.ts`](ffi.ts) | Foreign-function layer for transport packages, not an application import |

The core imports no concrete transport. The value and Host APIs work on their own, and a Runtime
that connects needs a provider or connector that you pass.

- The transport modules build on the core and not on each other. They share
  the `Context` pointer and the frame and context type layouts, and they
  export no overlapping symbols.
- Inside the core, modules are split by responsibility: `promise`, `gc`,
  `dial`, `session`, `pump`, `action`, `driver_loop`, and `host`. `mod.ts`
  re-exports them.
- The internal loaders live under [`internal/ffi/`](internal/ffi/), one per
  archive.
- `zig build gen-ts-abi` generates the ABI mirror in two parts. The constant
  values, which do not depend on the target, go into the `@glowcap/abi`
  package (`bindings/ts/abi/constants.ts`). The 64-bit struct layouts go into
  [`internal/abi.ts`](internal/abi.ts).
- [`internal/layout.ts`](internal/layout.ts) holds the active layout: the
  64-bit mirror, or the Wasm module's own descriptor in the browser. Every
  struct marshaller reads through it.

These files are internal to the package.

## The core

`mod.ts` is the application API for JavaScript and TypeScript. A Runtime owns one Host and the
providers or connectors you passed it. An application works with a `Session`:

- `publish` and `fetch` name capabilities.
- `send` returns a `RemotePromise` you can await, or send through before it settles.
- `spawn` hosts a plain callback as an actor.
- `serve` runs the inbound loop.

The library makes every CapTP decision: routing, three-party redemption, gift creation, and far
vows. The binding moves bytes and follows the Host's action queue. Integers are `bigint` and floats
are `number`:

```ts
import { Runtime } from "@glowcap/runtime";
import { locator, provider } from "@glowcap/tcp";

// tcp: the peer is a place, a cleartext host and port.
const partner = locator("127.0.0.1", 9099);

await using runtime = await Runtime.open({ providers: [provider()] });
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability, by name
console.log(await session.send(greeter, "greet", ["world"]));
```

`Runtime.open` keeps the providers and connectors you pass it. `Runtime.connect`
chooses only among them and does not infer a
transport from a locator. Passing `adoptHost` transfers an existing Host into
the Runtime, and `Runtime.close()` is then that Host's terminal shutdown barrier.

`tcp.noise.listen` accepts an optional 32-byte durable seed. `Runtime.connect` routes its
key-plus-address locator through the same driver loop on Deno.

A relay Runtime uses `provider(config)` from `@glowcap/relay`. Locator hints
select a route within that package and do not choose which package the Runtime
loads.

All three TCP-profile listeners accept `ListenOptions` for `host`, `codec`, and
the optional `advertisedHost`. Keyed and Noise listeners also accept `seed`.
A wildcard bind requires an advertised host, because a bound interface is not
a dialable route and glowcap will not sign the wildcard into a Host locator.
The driver accepts connections and limits concurrent handshakes.

## The transports

`@glowcap/tcp/transport` and `@glowcap/inproc` expose the C ABI's raw frame transport directly. A
`Netlayer` binds a `Listener` and dials a `Connection`. Dialing, accepting, reading, and writing are
all asynchronous, because each call that might block runs off the JavaScript event loop.
TCP binds a `host:port`. Inproc binds a string designator and moves frames through in-process pipes
with no kernel transport.

`writeFrame` copies the frame immediately, so its caller may mutate the
supplied bytes as soon as the method returns. Concurrent writes are serialized
under a bounded queue with two limits: no single write or admitted set may cross
the connection's `maxFrameBytes`, and at most <!-- value transport/ffi_frame.ts maxPendingWrites -->16<!-- /value --> writes may be pending.
A call beyond either limit rejects.

```ts
import { Netlayer } from "@glowcap/inproc";

await using net = new Netlayer();
await using listener = net.listen("rooms");
await using client = await net.connect("rooms");
await using server = await listener.accept();
await client.writeFrame(frame);
const got = await server.readFrame();
```

Child disposal requests shutdown synchronously. `await using` on the netlayer
also waits for every child release and the borrowed backend to retire.

Each transport routes its failures through its own `glowcap_<t>_last_error` slot, so a transport
call's diagnostic never reads the core's.

Callerless failures are separate from returned errors and close barriers.
`Host.takeFailures()` atomically claims the bounded records owned by that
Host's Context. `takeRuntimeFailures()` claims the process queue used only when
no usable Context survives or Context recording itself fails. Saturation is
visible through `droppedBefore`. Neither queue makes a failure fatal or changes an operation's outcome.

The raw TCP, inproc, and onion shuttles are asynchronous only on a runtime that
moves a potentially parking call off the JavaScript event loop. Deno does. Bun's
FFI executes the call synchronously, so those raw transports refuse
construction before allocating a handle, since even an idle release may join
backend work. Core TCP and inproc sessions work on both runtimes through their
runtime adapters.

## Build checks

[`../dogfood/zig_smoke.ts`](../dogfood/zig_smoke.ts) is the one consumer both
`zig build deno-dogfood` and `zig build bun-dogfood` run. Deno drives real OCapN conversations
through the application API (fetch/send, pipelining, result indexing, proxies, GC, both codecs) and
shuttles a frame through both the TCP and in-process transports. Bun proves the common synchronous
Host, locator, and sturdyref API and the explicit refusal boundary for operations its FFI
cannot move off the JavaScript event loop. Deno's FFI needs `--allow-ffi --allow-read`. The build
step passes them and resolves the shared libraries relative to `zig-out/`.

```sh
zig build bindings        # builds the glowcap archives, runs every binding consumer
```

The `@glowcap/runtime/cleanup` subpath runs rollback steps in order and keeps
any failures they raise attached to the original error, up to a fixed count.
It imports no Host or FFI adapter. `@glowcap/runtime` exports the same
helpers, and both paths share one record of attached failures.
