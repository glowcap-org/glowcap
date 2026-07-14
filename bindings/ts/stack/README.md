# @pancake/stack

The core multi-runtime JavaScript/TypeScript consumer of the pancake C ABI archives: a full OCapN
node over the byte-fed host archive `libpancake_driver` (ADR-0072) — values, capabilities, actors,
locator URIs, the async `Session`/`Server` over the runtime's own networking — plus the two built-in
transports (`tcp`, `inproc`). The optional encrypted-QUIC transport ships separately as
[`@pancake/iroh`](../iroh/README.md).

One source, two runtimes: all runtime coupling (the FFI and the sockets) lives behind a thin seam in
[`internal/ffi/runtime.ts`](internal/ffi/runtime.ts), which detects the host at load time and
`import()`s the matching adapter, so `bun:ffi` never loads on the wrong runtime. The binding is
à-la-carte, exactly like the archives it rides (ADR-0059): you import the core plus whichever
transports you want, and each module opens only its own archive. See
[`../../README.md`](../../README.md) for the shipped C ABI surface and how the bindings are gated.

## Runtimes

| Runtime                  | Tier          | FFI seam      | How it runs                         |
| ------------------------ | ------------- | ------------- | ----------------------------------- |
| [Deno](https://deno.com) | tested (gate) | `Deno.dlopen` | `deno run --allow-ffi --allow-read` |
| [Bun](https://bun.sh)    | tested (gate) | `bun:ffi`     | `bun run`                           |

Deno and Bun each have a `zig build` dogfood gate; any other runtime is refused at load with a clear
error rather than half-working.

## The modules

The public surface is one core module plus one module per built-in transport, declared in
[`deno.json`](deno.json)'s `exports` map (the JSR manifest; the same `exports` reach Bun). Each maps
to an archive and opens only that archive through the runtime shim's `dlopen`, so importing the core
never loads a transport and importing one transport never loads another.

| Import                            | File                                         | Archive it opens                                                                                                                                                                   |
| --------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@pancake/stack`                  | [`mod.ts`](mod.ts)                           | `libpancake_driver` (the byte-fed host: `Host`, `Session`/`Server`, `connect`/`listen`) plus `libpancake_ocapn`'s shared vocabulary (values, locator URIs, the allocation context) |
| `@pancake/stack/transport/tcp`    | [`transport/tcp.ts`](transport/tcp.ts)       | `libpancake_net_transport_tcp`: the blocking `Netlayer`/`Listener`/`Endpoint` frame shuttle                                                                                        |
| `@pancake/stack/transport/inproc` | [`transport/inproc.ts`](transport/inproc.ts) | `libpancake_net_transport_inproc`: the socket-free in-process `Netlayer`/`Listener`/`Endpoint`                                                                                     |
| `@pancake/stack/ffi`              | [`ffi.ts`](ffi.ts)                           | the native seam (`ffi`, `Ptr`, `Symbols`, `libPath`, ABI constants) a transport-companion package such as `@pancake/iroh` plugs into, not for applications                         |

The optional encrypted-QUIC transport is a separate package, [`@pancake/iroh`](../iroh/README.md),
so a consumer that never speaks iroh never installs the Rust-sidecar artifact. `connect` reaches it
lazily (`import("@pancake/iroh/internal")` on the first `iroh` locator), so the core never
hard-depends on it. Application code never imports that internal dial entry.

The core is usable standalone. The transport modules build on it (they share the `Context` pointer
and the frame/context type layout, and they are symbol-disjoint), but never on each other. Inside
the core, sibling modules split by responsibility — `promise`, `gc`, `dial`, `listen`, `session`,
`pump`, `action`, `host` — and `mod.ts` is only the barrel. The internal loaders live under
[`internal/ffi/`](internal/ffi/) (one per archive), and the ABI constants and struct layouts are
generated from the Zig source by `zig build gen-ts-abi` into [`internal/abi.ts`](internal/abi.ts)
(re-exported through [`internal/constants.ts`](internal/constants.ts)); a consumer never imports
those.

## The core

`mod.ts` is the idiomatic JavaScript/TypeScript API over the byte-fed host. An application holds a
`Session`: `publish`/`fetch` name capabilities, `send` returns an awaitable (and pipelinable)
`RemotePromise`, `spawn` hosts a plain callback as an actor, and `serve` runs the inbound loop. The
library owns every CapTP decision — routing, three-party redemption, gift origination, far vows —
and the binding moves bytes and honors the host's action queue. Integers are `bigint`, floats are
`number`:

```ts
import { connect, tcpLocator } from "@pancake/stack";

const conn = await connect(tcpLocator("127.0.0.1", 9099));
conn.serve().catch(() => {});
const greeter = await conn.fetch("greeter");
const reply = await conn.send(greeter, "greet", ["world"]);
conn.close();
```

The high-level `connect`/`listen` ride the runtime's networking, so a program that dials a `tcp`
locator or hosts a `Server` needs only the core module. `connect` imports `@pancake/iroh` lazily on
the first `iroh` locator, so a program that never speaks iroh never loads
`libpancake_net_transport_iroh`.

## The transports

`transport/tcp.ts` and `transport/inproc.ts` expose the C ABI's blocking frame shuttle directly: a
`Netlayer` binds a `Listener` and dials an `Endpoint`, each a synchronous `readFrame`/`writeFrame`.
TCP binds a `host:port`; inproc binds a string designator and moves frames through in-process pipes
with no kernel transport.

```ts
import { Netlayer } from "@pancake/stack/transport/inproc";

using net = new Netlayer();
using listener = net.listen("rooms");
using client = net.connect("rooms");
using server = listener.accept();
client.writeFrame(frame);
const got = server.readFrame();
```

Each transport routes its own failures through its own `pancake_<t>_last_error` slot, so a transport
call's diagnostic never scrapes the core's unrelated one.

## Gating

[`../dogfood/zig_smoke.ts`](../dogfood/zig_smoke.ts) is the one consumer both
`zig build deno-dogfood` and `zig build bun-dogfood` run, the same source on both runtimes: it
drives real OCapN conversations through the application API (fetch/send, pipelining, projections,
proxies, GC, both codecs) and shuttles a frame through both the TCP and in-process transports.
Deno's FFI needs `--allow-ffi --allow-read`; the build step passes them and resolves the shared
libraries relative to `zig-out/`.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
