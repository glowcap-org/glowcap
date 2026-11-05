# @glowcap/iroh

`@glowcap/iroh` connects [`@glowcap/runtime`](https://jsr.io/@glowcap/runtime) to
[OCapN](https://glowcap.org/protocol/) peers over [iroh](https://iroh.computer), which carries a
glowcap session over encrypted QUIC and finds the peer by its key. The
[iroh page](https://glowcap.org/transports/iroh/) explains reachability, what the key proves,
and handoffs.

## Install

```sh
deno add jsr:@glowcap/iroh jsr:@glowcap/runtime
```

The package loads `libglowcap_net_transport_iroh`, a Rust library built around iroh that the
runtime's C SDK download includes. Save the example below as `client.ts` and run
`deno run --allow-all client.ts`. The
[runtime installation instructions](https://jsr.io/@glowcap/runtime#install) explain the
download tools and how to use a local SDK.

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
through `@glowcap/runtime/ffi`, the runtime's foreign-function layer, and both packages share one
loader because ES modules are singletons.

## Byte-transparent relay

`dialLocatorForRelay(locator, reachability)` is a low-level dial for a relay server that forwards
bytes from another transport (a WebSocket, an HTTP stream) to an iroh locator without parsing
CapTP frames. Most applications never call it. It returns a byte `Channel` with `read()`,
`write()`, and `close()` methods. `close()` also releases the loop and netlayer the dial opened. Each
call makes one transport attempt, and the calling application owns any retry.

A byte-transparent relay leaves the keyed handshake and everything after it to the two ends, as
[`@glowcap/relay`](https://jsr.io/@glowcap/relay) describes.
That package holds the relay pump and WebSocket adapter, and the Rooms app's
[relay endpoint](https://github.com/glowcap-org/glowcap/blob/main/apps/rooms/rust/services/src/web/relay.rs)
adds policy on top.

## Learn more

- [iroh page](https://glowcap.org/transports/iroh/) and
  [choosing a transport](https://glowcap.org/transports/choosing/).
- The [repository](https://github.com/glowcap-org/glowcap) for the Rust library and the other
  bindings.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
