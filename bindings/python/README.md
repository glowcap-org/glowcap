# glowcap for Python

The `glowcap` package connects a Python program to [OCapN](https://glowcap.org/protocol/) peers. It
calls their objects, hosts objects of its own, and passes references between peers, with glowcap's
C libraries doing the protocol work. It uses `ctypes`, `asyncio`, and the standard library, and
needs CPython on a 64-bit Unix platform. Its
[package metadata](https://github.com/glowcap-org/glowcap/blob/main/bindings/python/pyproject.toml)
declares the minimum Python version. The
[Python guide](https://glowcap.org/bindings/python/) walks through the round trip, listening, and
actors. Terms such as locator, vat, and sturdyref are defined in the
[glossary](https://github.com/glowcap-org/glowcap/blob/main/docs/capabilities.md#glossary).

## Install

```sh
python -m pip install glowcap
```

On first import the package downloads the C libraries of its version from its
[GitHub release](https://github.com/glowcap-org/glowcap/releases) and verifies
them against its checksum file. Set
`GLOWCAP_LIB_DIR` to an extracted C SDK's `lib/` directory to use a local copy.
In a checkout of the repository, run `zig build` and make the tree's package
importable instead:

```sh
export PYTHONPATH="$PWD/bindings/python${PYTHONPATH:+:$PYTHONPATH}"
```

## A first session

Start the [greeter server below](#run-the-greeter-server). This client
connects over encrypted Noise TCP to `127.0.0.1:9099`. Replace `peer_key` with
the server's public key, save this as `client.py`, and run `python client.py`.

```python
import asyncio

from glowcap import Runtime, tcp, VowBroken


async def main():
    peer_key = "<64 lowercase hex characters from the server>"
    async with Runtime.open(providers=[tcp.provider()]) as runtime:
        async with await runtime.connect(tcp.noise.locator(peer_key, "127.0.0.1", 9099)) as session:
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

### Run the greeter server

Save this as `server.py` and run `python server.py` in another terminal.
It prints an `ocapn://` URI. Copy its 64-character key into `peer_key` in the
client above. The server creates a fresh key each time it starts.

```python
import asyncio

from glowcap import Argument, tcp


def greet(verb: str | None, args: list[Argument]) -> str:
    if verb != "greet" or len(args) != 1 or not isinstance(args[0], str):
        raise ValueError("expected greet with one string")
    return f"Hello, {args[0]}"


async def main():
    async with await tcp.noise.listen("127.0.0.1", 9099) as server:
        server.host.publish("greeter", greet)
        print(server.uri, flush=True)
        async for accepted in server:
            async with accepted as session:
                await session.serve()


asyncio.run(main())
```

## Sessions and actors

Python values map directly to glowcap values: integers, floats, booleans,
bytes, strings, and lists, plus `Symbol`, `Keyword`, `Set`, `Tagged`, `Struct`,
the fulfilled-data `ErrorValue`, and the capability type `Ref`. Returning an
`ErrorValue` fulfills the caller's `RemotePromise` with that error as data.
Raising an exception or returning a broken vow rejects it. Async behaviors
may return values containing capabilities, just as synchronous behaviors may.

`host.retain(ref)` returns an independent reference occurrence. Releasing the
source wrapper leaves it usable. `await session.resolve(ref)` returns an owned
reference for a live object without wire traffic, or waits for a promise's settled
value. Retained and resolved references receive finalizer cleanup even when
Session GC is off. Use `host.release(ref)` or `session.release(ref)` when release
must happen now.

`await tcp.listen(host, port)` returns a `tcp.Server` whose iterator yields a
`Session` for each partner. `publish` and `spawn` host ordinary Python
callables. `send` returns a `RemotePromise`, implemented as an
`asyncio.Future`, and that promise can be the target of another send.

Under `Runtime` and `listen`, an `iroh`, `noise-tcp`, `keyed-tcp`, or `tcp`
connection runs on glowcap's driver loop, one event loop in the C library that
owns the sockets, moves frames, and releases finished sessions.
Python loads the separate Host and driver libraries and steps the loop, while
asyncio waits on a file descriptor that signals when the loop has work.

Pass `iroh.provider(config)`, `tcp.provider(config)`, or another transport
package to choose a transport. The driver starts with no transports and
installs the providers you pass. A routed `keyed-relay` or `noise-relay` locator
likewise loads the relay library and installs its provider.

`Runtime.open(providers=[...])` or `Runtime.open(connectors=[...])` names the
transports. Host options such as `seed`, `profile`, `codec`, `captp_version`,
`features`, `context`, `frame_cap`, and `local_turn_budget` configure the Host it creates.
`Runtime.open(adopt_host=host, ...)` transfers an existing Host into the
Runtime and takes no Host options. `await runtime.close()` then shuts that Host
down for good.

`close(*, pending=PendingWork.CANCEL, grace_ms=...)` has the same shape on
`Session`, `Runtime`, and `Host`. `PendingWork.FINISH` requires `grace_ms`, an
integer number of milliseconds, or `None` to wait without a bound.

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
session to the peer that hosts the object. References belong to their Host
and can be used through any session on that Host.

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

[Choosing a transport](https://glowcap.org/transports/choosing/) compares them, and the pages for
[iroh](https://glowcap.org/transports/iroh/), [WebRTC](https://glowcap.org/transports/webrtc/),
[Tor](https://glowcap.org/transports/onion/), and [relays](https://glowcap.org/relay/) go deeper.

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
  `glowcap[rendezvous]`.

The lower-level transports are also available directly:

```python
from glowcap.tcp import TcpNetlayer

with TcpNetlayer() as netlayer:
    listener = netlayer.listen("127.0.0.1", 0)
    connection = netlayer.connect("127.0.0.1", listener.port())
```

## Learn more

- [Python guide](https://glowcap.org/bindings/python/): the round trip, listening, async, and actors.
- [The API every binding shares](https://github.com/glowcap-org/glowcap/blob/main/bindings/README.md),
  and the [repository](https://github.com/glowcap-org/glowcap) for the C libraries and the other
  bindings.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
