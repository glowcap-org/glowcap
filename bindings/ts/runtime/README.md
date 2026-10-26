# @glowcap/runtime

`@glowcap/runtime` is the core JavaScript and TypeScript package for glowcap. It provides values,
capabilities, actors, locator URIs, and the async `Session` and `Host` API on Deno and in the
browser through [`@glowcap/web`](../web/README.md). Bun supports the synchronous Host and locator
API and byte-fed clients, but cannot run the driver loop or blocking transports. The API does not depend on any
transport, so you also install a transport package.

## How it is built

- It loads two C libraries. `libglowcap_host` handles byte-fed sessions, where your code supplies
  the bytes. `libglowcap_driver` runs the event loop (the driver loop) that owns sockets. It starts
  with no transports and adopts a Host through `glowcap_driver_take_host`. A separate library per
  transport keeps unused code out of your program (ADR-0024).
- The TCP library supplies the plain, keyed, and sealed TCP transports. The relay library does the
  same for the keyed and sealed relay transports.
- On Deno, a `Runtime.connect` that uses a provider runs on a driver loop that
  the binding steps. Transport packages build their listeners and return a
  `Server` on that same loop.
- The byte-fed pump serves channels the runtime owns, and the low-level
  blocking transports are available for programs that run their own loop.

The optional encrypted-QUIC transport ships separately as
[`@glowcap/iroh`](../iroh/README.md), so an application that never uses iroh
never installs its Rust library. Pass its `provider(config)` or
`connector(config)` when opening a Runtime.

The same source runs on Deno, Bun, and the browser. The parts that differ (how to call the C
library, how to open sockets, and struct layout) live in
[`internal/ffi/runtime.ts`](internal/ffi/runtime.ts). A browser build injects its own adapter
first, which is how [`@glowcap/web`](../web/README.md) runs this package over WebAssembly.
Otherwise the module detects the runtime and imports the matching adapter, so `bun:ffi` never
loads on the wrong runtime.

[`../../README.md`](../../README.md) describes the API all bindings share.

## Runtimes

| Runtime                  | Tier                 | FFI                    | How it runs                               |
| ------------------------ | -------------------- | ---------------------- | ----------------------------------------- |
| [Deno](https://deno.com) | tested (build check) | `Deno.dlopen`          | `deno run --allow-ffi --allow-read`       |
| [Bun](https://bun.sh)    | tested (build check) | `bun:ffi`              | `bun run`                                 |
| Browser                  | tested (build check) | WebAssembly (ADR-0034) | [`@glowcap/web`](../web/README.md) `init` |

Deno and Bun each have a `zig build` test (`deno-dogfood`, `bun-dogfood`), and the browser path has
`web-peer-test`. Deno's test covers the application API over the driver loop. Bun's covers the
synchronous Host and locator API and checks that driver-loop and blocking transports refuse with an
error. Any other runtime is refused at load with an error.

## The modules

The public API is one core module plus one module per built-in transport, declared in
[`deno.json`](deno.json)'s `exports` map (the JSR manifest, which Bun also reads). Each maps
to an archive and opens only that archive through the runtime shim's `dlopen`, as the C libraries
do (ADR-0022), so an import loads only what it needs.

| Import                            | File                                         | Archive it opens                                                                                                                                                                 |
| --------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@glowcap/runtime` | [`mod.ts`](mod.ts) | `libglowcap_host`, `libglowcap_driver`, and the shared OCapN vocabulary |
| `@glowcap/runtime/transport` | [`transport.ts`](transport.ts) | For authors of a transport package. Applications do not import it. |
| `@glowcap/tcp` | [`../tcp/mod.ts`](../tcp/mod.ts) | TCP-profile locators, provider construction, and listeners |
| `@glowcap/tcp/transport` | [`../tcp/transport.ts`](../tcp/transport.ts) | TCP provider package plus blocking frame handles |
| `@glowcap/inproc` | [`../inproc/mod.ts`](../inproc/mod.ts) | Socket-free in-process frame transport |
| `@glowcap/onion` | [`../onion/mod.ts`](../onion/mod.ts) | Tor provider, listener, and raw transport handles |
| `@glowcap/relay` | [`../relay/mod.ts`](../relay/mod.ts) | `keyed-relay` and `noise-relay` provider package |
| `@glowcap/runtime/ffi` | [`ffi.ts`](ffi.ts) | Foreign-function layer for transport packages, not an application import |

The core imports no concrete transport. The value and Host APIs work on their own, and a Runtime
that connects needs a provider or connector that you pass.

The transport modules build on the core and not on each other. They share the `Context` pointer
and the frame and context type layouts, and they export no overlapping symbols. Everything else
below is internal to the package, so an application does not need it:

- The core is split by responsibility into `promise`, `gc`, `dial`, `session`, `pump`, `action`,
  `driver_loop`, and `host`, and `mod.ts` re-exports them.
- The loaders live under [`internal/ffi/`](internal/ffi/), one per C library.
- `zig build gen-ts-abi` generates the mirror of the C library's constants and struct layouts. The
  constants go into the `@glowcap/abi` package (`bindings/ts/abi/constants.ts`) and the 64-bit
  struct layouts into [`internal/abi.ts`](internal/abi.ts).
- [`internal/layout.ts`](internal/layout.ts) holds the active layout, which is the 64-bit mirror or
  the Wasm module's own descriptor in the browser. Every struct marshaller reads through it.

## The core

`mod.ts` is the application API for JavaScript and TypeScript. A Runtime owns one Host and the
providers or connectors you passed it. An application works with a `Session`:

- `publish` and `fetch` name capabilities.
- `send` returns a `RemotePromise` you can await, or send through before it settles.
- `spawn` hosts a plain callback as an actor.
- `serve` runs the inbound loop.

The glowcap C library makes every CapTP decision, including routing, three-party handoffs, and
sending promises to other peers. The binding moves bytes and carries out the Host's instructions.
Integers are `bigint` and floats are `number`:

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

`Runtime.open` keeps the transports you pass it, and `Runtime.connect` chooses only among them.
It does not infer a transport from a locator. Passing `adoptHost` moves an existing Host into the
Runtime, and `Runtime.close()` then shuts that Host down for good.

A relay Runtime uses `provider(config)` from `@glowcap/relay`. Locator hints select a route
within that package and do not choose which package the Runtime loads.

Listening:

- `tcp.noise.listen` accepts an optional 32-byte durable seed. `Runtime.connect` routes its
  key-plus-address locator through the same driver loop on Deno.
- All three TCP listeners (plain, keyed, and Noise) accept `ListenOptions` for `host`, `codec`,
  and the optional `advertisedHost`. Keyed and Noise listeners also accept `seed`.
- A wildcard bind requires `advertisedHost`, the name or address partners dial, because glowcap
  will not put a wildcard into a Host locator.
- The driver accepts connections and limits concurrent handshakes.

## The transports

Most applications use the transports above. `@glowcap/tcp/transport` and `@glowcap/inproc` expose
the lower-level frame transport directly, for programs that run their own loop. A `Netlayer` (the
OCapN term for a transport) binds a `Listener` and dials a `Connection`. Dialing, accepting, reading, and writing are
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

Some failures happen where no caller is waiting, such as a background send that fails after its
caller has moved on. They are not returned as errors. `Host.takeFailures()` atomically returns
and clears the bounded list of those failures recorded for that Host. `takeRuntimeFailures()` does the same
for a process-wide list, used only when no usable Context survives or recording on the Context
fails. When a list overflows, `droppedBefore` reports how many records were lost. Neither list
makes a failure fatal or changes an operation's outcome.

The raw TCP, inproc, and onion shuttles are asynchronous only on a runtime that
moves a potentially parking call off the JavaScript event loop. Deno does. Bun's
FFI executes the call synchronously, so those raw transports refuse
construction before allocating a handle, since even an idle release may join
backend work. Core TCP and inproc sessions work on both runtimes through their
runtime adapters.

## Tests

[`../dogfood/zig_smoke.ts`](../dogfood/zig_smoke.ts) is the example program that both
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
