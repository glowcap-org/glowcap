# Python binding

This package uses `ctypes`, `asyncio`, and the standard library. It is not
published yet; import it from a pinned checkout after running `zig build`.
CPython 3.11 or newer on an LP64 platform is required.

```python
import asyncio

from pancake import connect, tcp_locator, VowBroken


async def main():
    session = await connect(tcp_locator("127.0.0.1", 9099))
    session.serve()

    greeter = await session.fetch("greeter")
    try:
        print(await session.send(greeter, "greet", ["world"]))
    except VowBroken as reason:
        print(f"the greeter refused: {reason}")

    await session.close()


asyncio.run(main())
```

## Sessions and actors

Python values map directly to pancake values: integers, floats, booleans,
bytes, strings, and lists, plus `Symbol`, `Keyword`, `Set`, `Tagged`, and the
capability type `Ref`.

`await listen(host, port)` returns a `Server` whose iterator yields a `Session`
for each partner. `publish` and `spawn` host ordinary Python callables. `send`
returns a `RemotePromise`, implemented as an `asyncio.Future`, and that promise
can be the target of another send.

Under `connect` and `listen`, a `tcp`, `keyed-tcp`, `noise-tcp`, or `iroh`
connection runs on pancake's native loop posture: Python loads the separate
Host and driver archives, and one stepping native loop owns the provider,
framing, pumping, and session release while asyncio parks on its readiness
descriptor. The TCP archive supplies the complete TCP provider package; the
driver starts with no providers and receives it through the common provider
ABI. A routed `keyed-relay` or `noise-relay` locator likewise loads the relay
archive and installs its complete provider package. Both roads carry the same
`Session` surface.

`listen_keyed_tcp` and `listen_noise_tcp` return native-loop servers whose
`uri()` is ready to hand to `connect`; pass a 32-byte `seed` to keep a durable
designator across restarts. The native loop owns admission policy. A wildcard
`bind_host` requires `advertised_host`, the dialable name or address placed in
the Host locator; pancake does not guess that reachability from the bind.

A shared host makes handoff transparent across several sessions. The less
common `send_redeeming` call returns both the answer and `via`, the direct
exporter session. Host a reply capability on `via`; a local reference is valid
only in the session where it was exported.

## Transports

| Module | Purpose |
| --- | --- |
| `pancake` | Async sessions, hosts, values, locators, and actors. |
| `pancake.tcp` | Blocking TCP netlayer, listener, and connection handles. |
| `pancake.inproc` | Blocking in-process connections. |
| `pancake.onion` | Tor onion connections, through a Tor daemon you run. Both handles expose `readiness_fd()` for a caller with its own loop. |
| `pancake.iroh` | Optional encrypted QUIC and `listen_iroh`. |
| `pancake.relay` | Native `keyed-relay`/`noise-relay` provider composition. |

`connect` loads `pancake.iroh` only when it sees an iroh locator. A TCP-only
program never loads that library.

A `keyed-relay` locator names a peer that opens no socket and holds inbound
connections at a relay under its key. When the locator carries a
`rendezvous-relay` hint, `connect` routes through the native relay provider.
For a bare locator, assign `Host.rendezvous_url` (the mapping from designator
to the relay's rendezvous WebSocket URL); `connect` then uses the explicit
WebSocket byte-channel fallback. That fallback's client is the one optional
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
