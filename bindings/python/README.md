# Python binding

This package uses `ctypes`, `asyncio`, and the standard library. Pin a
checkout, run `zig build`, and import it from the tree.
CPython 3.11 or newer on an LP64 platform is required.

```python
import asyncio

from pancake import Runtime, tcp, VowBroken


async def main():
    peer_key = "<64 lowercase hex characters from the server>"
    async with Runtime.open(provider=tcp.provider()) as runtime:
        async with await runtime.connect(
            tcp.noise.locator(peer_key, "127.0.0.1", 9099)
        ) as session:
            greeter = await session.fetch("greeter")
            try:
                print(await session.send(greeter, "greet", ["world"]))
            except VowBroken as reason:
                print(f"the greeter refused: {reason}")


asyncio.run(main())
```

`fetch` and `send` start the inbound loop on demand, so a client that only
makes calls does not need `session.serve()`.

## Sessions and actors

Python values map directly to pancake values: integers, floats, booleans,
bytes, strings, and lists, plus `Symbol`, `Keyword`, `Set`, `Tagged`, `Struct`,
the fulfilled-data `ErrorValue`, and the capability type `Ref`. `ErrorValue`
does not reject a `RemotePromise`; raising an exception or returning a broken
vow does.

`await tcp.listen(host, port)` returns a `tcp.Server` whose iterator yields a
`Session` for each partner. `publish` and `spawn` host ordinary Python
callables. `send` returns a `RemotePromise`, implemented as an
`asyncio.Future`, and that promise can be the target of another send.

Under `Runtime` and `listen`, an `iroh`, `noise-tcp`, `keyed-tcp`, or `tcp`
connection runs on pancake's native loop posture: Python loads the separate
Host and driver archives, and one stepping native loop owns the provider,
framing, pumping, and session release while asyncio parks on its readiness
descriptor. The application supplies `iroh.provider(config)`,
`tcp.provider(config)`, or another transport package explicitly; the driver
starts with no providers and receives the selected package through the common
provider ABI. A routed `keyed-relay` or `noise-relay` locator likewise loads
the relay archive and installs its complete provider package. Both roads carry
the same `Session` surface.

`Runtime.open(adopt_host=host, ...)` explicitly transfers an existing Host into
the Runtime. `await runtime.close()` is then that Host's terminal shutdown
barrier.

`tcp.listen`, `tcp.keyed.listen`, and `tcp.noise.listen` return the same
`tcp.Server` surface. Its canonical `locator` and `uri` are ready to hand to
`Runtime.connect`; pass a 32-byte `seed` to keep a durable designator across restarts.
The native loop owns admission. A wildcard `bind_host` requires
`advertised_host`, the dialable name or address placed in the Host locator;
pancake does not guess that reachability from the bind.

`relay.keyed.listen` and `relay.noise.listen` return the same `DriverServer`
shape over a registered relay route. Their `locator` and `uri` carry the
durable key and the rendezvous relay that partners dial.

A shared host makes handoff transparent across several sessions. The less
common `send_redeeming` call returns both the answer and `via`, the direct
exporter session. Host a reply capability on `via`; a local reference is valid
only in the session where it was exported.

## Transports

| Module | Purpose |
| --- | --- |
| `pancake` | Async sessions, hosts, values, locators, and actors. |
| `pancake.tcp` | Typed TCP-profile locators, the complete provider package, and blocking frame handles. |
| `pancake.inproc` | Blocking in-process connections. |
| `pancake.onion` | Configured `listen` through a Tor daemon you run, plus raw Netlayer handles for an embedder-owned loop. |
| `pancake.iroh` | Optional encrypted QUIC and `listen`. |
| `pancake.relay` | Native `keyed-relay`/`noise-relay` provider composition and managed listeners. |

The application imports only the transport modules it composes. A TCP-only
program never loads the iroh library.

A `keyed-relay` locator names a peer that opens no socket and holds inbound
connections at a relay under its key. When the locator carries a
`rendezvous-relay` hint, `Runtime.connect` routes through the native relay provider.
For a bare locator, use `relay.connector(config)`: the route comes from the
locator's hint or the connector's own configuration, the same two authorities
every binding reads. The connector is an explicit byte-fed
integration, not an automatic fallback. Its client is the one optional
dependency, kept out of the core: install `pancake[rendezvous]`. Repository
proofs resolve that extra from the committed lock with
`uv run --project bindings/python --extra rendezvous --locked`.

The lower-level transports are also available directly:

```python
from pancake.tcp import TcpNetlayer

with TcpNetlayer() as netlayer:
    listener = netlayer.listen("127.0.0.1", 0)
    connection = netlayer.connect("127.0.0.1", listener.port())
```

## Checks

```sh
zig build python-dogfood
zig build python-goblins-interop
```

`zig build bindings` builds the archives and runs every language binding.
[`zig_smoke.py`](zig_smoke.py) is this package's complete in-tree consumer.

For the shared API, read the [binding overview](../README.md). Maintainers of
the private FFI loaders and pump should read
[Developing a binding](../DEVELOPING.md).
