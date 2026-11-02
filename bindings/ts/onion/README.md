# @glowcap/onion

`@glowcap/onion` connects [`@glowcap/runtime`](https://jsr.io/@glowcap/runtime) to
[OCapN](https://glowcap.org/protocol/) peers through [Tor](https://www.torproject.org/), using a
Tor daemon you already run. glowcap does not start, supervise, or configure one. The
[Tor page](https://glowcap.org/transports/onion/) explains what Tor proves and what it does not.

A service id is an address, not an identity: Tor proves the far circuit holds the key the address
encodes, while the CapTP peer is whoever owns the local endpoint the service forwards to. An
accepted circuit exposes no client identity, because Tor tells a hidden service nothing about who
dialed it.

## Install

```sh
deno add jsr:@glowcap/onion jsr:@glowcap/runtime
```

The package loads the onion C library on first use, which the runtime's C SDK download includes.
Deno needs `--allow-ffi --allow-read --allow-net` to reach the daemon.

## Dial and listen

`provider(options)` installs the transport on a Runtime, where `options` names the daemon's SOCKS
and control endpoints. `locator(serviceId)` builds the `onion` locator a Runtime dials.

```ts
import { Runtime } from "@glowcap/runtime";
import { locator, provider } from "@glowcap/onion";

await using runtime = await Runtime.open({
	providers: [provider({ socks: "127.0.0.1:9050", control: "127.0.0.1:9051" })],
});
await using session = await runtime.connect(locator("<56-character onion service id>"));
```

`listen(options, host?)` publishes a hidden service through the daemon and returns an
`OnionServer` whose iteration yields each accepted `Session`. `Netlayer`, `Listener`, and
`Connection` expose the raw frame transport for a program that runs its own loop. The raw methods
are asynchronous on Deno, and Bun's FFI refuses them before allocating a handle.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
