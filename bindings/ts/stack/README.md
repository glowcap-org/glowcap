# @pancake/stack

The core multi-runtime JavaScript/TypeScript consumer of the pancake C ABI archives: the OCapN/CapTP
peer, values, events, vat/actors, locator URIs, the async `Connection`/`Server` over the runtime's
own networking, and the two built-in transports (`tcp`, `inproc`). The optional encrypted-QUIC
transport ships separately as [`@pancake/iroh`](../iroh/README.md).

One source, three runtimes: all runtime coupling — the FFI and the sockets — lives behind a thin
seam in [`internal/ffi/runtime.ts`](internal/ffi/runtime.ts), which detects the host at load time
and `import()`s the matching adapter, so `bun:ffi`/`node:ffi` never load on the wrong runtime. The
binding is à-la-carte, exactly like the archives it rides (ADR-0059): you import the core plus
whichever transports you want, and each module opens only its own archive. See
[`../../README.md`](../../README.md) for the shipped C ABI surface and how the bindings are gated.

## Runtimes

| Runtime                    | Tier                  | FFI seam      | How it runs                                                                   |
| -------------------------- | --------------------- | ------------- | ----------------------------------------------------------------------------- |
| [Deno](https://deno.com)   | tested (gate)         | `Deno.dlopen` | `deno run --allow-ffi --allow-read`                                           |
| [Bun](https://bun.sh)      | tested (gate)         | `bun:ffi`     | `bun run`                                                                     |
| [Node](https://nodejs.org) | experimental, ungated | `node:ffi`    | Node 26+, `--experimental-ffi` (and `--allow-ffi` under the permission model) |

Deno and Bun each have a `zig build` dogfood gate. Node is shipped so a consumer can try the
binding, but it is **untested**: `node:ffi` is a stability-1 experimental API, and Node's built-in
type-stripping cannot run the `.ts` sources directly (they use TypeScript parameter properties), so
a Node consumer takes the binding through transpiled JS — the JSR npm bridge (`npx jsr add`) or a
local transpile — rather than the raw `.ts`.

## The modules

The public surface is one core module plus one module per built-in transport, declared in
[`deno.json`](deno.json)'s `exports` map (the JSR manifest; the same `exports` reach Bun and Node).
Each maps to an archive and opens only that archive through the runtime shim's `dlopen`, so
importing the core never loads a transport and importing one transport never loads another.

| Import                            | File                                         | Archive it opens                                                                                                                                            |
| --------------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@pancake/stack`                  | [`mod.ts`](mod.ts)                           | `libpancake_ocapn` — the core peer, values, events, vat/actors, locator URIs, and the async `Connection`/`Server` over the runtime's own networking         |
| `@pancake/stack/transport/tcp`    | [`transport/tcp.ts`](transport/tcp.ts)       | `libpancake_net_transport_tcp` — the blocking `Netlayer`/`Listener`/`Endpoint` frame shuttle                                                                |
| `@pancake/stack/transport/inproc` | [`transport/inproc.ts`](transport/inproc.ts) | `libpancake_net_transport_inproc` — the socket-free in-process `Netlayer`/`Listener`/`Endpoint`                                                             |
| `@pancake/stack/ffi`              | [`ffi.ts`](ffi.ts)                           | the native seam (`ffi`, `Ptr`, `Symbols`, `libPath`, ABI constants) a transport-companion package such as `@pancake/iroh` plugs into — not for applications |

The optional encrypted-QUIC transport is a separate package, [`@pancake/iroh`](../iroh/README.md),
so a consumer that never speaks iroh never installs the Rust-sidecar artifact. `connect` reaches it
lazily — `import("@pancake/iroh")` on the first `iroh` locator — so the core never hard-depends on
it.

The core is usable standalone. The transport modules build on it — they share the `Context` pointer
and the frame/context type layout, and they are symbol-disjoint — but never on each other. The
internal loaders live under [`internal/ffi/`](internal/ffi/) (one per archive) and the ABI
constants, hand-mirrored from `pancake_ocapn.h`, in
[`internal/constants.ts`](internal/constants.ts); a consumer never imports those.

## The core

`mod.ts` is the idiomatic JavaScript/TypeScript API over the core archive. What you use is a `Peer`
class (disposable), discriminated-union value types, and typed events. The default `new Peer()` is a
negotiating authenticated session; use `Peer.rawOpen()` only for low-level fixtures that inject
frames directly. Integers are `bigint`, floats are `number`:

```ts
import { far, Peer } from "@pancake/stack";

using peer = Peer.rawOpen();
peer.registerImport(5n);
peer.sendDeliver(far(5n), [42n, new Uint8Array([1, 2])], 9n);
peer.step();
const frame = peer.takeOutbound();
// ...and poll() returns a typed { kind: "deliver" | "resolve" | "other", ... }
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

[`zig_smoke.ts`](zig_smoke.ts) is the one consumer both `zig build deno-dogfood` and
`zig build bun-dogfood` run, the same source on both runtimes: it drives a real OCapN round-trip
through the core API and shuttles a frame through both the TCP and in-process transports. Deno's FFI
needs `--allow-ffi --allow-read`; the build step passes them and resolves the shared libraries
relative to `zig-out/`.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
