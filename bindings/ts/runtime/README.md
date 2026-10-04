# @glowcap/runtime

`@glowcap/runtime` is the core JavaScript and TypeScript package for glowcap.
It runs a full OCapN node on Deno and Bun over the glowcap C ABI. It covers
values, capabilities, actors, and locator URIs, and offers the async `Session`
and `Host` API, which does not depend on any transport.

How it is built:

- It loads the separate `libglowcap_host` and `libglowcap_driver` archives
  (ADR-0112). The Host archive handles byte-fed sessions. The driver exports
  only its loop functions, adopts a Host through `glowcap_driver_take_host`,
  and starts with no providers.
- The TCP archive supplies the plain, keyed, and sealed TCP providers through
  the common provider ABI. The relay archive does the same for the keyed and
  sealed relay profiles.
- On Deno, a `Runtime.connect` that uses a provider runs on a native loop that
  the binding steps. Transport packages build their listeners and return a
  `Server` on that same loop.
- The byte-fed pump is still used for channels the runtime owns, and the
  low-level blocking transports stay available for embedding.

The optional encrypted-QUIC transport ships separately as
[`@glowcap/iroh`](../iroh/README.md).

One source, three runtimes: all runtime coupling (the FFI, the sockets, and the struct layout) lives
behind a thin seam in [`internal/ffi/runtime.ts`](internal/ffi/runtime.ts), which binds an injected
adapter when one was installed before load (that is how [`@glowcap/web`](../web/README.md) runs this
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
| Browser                  | tested (build check) | WebAssembly (ADR-0070) | [`@glowcap/web`](../web/README.md) `init` |

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
| `@glowcap/runtime` | [`mod.ts`](mod.ts) | `libglowcap_host`, `libglowcap_driver`, and the shared OCapN vocabulary |
| `@glowcap/runtime/transport` | [`transport.ts`](transport.ts) | Transport-package authoring contract; not an application import |
| `@glowcap/tcp` | [`../tcp/mod.ts`](../tcp/mod.ts) | TCP-profile locators, provider construction, and listeners |
| `@glowcap/tcp/transport` | [`../tcp/transport.ts`](../tcp/transport.ts) | TCP provider package plus blocking frame handles |
| `@glowcap/inproc` | [`../inproc/mod.ts`](../inproc/mod.ts) | Socket-free in-process frame transport |
| `@glowcap/onion` | [`../onion/mod.ts`](../onion/mod.ts) | Tor provider, listener, and raw transport handles |
| `@glowcap/relay` | [`../relay/mod.ts`](../relay/mod.ts) | `keyed-relay` and `noise-relay` provider package |
| `@glowcap/runtime/ffi` | [`ffi.ts`](ffi.ts) | Native FFI seam used by transport packages; not an application import |

The optional encrypted-QUIC transport is a separate package, [`@glowcap/iroh`](../iroh/README.md),
so a consumer that never speaks iroh never installs the Rust-sidecar artifact. Applications compose
its `provider(config)` or `connector(config)` explicitly when opening a Runtime; the generic core
never imports or dispatches to a concrete transport.

The core does not depend on any transport. The value and Host APIs work on
their own, and a Runtime that connects needs a provider or connector you add
explicitly.

- The transport modules build on the core but never on each other. They share
  the `Context` pointer and the frame and context type layouts, and they
  export no overlapping symbols.
- Inside the core, modules are split by responsibility: `promise`, `gc`,
  `dial`, `session`, `pump`, `action`, `driver_loop`, and `host`. `mod.ts`
  only re-exports them.
- The internal loaders live under [`internal/ffi/`](internal/ffi/), one per
  archive.
- `zig build gen-ts-abi` generates the ABI mirror in two parts. The constant
  values, which do not depend on the target, go into the `@glowcap/abi`
  package (`bindings/ts/abi/constants.ts`). The 64-bit struct layouts go into
  [`internal/abi.ts`](internal/abi.ts).
- [`internal/layout.ts`](internal/layout.ts) holds the active layout: the
  64-bit mirror, or the Wasm module's own descriptor in the browser. Every
  struct marshaller reads through it.

Applications never import any of these internals.

## The core

`mod.ts` is the application API for JavaScript and TypeScript. A Runtime owns one Host and the
providers or connectors you gave it. An application works with a `Session`:

- `publish` and `fetch` name capabilities.
- `send` returns a `RemotePromise` you can await, or send through before it settles.
- `spawn` hosts a plain callback as an actor.
- `serve` runs the inbound loop.

The library makes every CapTP decision: routing, three-party redemption, gift creation, and far
vows. The binding only moves bytes and follows the Host's action queue. Integers are `bigint`, floats are
`number`:

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

`Runtime.open` commits the selected transport authority once. `Runtime.connect`
selects only among those retained providers or connectors; it never infers a
transport implementation from a locator.
Passing `adoptHost` explicitly transfers an existing Host into the Runtime;
`Runtime.close()` is then that Host's terminal shutdown barrier.

`tcp.noise.listen` accepts an optional 32-byte durable seed; `Runtime.connect` routes its
key-plus-address locator through the same native loop on Deno.

A relay Runtime composes `provider(config)` from `@glowcap/relay`; locator hints
select a route within that transport package, not which package the Runtime loads.

All three TCP-profile listeners accept `ListenOptions` for `host`, `codec`, and
the optional `advertisedHost`; keyed and Noise listeners also accept `seed`.
A wildcard bind requires an advertised host; binding an interface does not
prove a dialable route and glowcap will not sign the wildcard into a Host
locator. The native driver owns admission and handshake concurrency.

## The transports

`@glowcap/tcp/transport` and `@glowcap/inproc` expose the C ABI's raw frame transport directly. A
`Netlayer` binds a `Listener` and dials a `Connection`. Dialing, accepting, reading, and writing are
all asynchronous, because each native call that might block runs off the JavaScript event loop.
TCP binds a `host:port`; inproc binds a string designator and moves frames through in-process pipes
with no kernel transport.

`writeFrame` takes ownership through one immediate copy, so its caller may
mutate the supplied bytes as soon as the method returns. Concurrent writes are
serialized under a bounded queue: its byte waterline is the connection's
`maxFrameBytes`, no single write or admitted set may cross that line, and at
most 16 writes may be pending. A call beyond either bound rejects instead of
retaining more payloads or promise closures.

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
also waits for every child release and the borrowed native backend to retire.

Each transport routes its own failures through its own `glowcap_<t>_last_error` slot, so a transport
call's diagnostic never scrapes the core's unrelated one.

Callerless failures are separate from returned errors and close barriers.
`Host.takeFailures()` atomically claims the bounded records owned by that
Host's Context. `takeRuntimeFailures()` claims the process queue used only when
no usable Context survives or Context recording itself fails. Saturation is
visible through `droppedBefore`; neither queue makes a failure fatal or changes
an operation's outcome.

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
zig build bindings        # builds the glowcap archives, runs every binding consumer
```

The `@glowcap/runtime/cleanup` subpath provides bounded secondary-error custody
and ordered rollback helpers without importing a Host or FFI adapter. The same
helpers remain exported from `@glowcap/runtime`; both paths share one custody map.
