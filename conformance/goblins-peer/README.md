# conformance/goblins-peer

A slim Spritely Goblins OCapN peer. glowcap uses it as a real Goblins peer for
wire-shape lookup, local demos, and the upstream OCapN test suite target.

The Goblins source lives in the `../spritely-goblins/upstream/` submodule. This
directory holds glowcap's wrappers and small Racket programs around its API.

## Files

### Shared

| File                      | Role                                               |
| ------------------------- | -------------------------------------------------- |
| `racket/tcp-netlayer.rkt` | Testing TCP netlayer for loopback OCapN runs.      |
| `racket/iroh-netlayer.rkt` | iroh netlayer: the same vats over encrypted QUIC, through the glowcap Racket binding's byte-channel surface. |
| `racket/session-trace.rkt` | The CapTP session facts a netlayer sees at the wire, reported to a trace sink. Shared by both netlayers. |
| `racket/captp-message-procs.rkt` | CapTP message framing over Racket ports, so a transport close reads as end of stream and not as a Syrup decode error. |
| `racket/ocapn-names.rkt`  | The Public Identifier and Session ID both ends of a session derive alike. |
| `racket/trace-publish.rkt` | Publishes a vat's own sessions to a live timeline endpoint.        |
| `racket/smoke.sh`         | Boots `seven-caps-peer.rkt`, checks its printed URL and TCP port, and stops it. |
| `run.sh`                  | Launcher using the devcontainer's `racket`. |

### Demos and suite target

| File                         | Role                                                                      |
| ---------------------------- | ------------------------------------------------------------------------- |
| `racket/captp-demo.rkt`      | In-process CapTP demo over Goblins fake-intarwebs.                        |
| `racket/tcp-demo.rkt`        | Two Goblins peers over local TCP. Exits after one roundtrip.              |
| `racket/three-vat-demo.rkt`  | Three-party introduction over local TCP.                                  |
| `racket/seven-caps-peer.rkt` | Long-running peer registering the seven caps expected by the OCapN suite. |

### Live Goblins interop (`zig build goblins-interop` and siblings)

| File                              | Role                                                                                         |
| --------------------------------- | -------------------------------------------------------------------------------------------- |
| `racket/goblins-host.rkt`         | Echo, Struct, tally, and await host glowcap dials as client (NDJSON readiness). `await` replies with its promise argument's eventual value, which proves Goblins lifts a promise glowcap passes. |
| `racket/goblins-iroh-host.rkt`    | The same echo host over iroh: a vat reachable at an `iroh` locator, announcing its endpoint id and direct addresses (`goblins-iroh`). |
| `racket/glowcap-iroh-caller.rkt`  | Goblins client over iroh: dials a glowcap peer by endpoint id, calls its actor, and prints what its netlayer proved about the partner (`goblins-iroh`). |
| `racket/goblins-onion-host.rkt`   | The same echo host over upstream Goblins' own onion netlayer, reachable at a Tor onion address (`goblins-onion`). |
| `racket/glowcap-onion-caller.rkt` | Goblins client over the onion netlayer: calls a glowcap actor across a hidden service circuit (`goblins-onion`). |
| `racket/gc-echo-host.rkt`         | Echo host with a background collect loop, so `op:gc-exports` fires within `goblins-gc`'s deadline. |
| `racket/gc-probe.rkt` | Shared Goblins object factory for Zig and all four binding clients. A weak reference observes reclamation after both capability occurrences and their answer are released, with the client session still open. |
| `racket/glowcap-actor-call.rkt`   | Goblins client: settle-call a glowcap-hosted actor.                                          |
| `racket/goblins-tap-dialer.rkt`   | Goblins client: pipelined enliven-and-call against glowcap.                                  |
| `racket/glowcap-break-call.rkt`   | Goblins client: unknown-swiss fetch, asserts glowcap's break reason.                         |
| `racket/glowcap-export-listen.rkt` | Goblins client: `listen` on a live glowcap object export, asserts the fulfill.              |
| `racket/glowcap-projection-asker.rkt` | Goblins client: writes canonical `op:get` / `op:index` at glowcap's responders, sends `op:listen` for each projected answer, and observes glowcap's resolver-callback fulfillments. Goblins 0.18.0 has no application-level outbound projection send, so it marshals records Goblins already defines through the live session. |
| `racket/glowcap-answer-argument.rkt` | Goblins client: names its own pending `make` question with `desc:answer` in argument position of a `read` deliver it writes through its netlayer, and observes glowcap answer `read` with the value `make` settled to. |
| `racket/captp-interop-wire.rkt`   | The CapTP records, marshallers, and record readers the asker and the answer-argument dialer share. |
| `racket/handoff-introducer-host.rkt` | Goblins Alice+Bob for recipient-side handoff over TCP and iroh (`goblins-handoff`, `goblins-handoff-iroh`, and binding checks).   |
| `racket/gift-exporter-host.rkt`   | Goblins Bob (exporter) for glowcap-as-gifter (`*-goblins-gift`).                                  |
| `racket/gift-recipient.rkt`       | Goblins Carol (recipient) that redeems a glowcap-minted give (`*-goblins-gift`).             |
| `racket/exporter-gifter-host.rkt` | Goblins Alice (gifter) over a greeter glowcap exports, so a Goblins pair deposits into and withdraws from glowcap's gift registry (`goblins-exporter`). |
| `racket/deferred-exporter-host.rkt` | Goblins Bob (exporter) holding a promise he has not settled. He hands it to glowcap as a delivered argument, then either settles from stdin for `goblins-relayed-give` or settles a nested-capability value after glowcap's ordered `listenTo` in `goblins-listen-recipient`. |
| `racket/relayed-give-recipient.rkt` | Goblins Carol (recipient), who waits on a promise glowcap introduced her to and reads the give out of the listener fire (`goblins-relayed-give`). |
| `racket/rooms-client.rkt`         | The rooms wire protocol in Goblins terms (dial, reach the directory, enter or open a room, spawn the inbox the room calls back), shared by the three rooms members below. |
| `racket/rooms-dm.rkt`             | The direct-message half of that protocol: claim a name, mint one inbox per peer and offer it to the room, receive a message off-room and answer over the connection it arrived on. |
| `racket/rooms-member.rkt`         | Goblins vat joining the rooms chat as an ordinary member, scripted: it enters a room, subscribes, posts one line, waits to hear what it came for, and exits (`goblins-rooms`). |
| `racket/rooms-dm-member.rkt`      | Goblins vat sitting in the room and reachable by direct message, scripted: it narrates each message it receives and answers it, starts a direct message of its own with `--dm`, and stays up until killed (`goblins-rooms-dm`). |
| `racket/rooms-chat.rkt`           | The same member, interactive: a terminal you talk in as a real Goblins vat, with `/list`, `/open`, `/enter`, `/leave`, `/dms`, and `/dm`. Run it beside `zig build rooms-web -Dtransport=tcp`, the cleartext transport the vat speaks, to chat with browser members, in the room and privately. |

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

## The transports these vats speak

Goblins ships the standardized onion netlayer. This directory supplies the TCP
testing and iroh netlayers.

| Path | Transport symbol | Who dials whom |
| ---- | ---------------- | -------------- |
| Live Goblins interop (`zig build goblins-interop`, handoff, gift, both foreign-promise directions, binding clients) | `tcp` (`tcp-netlayer.rkt`, glowcap `net.tcp`) | Real Goblins ↔ glowcap CapTP over cleartext TCP |
| Live Goblins over QUIC (`zig build goblins-iroh`) | `iroh` (`iroh-netlayer.rkt`, glowcap `net.transport.iroh`) | Real Goblins ↔ glowcap CapTP over encrypted QUIC, both directions |
| Live Goblins over Tor (`zig build goblins-onion`) | `onion` (upstream Goblins netlayer, glowcap `net.onion`) | Real Goblins ↔ glowcap CapTP over onion circuits, both directions |
| Upstream OCapN suite target (`seven-caps-peer`, `ocapn-conformance`) | `tcp-testing-only` in printed URLs | Suite harness ↔ glowcap or seven-caps peer |

`tcp-testing-only` serves the suite only, not Goblins parity.

## How glowcap uses this

- **External peer.** Goblins emits OCapN/Syrup bytes that glowcap must parse and
  answer.
- **Suite target.** `seven-caps-peer.rkt` supplies the capabilities the upstream
  Python suite expects.
- **Wire-shape lookup.** When the Zig implementation needs evidence for a
  Goblins shape, this peer produces it on the wire.

## Posture

- The demos are glowcap's own and are editable.
- `seven-caps-peer.rkt` stays compatible with the capabilities the upstream
  suite expects.
- The testing TCP netlayer is cleartext loopback. The iroh netlayer is encrypted
  and names its peer by key, but it is interop scaffolding, not a Spritely
  product, with no graceful shutdown and no reconnect.
