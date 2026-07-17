# bindings/ts

This is the multi-runtime JavaScript/TypeScript consumer of the pancake C ABI
archives: one TypeScript source that runs on Deno and Bun. All runtime coupling
(FFI and sockets) lives behind a thin seam that detects the host at load time
and `import()`s the matching adapter, so `bun:ffi` never loads on the wrong
runtime. See [`../README.md`](../README.md) for the shipped C ABI surface and
how every binding is gated.

## Packages

The binding is a Deno workspace of two published packages, split along the
dependency graph. The core and its built-in transports version together. The
optional, externally-cadenced iroh transport versions on its own:

| Package                             | Dir                | What it is                                                                                                                                                                                                                                |
| ----------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`@pancake/stack`](stack/README.md) | [`stack/`](stack/) | A full OCapN host over the byte-fed host archive (`libpancake_driver`, ADR-0072): values, capabilities, locators, the async `Session`/`Server`, plus the built-in `tcp` and `inproc` transports and the native seam `@pancake/stack/ffi` |
| [`@pancake/iroh`](iroh/README.md)   | [`iroh/`](iroh/)   | Optional encrypted-QUIC transport (`libpancake_net_transport_iroh`). Depends on `@pancake/stack`. The core's `connect` reaches it lazily for an `iroh` locator.                                                                            |

## Runtimes

| Runtime                  | Tier          | FFI seam      |
| ------------------------ | ------------- | ------------- |
| [Deno](https://deno.com) | tested (build check) | `Deno.dlopen` |
| [Bun](https://bun.sh)    | tested (build check) | `bun:ffi`     |

## Build checks

[`dogfood/zig_smoke.ts`](dogfood/zig_smoke.ts) is the one consumer both
`zig build deno-dogfood` and `zig build bun-dogfood` run. The same source runs
on both runtimes, driving real OCapN conversations through the application API
and shuttling a frame through both built-in transports.
[`dogfood/gifter_handoff.ts`](dogfood/gifter_handoff.ts) is the
`zig build deno-gifter-handoff` consumer: a pancake-only three-party handoff
where a broker's introduction is redeemed transparently and the recipient
messages the exporter directly.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
