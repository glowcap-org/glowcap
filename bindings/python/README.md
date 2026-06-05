# pancake-python

Python `ctypes` bindings for the **libpancake** C-ABI cdylib family — a
codec-neutral CapTP runtime for OCapN. Pure standard library (`ctypes`
only); no third-party dependencies. Targets CPython 3.11+ on LP64
platforms (x86_64 / aarch64 Linux + macOS).

This is a faithful Python port of the proven Racket binding at
[`../pancake-goblins/racket/pancake-ffi.rkt`](../pancake-goblins/racket/pancake-ffi.rkt):
the same env-driven 3-library load, the same fixed-size tagged-union
marshalling, the same per-library last-error slots, and the same
single-thread poll pump.

## What it binds

Three prebuilt cdylibs (named by environment variable):

| Env var | cdylib | Surface |
| --- | --- | --- |
| `PANCAKE_LIB` | `libpancake_ffi_runtime` | protocol core: peer lifecycle, step/queues, typed values, send/recv, cross-peer, keypair, OCapN-URI parse, syrup-frame-probe |
| `PANCAKE_NET_TCP_LIB` | `libpancake_ffi_net_tcp` | cleartext + TLS TCP endpoints |
| `PANCAKE_NET_IROH_LIB` | `libpancake_ffi_net_iroh` | QUIC-over-iroh endpoints |

The full C ABI surface of all three is bound. The `pancake-ffi-abi` panic
seam (with its per-thread last-error slot) is statically linked into each
cdylib, so `pancake_last_error` is bound **once per loaded library** — a
net-tcp failure stashes its diagnostic in the net-tcp slot, not the runtime
slot.

## Layout

```
pancake/
  _abi.py        shared loader, PancakeFrame, error codes, per-lib last_error
  _runtime.py    ctypes bindings for libpancake_ffi_runtime (full surface)
  _net_tcp.py    ctypes bindings for libpancake_ffi_net_tcp (cleartext + TLS)
  _net_iroh.py   ctypes bindings for libpancake_ffi_net_iroh (QUIC)
  constants.py   every PANCAKE_* constant, mirrored from the headers
  values.py      typed tagged-union marshal + projection (Reference/Argument/Resolution)
  host.py        Runtime / Peer / KeyPair / SturdyrefDedup high-level API
  netlayer.py    TransportOps + Connection/Listener (TCP/TLS/iroh)
  pump.py        single-thread poll pump (Bridge + run_until)
  scenarios.py   verification scenarios
  __init__.py    public re-exports
pyproject.toml
README.md
```

## ABI contracts honored

1. **One frame model per direction.** Inbound (`feed_inbound`) lends a bare
   `PancakeFrame` `(bytes,len)` the runtime borrows for the call (zero-copy,
   nothing to free). Outbound (`take_outbound`) and netlayer `read_frame`
   hand back a self-describing `PancakeManagedFrame`; every such buffer —
   from the runtime or either netlayer cdylib — is released via the single
   `pancake_managed_frame_release`, **never** `libc.free`.
2. **Typed diagnostics** from the runtime's send / `feed_inbound` paths
   (codes `-3`/`-4`/`-5`/`-6`) are surfaced via the per-library last-error
   slot in `PancakeError`.
3. **Fixed-size tagged unions**: `PancakeReference` (kind `u32`, pad `u32`,
   payload `[32]`), `PancakeArgument` (payload `[40]`), `PancakeResolution`
   (payload `[48]`), payload at offset 8; `Far`/`Sturdy` payloads are
   `{ptr, len, u64}` triples. Receive-side projection copies out, then calls
   the matching `pancake_typed_*_free`.
4. **LP64, 64-bit pointers.**

## Usage

Set the three env vars to the absolute `target/release/*.so` paths, then:

```python
from pancake import Runtime, TcpNetlayer, Bridge, run_until, both_open
from pancake.constants import PANCAKE_CODEC_SYRUP

rt = Runtime()
print(rt.version())                          # "pancake-ffi 0.1.0"

kp = rt.keypair_from_seed(b"\x00" * 32)
peer = rt.peer_new(kp, PANCAKE_CODEC_SYRUP)  # peer takes ownership of kp
```

The poll pump (`pump.Bridge` + `run_until`) drives `feed_inbound` / `step` /
`take_outbound` / `write_frame` against a netlayer `Connection`, using
`set_read_timeout_ms(50)` + a `0.001 s` inter-tick yield.

## Verification

```bash
export PANCAKE_LIB=/abs/path/target/release/libpancake_ffi_runtime.so
export PANCAKE_NET_TCP_LIB=/abs/path/target/release/libpancake_ffi_net_tcp.so
export PANCAKE_NET_IROH_LIB=/abs/path/target/release/libpancake_ffi_net_iroh.so

python3 -m pancake.scenarios all
# or a single scenario:
python3 -m pancake.scenarios handshake-tcp-loopback
python3 -m pancake.scenarios handshake-tcp-tls-loopback
```

Scenarios: `version`, `ocapn-uri-parse`, `value-roundtrip`,
`syrup-frame-probe`, `handshake-tcp-loopback`, `handshake-tcp-tls-loopback`.

### Verified output (`python3 -m pancake.scenarios all`)

```
[version] pancake_version() = 'pancake-ffi 0.1.0'
OK: version

[uri] parsing peer-locator form…
  ✓ transport='tcp-testing-only' designator='IO58l1laTyhcrgDKbEzFOO32MDd6zE5w' swissnum=None
[uri] parsing OCapN spec sturdyref form…
  ✓ transport='iroh' designator='abc' swissnum=b'\x00\x01\x02\x03\xff\xfe\xfd\xfc'
[uri] asserting non-ocapn scheme is rejected…
  ✓ rejected: pancake_ocapn_uri_parse: parse failed — expected scheme `ocapn`, got `http`
OK: ocapn-uri-parse

[value] building mixed String/Integer/nested-List args…
  marshalled+projected: [('list', [('string', 'hello'), ('integer', 42), ('list', [('string', 'nested-a'), ('string', 'nested-b')])])]
OK: value-roundtrip (String / Integer / nested-List intact)

[frame-probe] probing a complete Syrup integer frame…
  ✓ COMPLETE at end=3 (frame = b'42+')
OK: syrup-frame-probe

[loopback] pancake version: pancake-ffi 0.1.0 (transport=tcp-testing-only)
[loopback] server listening on 127.0.0.1:31098
[loopback] server accepted
[loopback] dialer connected to 127.0.0.1:31098
[loopback] dialer pubkey[:4]=d61cf605 server pubkey[:4]=92feecae
[loopback] dialer my-peer-id[:4]=94d4f11b server my-peer-id[:4]=00bea9f6
[loopback] states: dialer=Negotiating server=Open
[loopback] states: dialer=Open server=Open
[loopback] ✓ BOTH peers reached SESSION_OPEN
[loopback] dialer learned partner-peer-id[:4]=00bea9f6
[loopback] server learned partner-peer-id[:4]=94d4f11b
OK: handshake-tcp-loopback

============================================================
ALL SCENARIOS PASSED
============================================================
```

The TCP+TLS loopback (`handshake-tcp-tls-loopback`) likewise reaches
`SESSION_OPEN` on both peers over the rustls surface.

> Note: dialing runs on a background thread so `connect` and `accept` proceed
> concurrently — required for `tcp-tls`, whose `connect` blocks on the inline
> TLS handshake until the server accepts. `ctypes` releases the GIL during the
> foreign call, so the two FFI calls genuinely run in parallel.
