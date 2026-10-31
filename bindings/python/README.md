# Python binding

This package lets Python connect to OCapN peers, call their objects, and host
objects of its own. It uses `ctypes`, `asyncio`, and the standard library, and
needs the CPython version `pyproject.toml` declares on an LP64 (64-bit Unix)
platform. Terms such as locator, vat, and sturdyref are defined in the
[glossary](../../docs/capabilities.md#glossary).

```sh
pip install glowcap
```

On first import the package downloads the C libraries of its version from the
GitHub release and verifies them against its checksum file. Set
`GLOWCAP_LIB_DIR` to an extracted C SDK's `lib/` directory to use a local copy.
In a checkout of the repository, run `zig build` and make the tree's package
importable instead:

```sh
export PYTHONPATH="$PWD/bindings/python${PYTHONPATH:+:$PYTHONPATH}"
```

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

- `fetch` and `send` start the inbound loop when first used, so a client that
  only makes calls does not need `session.serve()`.
- `await session.closed()` waits for the session to end without closing it or
  starting that loop. Cancelling the waiter leaves the session running.
- `Host.publish_durable(behavior, entropy=None)` publishes `behavior` under a
  durable swiss number, the secret name a peer uses to fetch it later. Pass the
  same entropy to a Host reconstructed from the same seed to restore that name.

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
connection runs on glowcap's driver loop, one event loop in the C library that
owns the sockets, frames and moves bytes, and releases finished sessions.
Python loads the separate Host and driver libraries and steps the loop, while
asyncio waits on a file descriptor that signals when the loop has work.

Pass `iroh.provider(config)`, `tcp.provider(config)`, or another transport
package to choose a transport. The driver starts with no transports and
installs the one you pass. A routed `keyed-relay` or `noise-relay` locator
likewise loads the relay library and installs its provider.

`Runtime.open(adopt_host=host, ...)` transfers an existing Host into the
Runtime. `await runtime.close()` then shuts that Host down for good.

`tcp.listen`, `tcp.keyed.listen`, and `tcp.noise.listen` return the same
`tcp.Server`. Its `locator` and `uri` are ready to hand to `Runtime.connect`.

- Pass a 32-byte `seed` to keep the same identity (the designator in the
  locator) across restarts.
- The driver loop accepts incoming connections and limits concurrent
  handshakes.
- A wildcard `bind_host` requires `advertised_host`, the name or address
  partners dial. glowcap puts it in the locator because it cannot infer
  reachability from the bind.

`relay.keyed.listen` and `relay.noise.listen` return the same `DriverServer`
shape over a registered relay route. Their `locator` and `uri` carry the
durable key and the rendezvous relay that partners dial.

A handoff is how one peer gives you a reference to an object hosted by a third
peer. With one Host shared across sessions, a handoff needs no extra code. The
less common `send_redeeming` call returns both the answer and `via`, the
session to the peer that hosts the object. Host a reply capability on `via`. A
local reference is valid only in the session where it was exported.

## Transports

| Module | Purpose |
| --- | --- |
| `glowcap` | Async sessions, hosts, values, locators, and actors. |
| `glowcap.tcp` | Typed TCP-profile locators, the complete provider package, and blocking frame handles. |
| `glowcap.inproc` | Blocking in-process connections. |
| `glowcap.onion` | Configured `listen` through a Tor daemon you run, plus raw Netlayer handles for a program that owns its own loop. |
| `glowcap.iroh` | Optional encrypted QUIC and `listen`. |
| `glowcap.webrtc` | Optional WebRTC dial and listen. See below. |
| `glowcap.relay` | `keyed-relay`/`noise-relay` provider composition and managed listeners. |

WebRTC needs a `SignalingAuthority` that you write to carry each exchange's
offer, answer, and candidates. `webrtc.provider(signaling)` installs the dial.
`await webrtc.listen(signaling)` returns a `Server` you iterate for sessions.
Hand each inbound offer to `server.provide_offer(designator, sdp)`.

The application imports only the transport modules it composes. A TCP-only
program never loads the iroh or WebRTC library.

A `keyed-relay` locator names a peer that opens no socket of its own. Instead,
a relay holds inbound connections for it under its key.

- When the locator carries a `rendezvous-relay` hint, `Runtime.connect` routes
  through the relay provider.
- For a bare locator, use `relay.connector(config)`. The route comes from the
  locator's hint or from the connector's configuration, as in every binding.
  Connections go through the connector only when your code creates one.
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

## Tests

```sh
zig build python-dogfood         # the package against a glowcap peer
zig build python-goblins-interop # the package against a Spritely Goblins peer
```

`zig build bindings` builds the libraries and runs the tests for every
language binding. [`zig_smoke.py`](zig_smoke.py) is a complete example program.

For the shared API, read the [binding overview](../README.md). Maintainers of
the private FFI loaders and pump should read
[Developing a binding](../DEVELOPING.md).
