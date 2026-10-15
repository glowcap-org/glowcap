# @glowcap/iroh

The optional [iroh](https://iroh.computer) transport for the glowcap JavaScript and TypeScript
binding. iroh carries the session over encrypted QUIC. This package is a companion to
[`@glowcap/runtime`](../runtime/README.md).

It loads its own library, `libglowcap_net_transport_iroh`, a Rust library built around iroh. That
library exports only `glowcap_iroh_*` functions and shares no symbol with the core, so it loads
next to `libglowcap_ocapn`.

iroh lives in its own package because it follows iroh's release schedule and needs cargo to build
(`zig build iroh-abi`). An application that never uses iroh installs only `@glowcap/runtime` and
never downloads the Rust library.

## How it plugs into the runtime

`@glowcap/iroh` depends on `@glowcap/runtime`. It feeds the runtime's byte `Channel` from the Rust
library's event loop, and it creates keyed `Session`s with `Session.establishDialedLocator` and
`establishAccepted`. It loads its library through
[`@glowcap/runtime/ffi`](../runtime/ffi.ts), the runtime's foreign-function layer. ES modules are
singletons, so both packages share one loader and one library lookup.

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

Every entry point requires `Reachability` and none has a default, because only the caller knows
how reachable and how private the endpoint should be. See [`mod.ts`](mod.ts) for `provider`,
`connector`, `listen`, `IrohServer`, and each `Reachability` choice.

## Byte-transparent relay

`dialLocatorForRelay(locator, reachability)` is a low-level dial for relays that forward bytes from
another transport (a WebSocket, an HTTP stream) to an iroh locator without parsing CapTP frames.
It returns a byte `Channel` with `read()`, `write()`, and `close()` methods. `close()` also
releases the loop and netlayer the dial opened. Each call makes one transport attempt, and the
calling application owns any retry. A byte-transparent relay leaves the keyed handshake and
everything after it to the two ends.

`zig build bindings-relay-iroh` checks that a wasm browser peer holds a live OCapN session with a
real iroh endpoint through each runtime's relay (fetch and call round-trip). The relay pump and
WebSocket adapter live in [`@glowcap/relay`](../relay/). The Rooms endpoint that adds policy is
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs).
