# @glowcap/iroh

The optional encrypted-QUIC (iroh) transport for the glowcap JavaScript/TypeScript binding, a
companion to [`@glowcap/runtime`](../runtime/README.md). It uses its own archive,
`libglowcap_net_transport_iroh` (a Rust iroh sidecar, ADR-0055), which exports only the
`glowcap_iroh_*` family and shares no core symbol, so it loads alongside `libglowcap_ocapn`.

It is a separate package because iroh is the one transport with an external release cadence (the
Rust/iroh sidecar) and the one the C ABI builds only on request (`zig build iroh-abi`, needs cargo).
A consumer that never speaks iroh installs only `@glowcap/runtime` and never pulls the sidecar
artifact.

## Dependency shape

`@glowcap/iroh` depends on `@glowcap/runtime`: it supplies the core's byte `Channel` seam over the
sidecar's readiness loop and mints keyed `Session`s through `Session.establishDialedLocator` /
`establishAccepted`, and it loads its archive through the core's FFI runtime, the
[`@glowcap/runtime/ffi`](../runtime/ffi.ts) seam. ES modules are singletons, so both packages share
one adapter and one archive resolver.

The package exports transport-owned `provider(config)` and `connector(config)`
values. Applications pass one to `Runtime.open`, so `@glowcap/runtime` does not depend on iroh or
interpret its locators.

```ts
import { Runtime } from "@glowcap/runtime";
import { locator, provider, Reachability } from "@glowcap/iroh";

await using runtime = await Runtime.open({
	providers: [provider({ reachability: Reachability.Discovery })],
});
await using session = await runtime.connect(locator("<peer node id>"));
```

`Reachability` is required at every entry point and has no default, because the caller owns the
reach and privacy posture. See [`mod.ts`](mod.ts) for `provider`, `connector`, `listen`,
`IrohServer`, and the `Reachability` postures.

## Byte-transparent relay

`dialLocatorForRelay(locator, reachability)` is a low-level dial entry point for relay
implementations that forward bytes from another transport (a WebSocket, an HTTP stream) to an iroh
locator without parsing CapTP frames. It returns a byte `Channel`: an object with `read()`,
`write()`, and `close()` methods, where `close()` also releases the loop and netlayer the dial
opened. Each call makes one transport attempt, and the embedding application owns any retry. A
byte-transparent relay leaves the keyed handshake and session authority to the two ends.
`zig build bindings-relay-iroh` checks that a wasm browser peer holds a live OCapN session with a
real iroh endpoint through each runtime's relay (fetch and call round-trip). The relay pump and WebSocket
adapter live in [`@glowcap/relay`](../relay/). The rooms endpoint that adds policy is
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs).
