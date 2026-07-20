# conformance/goblins-peer

Slim Spritely Goblins OCapN peer packaged for pancake conformance work. It gives
pancake a real Goblins-shaped peer for wire-shape lookup, local demos, and the
upstream OCapN test suite target.

This is not Spritely Goblins itself. The upstream source lives in the
`../spritely-goblins/upstream/` submodule; this directory contains pancake-owned
wrappers and small Racket programs around that API.

## Files

### Shared

| File                      | Role                                               |
| ------------------------- | -------------------------------------------------- |
| `racket/tcp-netlayer.rkt` | Testing TCP netlayer for loopback OCapN runs.      |
| `run.sh`                  | Native launcher using the devcontainer's `racket`. |

### Demos and suite target

| File                         | Role                                                                      |
| ---------------------------- | ------------------------------------------------------------------------- |
| `racket/captp-demo.rkt`      | In-process CapTP demo over Goblins fake-intarwebs.                        |
| `racket/tcp-demo.rkt`        | Two Goblins peers over local TCP; exits after one roundtrip.              |
| `racket/three-vat-demo.rkt`  | Three-party introduction over local TCP.                                  |
| `racket/seven-caps-peer.rkt` | Long-running peer registering the seven caps expected by the OCapN suite. |

### Live Goblins interop (`zig build goblins-interop` and siblings)

| File                              | Role                                                                                         |
| --------------------------------- | -------------------------------------------------------------------------------------------- |
| `racket/goblins-host.rkt`         | Echo + Struct host pancake dials as client (NDJSON readiness).                               |
| `racket/gc-echo-host.rkt`         | Echo host with a background collect loop, so `op:gc-exports` fires within `goblins-gc`'s deadline. |
| `racket/pancake-actor-call.rkt`   | Goblins client: settle-call a pancake-hosted actor.                                          |
| `racket/goblins-tap-dialer.rkt`   | Goblins client: pipelined enliven-and-call against pancake.                                  |
| `racket/pancake-break-call.rkt`   | Goblins client: unknown-swiss fetch, asserts pancake's break reason.                         |
| `racket/pancake-export-listen.rkt` | Goblins client: `listen` on a live pancake object export, asserts the fulfill.              |
| `racket/pancake-projection-asker.rkt` | Goblins client: writes canonical `op:get` / `op:index` at pancake's responders. Goblins 0.18.0 has no application-level outbound projection send, so it marshals records Goblins already defines through the live session. |
| `racket/captp-projection-wire.rkt` | The projection records and marshallers `pancake-projection-asker.rkt` writes with.          |
| `racket/handoff-introducer-host.rkt` | Goblins Alice+Bob for recipient-side handoff (`goblins-handoff` / `*-goblins-handoff`).   |
| `racket/gift-exporter-host.rkt`   | Goblins Bob (exporter) for pancake-as-gifter (`*-goblins-gift`).                                  |
| `racket/gift-recipient.rkt`       | Goblins Carol (recipient) that redeems a pancake-minted give (`*-goblins-gift`).             |

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

## Two TCP paths

| Path | Transport symbol | Who dials whom |
| ---- | ---------------- | -------------- |
| Live Goblins interop (`zig build goblins-interop`, handoff, gift, binding clients) | `tcp` (`tcp-netlayer.rkt`, pancake `net.tcp`) | Real Goblins ↔ pancake CapTP over cleartext TCP |
| Upstream OCapN suite target (`seven-caps-peer`, `ocapn-conformance`) | `tcp-testing-only` in printed URLs | Suite harness ↔ pancake or seven-caps peer |

Do not infer that the suite netlayer is the Goblins parity path.

## How Pancake Uses This

- **As an external peer.** Goblins emits OCapN/Syrup bytes pancake must parse
  and answer correctly.
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
