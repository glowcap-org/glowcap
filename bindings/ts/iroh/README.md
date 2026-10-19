# @glowcap/iroh

Use this package to connect to peers over [iroh](https://iroh.computer), which
carries a glowcap session over encrypted QUIC. It is an optional companion to
[`@glowcap/runtime`](../runtime/README.md), the core package.

It loads its own library, `libglowcap_net_transport_iroh`, a Rust library built around iroh. That
library exports only `glowcap_iroh_*` functions and shares no symbol with the core, so it loads
next to `libglowcap_ocapn`.

iroh lives in its own package because it follows iroh's release schedule and needs cargo to build
(`zig build iroh-abi`). An application that never uses iroh installs only `@glowcap/runtime` and
never downloads the Rust library.

## Connecting to a peer

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

`Reachability` says how the endpoint is found and how private it is. Every entry point requires it
and none has a default, because only the caller knows what the endpoint needs. See [`mod.ts`](mod.ts)
for `provider`, `connector`, `listen`, `IrohServer`, and each `Reachability` choice.

## How it plugs into the runtime

`@glowcap/iroh` depends on `@glowcap/runtime`. Applications do not call these internals. The
package feeds the runtime's byte `Channel` from the Rust library's event loop and creates keyed
`Session`s with `Session.establishDialedLocator` and `establishAccepted`. It loads its library
through [`@glowcap/runtime/ffi`](../runtime/ffi.ts), the runtime's foreign-function layer, and both
packages share one loader because ES modules are singletons.

## Byte-transparent relay

`dialLocatorForRelay(locator, reachability)` is a low-level dial for a relay server that forwards
bytes from another transport (a WebSocket, an HTTP stream) to an iroh locator without parsing
CapTP frames. Most applications never call it. It returns a byte `Channel` with `read()`,
`write()`, and `close()` methods. `close()` also releases the loop and netlayer the dial opened. Each
call makes one transport attempt, and the calling application owns any retry. A byte-transparent relay leaves the keyed handshake and
everything after it to the two ends, as [`@glowcap/relay`](../relay/README.md) describes.

`zig build bindings-relay-iroh` checks that a WebAssembly browser peer holds a live OCapN session
with a real iroh endpoint through each runtime's relay, including a fetch and a call. The relay pump and
WebSocket adapter live in [`@glowcap/relay`](../relay/README.md). The Rooms endpoint that adds policy is
[`apps/rooms/rust/services/src/web/relay.rs`](../../../apps/rooms/rust/services/src/web/relay.rs).
