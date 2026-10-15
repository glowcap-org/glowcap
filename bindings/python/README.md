# Python binding

This package uses `ctypes`, `asyncio`, and the standard library. It needs the
CPython version `pyproject.toml` declares, on an LP64 platform. Pin a
checkout, run `zig build`, and import it from the tree.

```python
import asyncio

from glowcap import Runtime, tcp, VowBroken


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
makes calls does not need `session.serve()`. `await session.closed()` waits for
the session to end without asking it to close or starting that loop. Cancelling the
waiter leaves the session running. `Host.publish_durable(behavior, entropy=None)`
mints a durable swiss name. Pass the same entropy to a Host reconstructed from
the same seed to restore that name.

## Sessions and actors

Python values map directly to glowcap values: integers, floats, booleans,
bytes, strings, and lists, plus `Symbol`, `Keyword`, `Set`, `Tagged`, `Struct`,
the fulfilled-data `ErrorValue`, and the capability type `Ref`. Returning an
`ErrorValue` fulfills the caller's `RemotePromise` with that error as data.
Raising an exception or returning a broken vow rejects it.

`await tcp.listen(host, port)` returns a `tcp.Server` whose iterator yields a
`Session` for each partner. `publish` and `spawn` host ordinary Python
callables. `send` returns a `RemotePromise`, implemented as an
`asyncio.Future`, and that promise can be the target of another send.

Under `Runtime` and `listen`, an `iroh`, `noise-tcp`, `keyed-tcp`, or `tcp`
connection runs on glowcap's driver loop. Python loads the separate Host and
driver archives. Python steps one loop that runs the provider, frames and
moves bytes, and releases finished sessions, while asyncio waits on a file
descriptor that signals when the loop has work.

The application passes `iroh.provider(config)`, `tcp.provider(config)`, or
another transport package. The driver starts with no providers and receives
the chosen package through the common provider ABI. A routed `keyed-relay` or
`noise-relay` locator likewise loads the relay archive and installs its
provider package. Either way you get the same `Session` API.

`Runtime.open(adopt_host=host, ...)` transfers an existing Host into the
Runtime. `await runtime.close()` then shuts that Host down for good.

`tcp.listen`, `tcp.keyed.listen`, and `tcp.noise.listen` return the same
`tcp.Server` surface. Its canonical `locator` and `uri` are ready to hand to
`Runtime.connect`. Pass a 32-byte `seed` to keep a durable designator across restarts.
The driver loop accepts incoming connections and limits concurrent handshakes. A wildcard `bind_host` requires
`advertised_host`, the dialable name or address placed in the Host locator,
because glowcap cannot infer reachability from the bind.

`relay.keyed.listen` and `relay.noise.listen` return the same `DriverServer`
shape over a registered relay route. Their `locator` and `uri` carry the
durable key and the rendezvous relay that partners dial.

A shared host makes handoff transparent across several sessions. The less
common `send_redeeming` call returns both the answer and `via`, the direct
exporter session. Host a reply capability on `via`. A local reference is valid
only in the session where it was exported.

## Transports

| Module | Purpose |
| --- | --- |
| `glowcap` | Async sessions, hosts, values, locators, and actors. |
| `glowcap.tcp` | Typed TCP-profile locators, the complete provider package, and blocking frame handles. |
| `glowcap.inproc` | Blocking in-process connections. |
| `glowcap.onion` | Configured `listen` through a Tor daemon you run, plus raw Netlayer handles for a program that owns its own loop. |
| `glowcap.iroh` | Optional encrypted QUIC and `listen`. |
| `glowcap.webrtc` | Optional WebRTC dial and listen. `webrtc.provider(signaling)` installs the dial, `await webrtc.listen(signaling)` returns a `Server` you iterate for sessions, and your `SignalingAuthority` carries each exchange's offer, answer, and candidates. You hand each inbound offer to `server.provide_offer(designator, sdp)`. |
| `glowcap.relay` | `keyed-relay`/`noise-relay` provider composition and managed listeners. |

The application imports only the transport modules it composes. A TCP-only
program never loads the iroh or WebRTC library.

A `keyed-relay` locator names a peer that opens no socket of its own. Instead,
a relay holds inbound connections for it under its key.

- When the locator carries a `rendezvous-relay` hint, `Runtime.connect` routes
  through the relay provider.
- For a bare locator, use `relay.connector(config)`. The route comes from the
  locator's hint or from the connector's configuration, as in every binding.
  You choose the connector. It is not an automatic fallback.
- The connector's client is the one optional dependency: install
  `glowcap[rendezvous]`. Repository checks install that extra
  from the committed lock with
  `uv run --project bindings/python --extra rendezvous --locked`.

The lower-level transports are also available directly:

```python
from glowcap.tcp import TcpNetlayer

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
