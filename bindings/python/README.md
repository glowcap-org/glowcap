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

A shared host makes handoff transparent across several sessions. The less
common `send_redeeming` call returns both the answer and `via`, the direct
exporter session. Host a reply capability on `via`; a local reference is valid
only on the connection where it was exported.

## Transports

| Module | Purpose |
| --- | --- |
| `pancake` | Async sessions, hosts, values, locators, and actors. |
| `pancake.tcp` | Blocking TCP netlayer, listener, and endpoint handles. |
| `pancake.inproc` | Blocking in-process connections. |
| `pancake.iroh` | Optional encrypted QUIC and `listen_iroh`. |

`connect` loads `pancake.iroh` only when it sees an iroh locator. A TCP-only
program never loads that library.

The lower-level transports are also available directly:

```python
from pancake.tcp import TcpNetlayer

with TcpNetlayer() as netlayer:
    listener = netlayer.listen("127.0.0.1", 0)
    endpoint = netlayer.connect("127.0.0.1", listener.port())
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
