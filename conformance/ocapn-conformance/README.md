# conformance/ocapn-conformance

Runs the upstream [OCapN test suite](https://github.com/ocapn/ocapn-test-suite)
against a Goblins peer or against glowcap. The suite lives in the `upstream/`
submodule, and this directory holds the wrappers that invoke it.

## Setup

Initialize submodules once. The wrappers run through `uv`, which the
devcontainer provides.

```sh
bash conformance/bootstrap-submodules.sh
```

## Running

Start a target peer, then point the suite at the OCapN URL it prints. This is
the bundled Goblins target:

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

## Adoption accounting

The [conformance manifest](../../docs/ocapn-conformance.md) fingerprints every
Python source in this suite, shared setup included, and records whether each
is adopted, deferred, or pending. The live suite steps run
`zig build ocapn-adoption-check` before starting a peer, so a suite bump fails
until its changes are reviewed there. Baseline and next have separate rows.
The next runner consumes those same rows as execution policy: pending sources
fail, deferred modules name their decision, and adopted modules must pass
without skips.

## Running Against glowcap

`glowcap_peer.zig` serves the canonical conformance swiss-nums over the
`tcp-testing-only` netlayer, and `run-against-glowcap.sh` starts it and runs the
suite against it. The peer is the production Host stack plus the conformance
actors and three suite-required interceptors on the serve path: a
promise-resolver bootstrap object, the recipient's give redeem, and the
gifter's enliven claim. The file's header inventories them.

```sh
zig build ocapn-conformance              # default: every upstream test module
zig build ocapn-conformance -Dport=23055 # move the peer off 22055 when that port is taken
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_deliver  # one module
```

`zig build ocapn-conformance-onion` runs the same suite over onion. It needs
an operator-supplied Tor (`GLOWCAP_OCAPN_TOR_SOCKS` and
`GLOWCAP_OCAPN_TOR_CONTROL`, both `host:port`) and network access.
`run-against-glowcap-onion.sh` starts the onion peer, and the suite dials it
through its own pinned onion netlayer.

The wrapper discovers Python test modules recursively under `upstream/tests/`, so a submodule
bump that adds a module fails the run until glowcap targets it. It runs every
upstream module except `tests.op_abort`, which does not accept Linux's
TCP-reset form of teardown. A local abort probe covers the same case with the
suite's netlayer and message types. It requires observable EOF, reset, or
broken pipe, and a timeout fails. The raw upstream module stays available as a
diagnostic.

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
have passed. Raise it with `OCAPN_MODULE_TIMEOUT` (the probe's 10s cap uses
`OCAPN_PROBE_TIMEOUT`) before reading a timeout as a protocol failure.

`handshake_abort_probe.py` covers invalid signature, invalid version, and
pre-setup abort teardown. `zig build ocapn-conformance` runs it before the suite
modules. Pass `--port=N` or set `GLOWCAP_OCAPN_CONFORMANCE_PORT` to match the
peer. To run one module or the probe alone:

```sh
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_start_session
bash conformance/ocapn-conformance/run-against-glowcap.sh tests.op_abort # raw upstream diagnostic
uv run --project conformance/ocapn-conformance --locked \
  python conformance/ocapn-conformance/handshake_abort_probe.py --port=22055
```

Two details keep the suite's verdict valid:

- The Syrup codec accepts a non-empty hints map, because the `tcp-testing-only`
  netlayer carries the address in the locator hints (`{host …, port …}`). A peer
  that rejected them would abort before checking any signature and pass the
  invalid-version and invalid-signature tests for the wrong reason.
- Signature verification reads the captured raw locator bytes, not a re-encode
  of them.

## Next with the retained opening

`zig build ocapn-conformance-next` runs baseline conformance first, then fixture
regressions and the next lane. It uses the production Host configured for next
and Syrup. Signed locator hints offer next using the shared four-field hello.
The next hint names the fingerprint of the build's own wire (ADR-0001), and
`next_wire.py` reads it from `src/ocapn/model/own_wire.zig`.
The fixture checks the signature and chosen profile before operations.

`next_wire.py` adapts the pinned suite's baseline constructors at the socket
boundary. Production deliveries must have the draft wire shape. The runner
keeps upstream assertions and deliberate bad-certificate mutations, choosing
32-byte gift IDs before signing. `next_cases.py` checks draft delivery forms,
inline modes, promise arguments, shared resolver callbacks during pipelining,
and refusal of removed projections. Upstream files stay unmodified.

The next rows defer `tests/op_start_session.py` to the crypto transition plan.
Both profiles replace the reset-sensitive `tests/op_abort.py` with the strict
portable probe. Next also defers `test_runner.py` because `next_runner.py` owns
its policy and fixture, and `netlayers/onion.py` because this lane is TCP-only.
These replacements are explicit coverage limits, never passing upstream cases.
Shared hello setup and message types remain fingerprinted for both profiles.
A suite update that changes them requires review and adapter changes.

## What a green run shows

A green run against `goblins-peer/` shows that the upstream suite, the wrapper,
the slim Goblins target, and its testing TCP netlayer work together. A run
against `glowcap_peer.zig` applies the same suite to glowcap itself. Neither is
part of `zig build check`, and neither alone is the semantic authority for Zig
code. `zig build oracle-check` and `zig build check` cover the protocol
scenarios and Syrup fixtures the Zig implementation consumes.

## Posture

- `upstream/` is read-only. Bump the submodule pin instead of editing it.
- `run.sh` is glowcap's own and stays a thin wrapper.
- `tcp-testing-only` is a testing transport, not a production one.
