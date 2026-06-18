# bindings/ts

The multi-runtime JavaScript/TypeScript consumer of the pancake C ABI archives —
one TypeScript source that runs on Deno, Bun, and (experimentally) Node. All
runtime coupling (FFI and sockets) lives behind a thin seam that detects the
host at load time and `import()`s the matching adapter, so `bun:ffi`/`node:ffi`
never load on the wrong runtime. See [`../README.md`](../README.md) for the
shipped C ABI surface and how every binding is gated.

## Packages

A Deno workspace with two published packages, split exactly along the dependency
graph — the core and its built-in transports version together; the optional,
externally-cadenced iroh transport versions on its own:

| Package                             | Dir                | What it is                                                                                                                                                                                                                   |
| ----------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`@pancake/stack`](stack/README.md) | [`stack/`](stack/) | Core OCapN/CapTP peer, values, events, vat/actors, locators, async `Connection`/`Server`, plus the built-in `tcp` and `inproc` transports (`@pancake/stack/transport/{tcp,inproc}`) and the native seam `@pancake/stack/ffi` |
| [`@pancake/iroh`](iroh/README.md)   | [`iroh/`](iroh/)   | Optional encrypted-QUIC transport (`libpancake_net_transport_iroh`); depends on `@pancake/stack`, reached lazily by the core's `connect` for an `iroh` locator                                                               |

## Runtimes

| Runtime                    | Tier                  | FFI seam              |
| -------------------------- | --------------------- | --------------------- |
| [Deno](https://deno.com)   | tested (gate)         | `Deno.dlopen`         |
| [Bun](https://bun.sh)      | tested (gate)         | `bun:ffi`             |
| [Node](https://nodejs.org) | experimental, ungated | `node:ffi` (Node 26+) |

## Gating

[`stack/zig_smoke.ts`](stack/zig_smoke.ts) is the one consumer both
`zig build
deno-dogfood` and `zig build bun-dogfood` run — the same source on
both runtimes, driving a real OCapN round-trip through the core API and
shuttling a frame through both built-in transports.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
