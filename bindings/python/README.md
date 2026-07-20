# bindings/python

This package is a Python consumer of the pancake C ABI archives. It uses
`ctypes` and the standard library alone. The C ABI ships as composable,
symbol-disjoint archives (ADR-0059), and this package mirrors that split: a
core package over `libpancake_ocapn` plus the byte-fed host companion
`libpancake_driver` (ADR-0072), and one submodule per transport. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## Composable submodules, one per archive

Each module loads only its own archive, so importing one transport never loads
another. Compose what you need, the same way a C consumer links archives
à la carte:

| Module           | Archive it loads                                    | Surface                                                                                                                                                     |
| ---------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pancake` (core) | `libpancake_ocapn` + `libpancake_driver` (ADR-0072) | `connect` / `listen` / `Session` / `Host` over the byte-fed host, plus `Context`, the value vocabulary, and the locator grammar. Asyncio-driven; transport chosen by locator (typically `pancake.tcp`, `pancake.inproc`, or `pancake.iroh`). |
| `pancake.tcp`    | `libpancake_net_transport_tcp`                      | `TcpNetlayer`, `TcpListener`, `TcpEndpoint`: the blocking `pancake_tcp_*` frame shuttle                                                                    |
| `pancake.inproc` | `libpancake_net_transport_inproc`                   | `InprocNetlayer`, `InprocListener`, `InprocConn`: the socket-free in-process shuttle                                                                       |
| `pancake.iroh`   | `libpancake_net_transport_iroh`                     | `listen_iroh`, `Reachability`: encrypted QUIC (loaded lazily; dial via `pancake.connect` on an `ocapn://…iroh` locator)                                                                |

The internal per-archive `ctypes` loaders ([`_ffi_ocapn`](pancake/_ffi_ocapn.py),
[`_ffi_driver`](pancake/_ffi_driver.py), [`_ffi_tcp`](pancake/_ffi_tcp.py),
[`_ffi_inproc`](pancake/_ffi_inproc.py), and [`_ffi_iroh`](pancake/_ffi_iroh.py))
resolve archives through [`_lib_resolve`](pancake/_lib_resolve.py): configure,
then the abi-versioned cache, then `zig-out`, then find. The ABI constants in
[`_constants`](pancake/_constants.py) are `_`-private and never imported by a
consumer. Each companion archive reuses the core's `ctypes` `Structure` types by
layout, the same way the C headers share `pancake_ocapn.h`, and routes its own
errors through its own `pancake_<family>_last_error` slot. The signature tables
the loaders bind are generated from the Zig exports
([`_sigs_gen`](pancake/_sigs_gen.py), `zig build gen-binding-python-ffi`, held
fresh by the check build), so a C-side signature change regenerates them. The
struct mirrors themselves stay hand-declared — pinned at import time against
the generated layout facts in [`_layouts_gen`](pancake/_layouts_gen.py) — so a
C-side layout change is swept into the `_ffi_*` modules by hand, the same
standing gap the Racket binding names. The package ships a `py.typed` marker,
so type checkers read its inline annotations (PEP 561).

The core public surface is split by responsibility across `_`-private
submodules that the package `__init__` re-exports as a barrel: errors, values,
the argument codec, locators, the behavior trampoline, `Host`, host actions,
promises, GC, dial and listen, the byte-fed pump, and the `Session` verbs.
Import every name from `pancake`; the submodule layout is internal and may
change.

## The API

What you hold is a `Session` over the byte-fed host. The library owns framing,
routing, three-party redemption, and gift origination. The binding moves bytes
and honors the host's action queue. Values are native Python: `int`, `float`,
`bool`, `bytes`, `str`, `list`, plus `Symbol` / `Keyword` / `Set` / `Tagged`
and the capability `Ref`:

```python
from pancake import connect, tcp_locator

# tcp: the peer is a place, a cleartext host and port.
partner = tcp_locator("127.0.0.1", 9099)

session = await connect(partner)
session.serve()

greeter = await session.fetch("greeter")  # a capability, by name
try:
    reply = await session.send(greeter, "greet", ["world"])
    print(reply)
except Exception as reason:
    print(f"the greeter refused: {reason}")

await session.close()
```

Hosting is the same surface from the other side. `await listen(bind_host, 0)`
returns a `Server` whose iterator yields a ready `Session` per partner.
`session.publish(name, behavior)` and `session.spawn(behavior)` host plain callables
as actors. A `send` returns a `RemotePromise` (a real `asyncio.Future`) that is
itself a valid `send` target, so a dependent chain pipelines in one round trip.
A host's identity and gift registry are shared through `server.host` /
`connect(..., host=...)`, which is what makes a three-party handoff
transparent.

The blocking shuttles are à la carte:

```python
from pancake.tcp import TcpNetlayer        # or pancake.inproc / pancake.iroh

with TcpNetlayer() as nl:
    listener = nl.listen("127.0.0.1", 0)
    endpoint = nl.connect("127.0.0.1", listener.port())
```

`connect` reaches `pancake.iroh` lazily on the first `iroh` locator, so a
TCP-only program never loads `libpancake_net_transport_iroh` (the optional cargo
artifact, built with `zig build iroh-abi`).

[`zig_smoke.py`](zig_smoke.py) is the consumer `zig build bindings` runs. It
drives a real OCapN round-trip through that API. The build step resolves the
shared library relative to `zig-out/`. CPython 3.11+ on an LP64 platform is
required.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
