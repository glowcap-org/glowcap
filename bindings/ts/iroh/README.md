# @pancake/iroh

The optional encrypted-QUIC (iroh) transport for the pancake JavaScript/TypeScript binding, a
composable companion to [`@pancake/stack`](../stack/README.md). It rides its own archive,
`libpancake_net_transport_iroh` (a Rust iroh sidecar, ADR-0055), which exports only the
`pancake_iroh_*` family and shares no core symbol, so it loads alongside `libpancake_ocapn`, never
instead of it.

It is a separate package on purpose: it is the one transport with an external release cadence (the
Rust/iroh sidecar) and the one the C ABI builds only on request (`zig build iroh-abi`, needs cargo).
A consumer that never speaks iroh installs only `@pancake/stack` and never pulls the sidecar
artifact.

## Dependency shape

`@pancake/iroh` depends on `@pancake/stack`: it supplies the core's byte `Channel` seam over the
sidecar's readiness loop and mints keyed `Session`s through `Session.establishDialedLocator` /
`establishAccepted`, and it loads its archive through the core's one FFI runtime, the
[`@pancake/stack/ffi`](../stack/ffi.ts) seam. ES modules are singletons, so there is exactly one
adapter and one archive resolver across both packages.

The core's transport-neutral `connect` reaches this package only through a lazy
`import("@pancake/iroh/internal")` for an `iroh` locator, so `@pancake/stack` never hard-depends on
it. Application code dials via `connect(locator, reachability)` and never imports that internal
entry.

```ts
import { listenIroh, Reachability } from "@pancake/iroh";

const server = listenIroh(Reachability.Direct);
console.log(server.uri); // hand this to a partner
for await (const conn of server) conn.serve();
```

`Reachability` is required at every entry point. The caller owns the reach and privacy posture;
there is no default. See [`mod.ts`](mod.ts) for `listenIroh`, `IrohServer`, and the `Reachability`
postures; dial via `@pancake/stack`'s `connect(locator, reachability)`.
