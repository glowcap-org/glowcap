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
zig build ocapn-conformance              # default: tests.op_start_session
bash conformance/ocapn-conformance/run-against-pancake.sh tests.op_deliver  # other modules
```

Against the external authority, pancake passes the suite's `op:start-session`
conformance:

- **Valid keyed handshake.** pancake answers a valid start-session, and the suite
  parses pancake's own start-session (version, gcrypt public key, signed `tcp`
  locator).
- **Partner signature verification.** A negotiating peer verifies the partner's
  handshake by default (`Peer.verify_partner_handshake`, which
  `initNegotiating` enables — the same secure default the bindings and driver
  inherit), so an `op:start-session` whose location signature does not verify
  against the claimed key is refused with an `InvalidStartSessionSignature`
  `op:abort` — partner signatures are checked, not trusted. The check runs at the
  engine boundary over the *exact received* location bytes
  (`acceptable_location_raw`), so a locator's hints stay covered even though the
  borrowed decode does not retain them; the session core still runs no crypto.
- **Invalid version.** An unrecognized captp-version is refused with an
  `op:abort`.

`zig build ocapn-conformance` pins all three — the valid handshake through the
suite module, and the two abort cases through `handshake_abort_probe.py` (which
drives the suite's own netlayer + message types). It fails loudly on a
regression.

One scenario the suite checks is a named, not-yet-implemented gap, so the step
does not assert it:

- **Crossed-hellos mitigation.** Simultaneous mutual connection attempts are not
  detected. (These cases also sort before the abort cases in the suite module and
  block on its receive timeout, which is why the abort cases are driven by the
  probe rather than the module run.)

A note on history: decoding a locator's hints map was the bug that hid the
signature behavior. The suite's `tcp-testing-only` netlayer puts the address in
the locator hints (`{host …, port …}`); pancake's Syrup codec rejected any
non-empty hints, so it aborted the handshake before reaching the signature —
making the invalid-version and invalid-signature tests pass for the wrong reason.
The codec now consumes a non-empty hints map (Goblins uses `#f` hints, which is
why this went unseen), and verification reads the captured raw bytes, so the
suite's verdict is honest.

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
