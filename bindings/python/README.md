# bindings/python

This package is a Python consumer of the pancake C ABI archives, built on
`ctypes` with the standard library alone. The C ABI ships as a set of
composable, symbol-disjoint archives (ADR-0059), and this package mirrors that
split à la carte: a core package over `libpancake_ocapn` plus its byte-fed host
companion `libpancake_driver` (ADR-0072), and one submodule per transport. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## Composable submodules, one per archive

Each module loads only its own archive, so importing one transport never loads
another. Compose what you need, exactly as a C consumer links archives à la
carte:

| Module           | Archive it loads                                    | Surface                                                                                                                                                     |
| ---------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pancake` (core) | `libpancake_ocapn` + `libpancake_driver` (ADR-0072) | `connect` / `listen` / `Session` / `Host` over the byte-fed host, `Context`, the value vocabulary, and the locator grammar (asyncio-driven; transport chosen by locator — typically `pancake.tcp`, `pancake.inproc`, or `pancake.iroh`) |
| `pancake.tcp`    | `libpancake_net_transport_tcp`                      | `TcpNetlayer`, `TcpListener`, `TcpEndpoint`: the blocking `pancake_tcp_*` frame shuttle                                                                    |
| `pancake.inproc` | `libpancake_net_transport_inproc`                   | `InprocNetlayer`, `InprocListener`, `InprocConn`: the socket-free in-process shuttle                                                                       |
| `pancake.iroh`   | `libpancake_net_transport_iroh`                     | `listen_iroh`, `Reachability`: encrypted-QUIC (loaded lazily; dial via `pancake.connect` on an `ocapn://…iroh` locator)                                                                |

The internal per-archive `ctypes` loaders ([`_ffi_ocapn`](pancake/_ffi_ocapn.py),
[`_ffi_driver`](pancake/_ffi_driver.py), [`_ffi_tcp`](pancake/_ffi_tcp.py),
[`_ffi_inproc`](pancake/_ffi_inproc.py), and [`_ffi_iroh`](pancake/_ffi_iroh.py))
resolve archives through [`_lib_resolve`](pancake/_lib_resolve.py) (the shared
configure → abi-versioned cache → `zig-out` → find cascade), and the ABI
constants in [`_constants`](pancake/_constants.py) are `_`-private and never
imported by a consumer. Each companion archive reuses the core's
`ctypes` `Structure` types by layout, the same way the C headers share
`pancake_ocapn.h`, and routes its own errors through its own
`pancake_<family>_last_error` slot. The struct mirrors are hand-declared — the
same standing gap the Racket binding names — so a C-side layout change is swept
into the `_ffi_*` modules by hand. The package ships a `py.typed` marker, so
type checkers read its inline annotations (PEP 561).

The core public surface is itself split by responsibility across `_`-private
submodules that the package `__init__` re-exports as a barrel: the typed errors
in [`_errors`](pancake/_errors.py), the value and reference vocabulary in
[`_value`](pancake/_value.py), the `ctypes` argument codec in
[`_codec`](pancake/_codec.py), the allocation `Context` in
[`_context`](pancake/_context.py), the locator URI grammar in
[`_locator`](pancake/_locator.py), the shared behavior trampoline in
[`_trampoline`](pancake/_trampoline.py), the CapTP `Host` (the host handle and
vow table; kick/park) in [`_host`](pancake/_host.py), host-action
decode+execute in [`_action`](pancake/_action.py), the `RemotePromise` handle
in [`_promise`](pancake/_promise.py), distributed GC in [`_gc`](pancake/_gc.py),
the dial executor + `connect` in [`_dial`](pancake/_dial.py), `Server` /
`listen` in [`_listen`](pancake/_listen.py), the byte-fed embedder pump in
[`_pump`](pancake/_pump.py), and the `Session` verbs + mint/handshake in
[`_session`](pancake/_session.py). Import every name from `pancake`. The
submodule layout is internal and may change.

## The API

What you hold is a `Session` over the byte-fed host: the library owns
framing, routing, three-party redemption, and gift origination, and the binding
moves bytes and honors the host's action queue. Values are native Python —
`int`, `float`, `bool`, `bytes`, `str`, `list`, plus `Symbol` / `Keyword` /
`Set` / `Tagged` and the capability `Ref`:

```python
from pancake import connect, tcp_locator

conn = await connect(tcp_locator("127.0.0.1", 9099))
conn.serve()
greeter = await conn.fetch("greeter")            # a capability, by name
reply = await conn.send(greeter, "greet", ["world"])
await conn.close()
```

Hosting is the same surface from the other side: `await listen(bind_host, 0)`
returns a `Server` whose iterator yields a ready `Session` per partner, and
`conn.publish(name, behavior)` / `conn.spawn(behavior)` host plain callables as
actors. A `send` returns a `RemotePromise` (a real `asyncio.Future`) that is
itself a valid `send` target, so a dependent chain pipelines in one round trip.
A host's identity and gift registry are shared through `server.host` /
`connect(..., host=...)`, which is what makes a three-party handoff
transparent.

The blocking shuttles are à la carte:

```python
from pancake.tcp import TcpNetlayer        # or pancake.inproc / pancake.iroh

with TcpNetlayer() as nl:
    listener = nl.listen("127.0.0.1", 0)
    conn = nl.connect("127.0.0.1", listener.port())
```

`connect` reaches `pancake.iroh` lazily on the first `iroh` locator, so a
TCP-only program never loads `libpancake_net_transport_iroh` (the optional cargo
artifact, built with `zig build iroh-abi`).

[`zig_smoke.py`](zig_smoke.py) is the consumer `zig build bindings` runs: it
drives a real OCapN round-trip through that API. The build step resolves the
shared library relative to `zig-out/`; CPython 3.11+ on an LP64 platform is
required.

```sh
zig build bindings        # builds the pancake archives, runs every binding consumer
```
