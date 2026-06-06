# conformance/goblins-peer

Slim Spritely Goblins OCapN peer packaged for pancake conformance work. It gives
pancake a real Goblins-shaped peer for wire-shape lookup, local demos, and the
upstream OCapN test suite target.

This is not Spritely Goblins itself. The upstream source lives in the
`../spritely-goblins/upstream/` submodule; this directory contains pancake-owned
wrappers and small Racket programs around that API.

## Files

| File | Role |
| --- | --- |
| `racket/tcp-netlayer.rkt` | Testing TCP netlayer for loopback OCapN runs. |
| `racket/captp-demo.rkt` | In-process CapTP demo over Goblins fake-intarwebs. |
| `racket/tcp-demo.rkt` | Two Goblins peers over local TCP; exits after one roundtrip. |
| `racket/three-vat-demo.rkt` | Three-party introduction over local TCP. |
| `racket/seven-caps-peer.rkt` | Long-running peer registering the seven caps expected by the OCapN suite. |
| `run.sh` | Native launcher using the devcontainer's `racket`; no pixi layer. |

## Running

```sh
bash conformance/goblins-peer/run.sh seven-caps-peer
bash conformance/goblins-peer/run.sh smoke
bash conformance/goblins-peer/run.sh run captp-demo.rkt
bash conformance/goblins-peer/run.sh run tcp-demo.rkt
bash conformance/goblins-peer/run.sh run three-vat-demo.rkt
```

To target it with the upstream suite:

```sh
# Terminal 1
bash conformance/goblins-peer/run.sh seven-caps-peer

# Terminal 2: use the URL printed by terminal 1.
bash conformance/ocapn-conformance/run.sh test \
  'ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045'
```

## How Pancake Uses This

- **As an external peer.** Goblins emits OCapN/Syrup bytes pancake must parse and
  answer correctly.
- **As a conformance-suite target.** `seven-caps-peer.rkt` supplies the target
  capabilities the upstream Python suite expects.
- **As a wire-shape lookup.** When the Zig implementation needs evidence for a
  Goblins-canonical shape, this peer can produce it on the wire.

## Posture

- The demos are editable pancake-owned wrappers.
- `seven-caps-peer.rkt` must stay compatible with the upstream suite's expected
  cap behavior.
- The testing TCP netlayer is cleartext loopback infrastructure, not a
  production transport claim.
