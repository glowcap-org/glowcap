# conformance/ocapn-conformance

Wrapper for the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite). The suite lives
in the `upstream/` submodule. This directory holds only the invocation wrapper.

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

## Running Against glowcap

The suite can also be pointed at a glowcap peer.
`glowcap_peer.zig` serves the canonical conformance swiss-nums over the
`tcp-testing-only` netlayer, and `run-against-glowcap.sh` starts it and runs the
suite against it. The peer is the production Host stack plus what the Host
cannot know: the conformance actors and three suite-required interceptors on
the serve path (a promise-resolver bootstrap object, the recipient's give
redeem, and the gifter's enliven claim), each driving library seams. The
file's header inventories them.

```sh
zig build ocapn-conformance              # default: every upstream test module
zig build ocapn-conformance -Dport=23055 # move the peer off 22055 when that port is taken
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_deliver  # one module
```

The wrapper derives its module list from the upstream tree itself
(`upstream/tests/*.py`), so a submodule bump that adds a module fails the run
until glowcap targets it. It runs every upstream module except `tests.op_abort`:
that test does not accept Linux's TCP-reset form of teardown. The wrapper's
abort probe uses the suite's netlayer and message types for the same case and
requires observable EOF, reset, or broken pipe. A timeout fails. The raw
upstream module remains available as a diagnostic.

| Module                       | What it exercises                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------------------- |
| `tests.op_start_session`     | Valid keyed handshakes, invalid signature/version aborts, and crossed-hellos resolution. |
| local abort probe            | Aborting before a session is fully established, with portable teardown outcomes.         |
| `tests.op_deliver`           | Deliveries with and without answers, promise pipelining, and broken-promise propagation. |
| `tests.op_listen`            | Listening to pending and already-settled promises.                                       |
| `tests.op_gc`                | Answer and export garbage-collection messages.                                           |
| `tests.third_party_handoffs` | Handoff-give and handoff-receive flows, including wait-before-deposit.                   |

Crossed-hellos cases in `op_start_session` can use most of a module's time
budget, so a slow machine can hit the 5s per-module cap on a module that would
have passed. Raise it with `OCAPN_MODULE_TIMEOUT` (and the probe's with
`OCAPN_PROBE_TIMEOUT`) before reading a timeout as a protocol failure.
`handshake_abort_probe.py` covers invalid signature, invalid version, and
pre-setup abort teardown alone. The default
`zig build ocapn-conformance` wrapper runs that probe (10s cap) before the suite
modules. Pass `--port=N` or set `GLOWCAP_OCAPN_CONFORMANCE_PORT` to match the
peer. To run one module or the probe alone:

```sh
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_start_session
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_abort # raw upstream diagnostic
uv run --project conformance/ocapn-conformance --locked \
  python conformance/ocapn-conformance/handshake_abort_probe.py --port=22055
```

Two details keep the suite's verdict valid. The Syrup codec consumes a
non-empty hints map, because the suite's `tcp-testing-only` netlayer carries the
address in the locator hints (`{host …, port …}`). A peer that rejected
non-empty hints would abort the handshake before any signature was checked,
and would pass the invalid-version and invalid-signature tests for the wrong
reason. Signature verification also reads the captured raw locator bytes, not
a re-encode of them.

## What a green run shows

A green run against `goblins-peer/` shows that the upstream suite, the wrapper,
the slim Goblins target, and its testing TCP netlayer work together. A run
against `glowcap_peer.zig` applies the same suite to glowcap itself. Neither is
part of `zig build check`, and neither alone is the semantic authority for Zig
code.

The in-tree checks are `zig build oracle-check` and `zig build check`. They
cover the protocol scenarios and the Syrup fixtures the Zig implementation
consumes.

## Posture

- `upstream/` is read-only. Bump the submodule pin instead of editing it.
- `run.sh` is glowcap's own and stays a thin wrapper.
- `tcp-testing-only` is a testing transport, not a production one.
