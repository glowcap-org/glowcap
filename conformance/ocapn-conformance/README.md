# conformance/ocapn-conformance

Native wrapper for the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite). The suite lives
in the `upstream/` submodule; this directory owns only the invocation wrapper.

## Setup

Initialize submodules once:

```sh
bash conformance/bootstrap-submodules.sh
```

The wrapper runs through `uv`, which the devcontainer provides.

## Running

Start a target peer, then point the suite at the OCapN URL it prints. For the
bundled Goblins target:

```sh
# Terminal 1
bash conformance/goblins-peer/run.sh seven-caps-peer

# Terminal 2
bash conformance/ocapn-conformance/run.sh test \
  'ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045'
```

Useful wrapper checks:

```sh
bash conformance/ocapn-conformance/run.sh smoke
bash conformance/ocapn-conformance/run.sh shell
```

## Running Against pancake

The suite can be pointed at a *pancake* peer, not only Goblins.
`pancake_peer.zig` serves the canonical conformance swiss-nums over the
`tcp-testing-only` netlayer, and `run-against-pancake.sh` starts it and runs the
suite against it:

```sh
zig build ocapn-conformance              # default: all targeted modules
zig build ocapn-conformance -Dport=23055 # move the peer off 22055 when that port is taken
bash conformance/ocapn-conformance/run-against-pancake.sh tests.op_deliver  # one module
```

Against the external authority, pancake passes the targeted upstream modules the
wrapper runs:

| Module | What it exercises |
| --- | --- |
| `tests.op_start_session` | Valid keyed handshakes, invalid signature/version aborts, and crossed-hellos resolution. |
| `tests.op_abort` | Aborting before a session is fully established. |
| `tests.op_deliver` | Deliveries with and without answers, promise pipelining, and broken-promise propagation. |
| `tests.op_listen` | Listening to pending and already-settled promises. |
| `tests.op_gc` | Answer and export garbage-collection messages. |
| `tests.third_party_handoffs` | Handoff-give and handoff-receive flows, including wait-before-deposit. |

`handshake_abort_probe.py` remains a focused diagnostic for malformed handshake
cases if a suite regression needs isolating. It is not part of the default
`zig build ocapn-conformance` path.

Two details keep the suite's verdict honest. The Syrup codec consumes a
non-empty hints map, because the suite's `tcp-testing-only` netlayer carries the
address in the locator hints (`{host …, port …}`) — a peer that rejected
non-empty hints would abort the handshake before any signature was checked,
passing the invalid-version and invalid-signature tests for the wrong reason.
And signature verification reads the captured raw locator bytes, never a
re-encode of them.

## What This Proves

The suite is external conformance pressure. A green run against
`goblins-peer/` proves the upstream suite, the native wrapper, the slim Goblins
target, and its testing TCP netlayer compose; a run against `pancake_peer.zig`
turns the same authority on pancake itself. It is not the `zig build check`
gate and it is not the semantic oracle for Zig code by itself.

Pancake's in-tree gate remains `zig build oracle-check` / `zig build check`.
Those gates cover the checked protocol scenarios and pancake-authored Syrup
fixtures consumed by the Zig implementation.

## Posture

- `upstream/` is read-only. Bump the submodule pin; do not edit it in place.
- `run.sh` is pancake-owned and should stay a thin native wrapper.
- `tcp-testing-only` is a conformance/testing transport, not a production
  transport claim.
