# @glowcap/runtime

`@glowcap/runtime` is the core JavaScript and TypeScript package for glowcap. It connects a program
to [OCapN](https://glowcap.org/protocol/) peers, calls their objects, hosts objects of its own, and
passes references between peers, with glowcap's C libraries doing the protocol work. It provides
values, capabilities, actors, locator URIs, and the async `Session` and `Host` API on Deno, and in
the browser through [`@glowcap/web`](https://jsr.io/@glowcap/web). Bun supports the synchronous
Host and locator API and byte-fed clients, but cannot run the driver loop or blocking transports.
The [TypeScript guide](https://glowcap.org/bindings/ts/) walks through the round trip, listening,
and actors.

## Install

The core depends on no transport, so install it with the transport package you will dial through:

```sh
deno add jsr:@glowcap/runtime jsr:@glowcap/tcp
```

On first use outside a checkout, the package downloads the C libraries of its version from the
GitHub release and verifies them against its checksum file. Set `GLOWCAP_LIB_DIR` to an extracted
C SDK's `lib/` directory to use a local copy. Automatic downloads require `curl` and GNU or BSD `tar`.
The loader reads environment settings, writes its cache, and runs those tools before loading
the libraries through FFI. Save the example below as `client.ts` and run it with:

```sh
deno run --allow-all client.ts
```

For Bun's Host and byte-fed APIs, install with `bunx jsr add @glowcap/runtime` and run with
`bun run`. The Deno session example below uses the driver loop, which Bun does not support.

| Package | Adds |
| --- | --- |
| [`@glowcap/tcp`](https://jsr.io/@glowcap/tcp) | TCP, in the clear or sealed with Noise, and its listeners. |
| [`@glowcap/iroh`](https://jsr.io/@glowcap/iroh) | Encrypted QUIC through iroh, with peer discovery. |
| [`@glowcap/webrtc`](https://jsr.io/@glowcap/webrtc) | Direct peer-to-peer data channels, in Deno and the browser. |
| [`@glowcap/relay`](https://jsr.io/@glowcap/relay) | Relay routes for peers that cannot open a socket, and the relay itself. |
| [`@glowcap/onion`](https://jsr.io/@glowcap/onion) | Tor, through a daemon you run. |
| [`@glowcap/inproc`](https://jsr.io/@glowcap/inproc) | Two peers in one process, for tests. |
| [`@glowcap/web`](https://jsr.io/@glowcap/web) | The browser adapter that runs this package over WebAssembly. |
| [`@glowcap/abi`](https://jsr.io/@glowcap/abi) | The generated constants the packages above share. |

[Choosing a transport](https://glowcap.org/transports/choosing/) compares them.

## A first session

The example expects a peer publishing `greeter` at `127.0.0.1:9099`. The
[TCP listener example](https://jsr.io/@glowcap/tcp#listen) supplies that server.
Use its advertised durable key for `peerKey`.

A Runtime owns one Host (the object that owns your identity and published objects) and the
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
import { noise, provider } from "@glowcap/tcp";

// noise-tcp: the peer is a durable key at a host and port, sealed end to end.
const peerKey = "<64 lowercase hex characters from the server>";
const partner = noise.locator(peerKey, "127.0.0.1", 9099);

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

## Reference lifetime

Release a received capability with `session.release(ref)` when you are done with it.
`session.withGc()` instead selects finalizer cleanup for later replies and
delivered arguments projected by the Host. For one reply, select
`session.send(target, method).withGc()` before awaiting or attaching a reaction.
Selecting reply GC after observation has begun is refused.

Generated TypeScript calls select reply GC automatically. Saved raw results share
the same capability wrappers and remain usable while reachable. Local behavior
results remain borrowed, while a caretaker forwarding to a peer carries the reply
selection to that call. Collection timing is chosen by JavaScript, so use
explicit release when cleanup must happen now.

A fetch that receives a non-capability result throws `FetchFailed` and queues its
references for release without waiting for collection. Valid fetch results keep their
existing release policy. Unobserved replies abandoned or evicted by the Host
retire their references without waiting for JavaScript collection.

## How it is built

- It loads two C libraries. `libglowcap_host` handles byte-fed sessions, where your code supplies
  the bytes. `libglowcap_driver` runs the event loop (the driver loop) that owns sockets. It starts
  with no transports and adopts a Host through `glowcap_driver_take_host`. A separate library per
  transport keeps unused code out of your program.
- On Deno, a `Runtime.connect` that uses a provider runs on a driver loop that
  the binding steps. Transport packages build their listeners and return a
  `Server` on that same loop.
- The byte-fed pump serves channels the runtime owns, and the low-level
  blocking transports are available for programs that run their own loop.
- The same source runs on Deno, Bun, and the browser. The parts that differ (how to call the C
  library, how to open sockets, and struct layout) live in
  [`internal/ffi/runtime.ts`](internal/ffi/runtime.ts). A browser build injects its own adapter
  first, which is how `@glowcap/web` runs this package over WebAssembly. Otherwise the module
  detects the runtime and imports the matching adapter, so `bun:ffi` never loads on the wrong
  runtime.

| Runtime                  | FFI                    | How it runs                               |
| ------------------------ | ---------------------- | ----------------------------------------- |
| [Deno](https://deno.com) | `Deno.dlopen`          | `deno run --allow-all client.ts`          |
| [Bun](https://bun.sh)    | `bun:ffi`              | `bun run`                                 |
| Browser                  | WebAssembly            | `@glowcap/web` `init`                     |

Deno runs the application API over the driver loop. Bun runs the synchronous Host and locator
API, and its driver-loop and blocking transports refuse with an error. Any other runtime is
refused at load with an error.

## The modules

The public API is declared in [`deno.json`](deno.json)'s `exports` map. JSR uses it for Deno and
its npm-compatible packages, which Bun installs. Each transport package opens its own C library, so an
import loads only what it needs.

| Import | File | Purpose |
| --- | --- | --- |
| `@glowcap/runtime` | [`mod.ts`](mod.ts) | Sessions, Hosts, values, locators, actors, and the driver loop |
| `@glowcap/runtime/cleanup` | [`cleanup.ts`](cleanup.ts) | Rollback helpers that import no Host or FFI adapter |
| `@glowcap/runtime/transport` | [`transport.ts`](transport.ts) | For authors of a transport package. Applications do not import it. |
| `@glowcap/runtime/ffi` | [`ffi.ts`](ffi.ts) | Foreign-function layer for transport packages, not an application import |

The core imports no concrete transport. The value and Host APIs work on their own, and a Runtime
that connects needs a provider or connector that you pass. The transport packages build on the
core and not on each other. They share the `Context` pointer and the frame and context type
layouts, and they export no overlapping symbols.

`@glowcap/runtime/cleanup` runs rollback steps in order and keeps any failures they raise attached
to the original error, up to a fixed count. `@glowcap/runtime` exports the same helpers, and both
paths share one record of attached failures.

## The transports

Most applications use the transport packages above. `@glowcap/tcp/transport` and `@glowcap/inproc`
expose the lower-level frame transport directly, for programs that run their own loop. A `Netlayer`
(the OCapN term for a transport) binds a `Listener` and dials a `Connection`. Dialing, accepting,
reading, and writing are all asynchronous, because each call that might block runs off the
JavaScript event loop. TCP binds a `host:port`. Inproc binds a string designator and moves frames
through in-process pipes with no kernel transport.

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
const frame = new TextEncoder().encode("hello");
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

## Learn more

- [TypeScript guide](https://glowcap.org/bindings/ts/) and the
  [browser guide](https://glowcap.org/bindings/browser/).
- [The API every binding shares](https://github.com/glowcap-org/glowcap/blob/main/bindings/README.md),
  and the [repository](https://github.com/glowcap-org/glowcap) for the C libraries and the other
  bindings.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
