# bindings/python

A Python (`ctypes`, standard library only) consumer of the Zig `libpancake` C
ABI. See [`../README.md`](../README.md) for the shipped C ABI surface and how the
bindings are gated.

## The API

[`pancake.py`](pancake.py) is the idiomatic Python API over the C ABI. The raw
`ctypes` FFI is private; what you use is a `Peer` context manager, native Python
values as arguments, and typed event objects:

```python
with Peer() as peer:
    peer.register_import(5)
    peer.send_deliver(Far(5), [42, b"hi"], answer=9)   # native int, bytes
    peer.step()
    frame = peer.take_outbound()
    # ...and poll() returns Deliver / Resolve / Other dataclasses
```

[`zig_smoke.py`](zig_smoke.py) is the consumer `zig build bindings` runs: it
drives a real OCapN round-trip through that API. The build step resolves the
shared library relative to `zig-out/`; CPython 3.11+ on an LP64 platform is
required.

```sh
zig build bindings        # builds libpancake, runs every binding consumer
```
