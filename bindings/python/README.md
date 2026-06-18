# bindings/python

A Python (`ctypes`, standard library only) consumer of the pancake C ABI
archives. The C ABI ships as a set of composable, symbol-disjoint archives
(ADR-0059), and this package mirrors that à la carte: a core package over
`libpancake_ocapn`, plus one submodule per transport. See
[`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## Composable submodules, one per archive

Each module loads only its own archive, so importing the core never loads a
transport and importing one transport never loads another. Compose what you
need, exactly as a C consumer links archives à la carte:

| Module           | Archive it loads                  | Surface                                                                                                                                                                |
| ---------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pancake` (core) | `libpancake_ocapn`                | `Peer`, `Context`, `Vat`, the value/event vocabulary, the locator grammar, and the async transport-neutral `connect` / `listen` / `Connection` (pure asyncio over TCP) |
| `pancake.tcp`    | `libpancake_net_transport_tcp`    | `TcpNetlayer`, `TcpListener`, `TcpEndpoint` — the blocking `pancake_tcp_*` frame shuttle                                                                               |
| `pancake.inproc` | `libpancake_net_transport_inproc` | `InprocNetlayer`, `InprocListener`, `InprocConn` — the socket-free in-process shuttle                                                                                  |
| `pancake.iroh`   | `libpancake_net_transport_iroh`   | `listen_iroh`, `connect_iroh`, `Reachability` — encrypted-QUIC (loaded lazily, on first use)                                                                           |

The internal per-archive `ctypes` loaders — [`_ffi_core`](pancake/_ffi_core.py),
[`_ffi_tcp`](pancake/_ffi_tcp.py), [`_ffi_inproc`](pancake/_ffi_inproc.py), and
[`_ffi_iroh`](pancake/_ffi_iroh.py) — and the ABI constants in
[`_constants`](pancake/_constants.py) are `_`-private and never imported by a
consumer. Each transport reuses the core's `ctypes` `Structure` types by layout,
the same way the C headers share `pancake_ocapn.h`, and routes its own errors
through its own `pancake_<transport>_last_error` slot. The package ships a
`py.typed` marker, so type checkers read its inline annotations (PEP 561).

## The API

What you use is a `Peer` context manager, native Python values as arguments, and
typed event objects. The default `Peer()` is a negotiating authenticated
session; use `Peer.raw_open()` only for low-level fixtures that inject frames
directly:

```python
from pancake import Peer, Far

with Peer.raw_open() as peer:
    peer.register_import(5)
    peer.send_deliver(Far(5), [42, b"hi"], answer=9)   # native int, bytes
    peer.step()
    frame = peer.take_outbound()
    # ...and poll() returns Deliver / Resolve / Other dataclasses
```

A transport is one import away. The async application surface (`connect`,
`listen`, `Connection`) lives in the core and drives TCP over asyncio without a
transport archive; the blocking shuttles are à la carte:

```python
from pancake import Peer
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
