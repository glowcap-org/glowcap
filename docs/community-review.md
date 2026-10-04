# Community review

This is the review brief for OCapN and Spritely Goblins maintainers. It states
the interop target, the evidence that runs, and the known differences from the
draft text or a live peer.

glowcap pins the OCapN suite and Goblins source and checks both through
[`ci/gates.sh`](../ci/gates.sh) on main and dev pushes. Pull requests run the
Zig test suite and formatting check in a short lane. glowcap has not asked to
be listed as an OCapN implementation. Because the work is AI-assisted, it
sends no unsolicited patches, issues, or comments to projects whose policies
forbid them. The policy is in
[`PROVENANCE.md`](../PROVENANCE.md).

## Vocabulary map

| Goblins / CapTP / OCapN | glowcap |
| --- | --- |
| `mycapn` | Two roles: the product is a `Host`; the I/O-free handoff router is `engine.Node`. Goblins combines those jobs in one type; glowcap keeps them apart. |
| CapTP session with one partner | Application-facing `Session`; the Host ABI's registered shell is `GlowcapHostSession`. A byte stream is a `Connection` / transport `*Conn`, never the CapTP partner. |
| Goblins vow / OCapN promise / answer position | A Goblins vow is a passable eventual reference. glowcap's `Vow` is a local host/actor observation and send-result handle over an OCapN promise. `desc:answer` names the sender-chosen session slot used for pipelining. These are related projections, not one type. |
| CapTP value-level sealer / unsealer | Not implemented as a glowcap type. The unrelated `SealedChannel` is glowcap's Noise-encrypted transport byte channel (ADR-0107). |

Two findings may be useful upstream: the draft, suite, and Goblins disagree on
the operand count for `op:listen`, and the draft's mapping-shaped locator hints
do not match the pinned Goblins string-or-false constructor contract. The
records in
[`conformance/ocapn-findings/`](../conformance/ocapn-findings/README.md) are
enough for a maintainer to reproduce the disagreement without a glowcap
checkout.

## Interop Target

The Goblins-facing path is signed CapTP 1.0 over Syrup. Recurring live
checks, the C ABI, `driver.connect`, and the upstream suite use cleartext
TCP: glowcap's testing adapter. Goblins ships onion
(and an in-process `fake`). `zig build goblins-onion` is the meeting on
that netlayer, both directions; it needs Tor and is on demand.

TCP itself authenticates no durable peer identity. The fresh session key signs
the hello, so glowcap can verify session continuity and signed handoff
payloads. Durable provenance comes only from an authenticated channel realizer
such as iroh, WebRTC signaling, or an embedder-supplied channel binding.

The glowcap-native profile is a separate job. Native peers can negotiate
`"glowcap-next"` with Cap'n Proto, and iroh supplies encrypted reachability.
Neither is offered as Goblins compatibility. The only outside CapTP
implementations exercised today are the upstream suite and Racket Goblins.

ADR-0125's `id/via` multi-home shape is a glowcap-private extension. It is not
understood by any external OCapN or Goblins implementation exercised by this
repository. The existing OCapN and
Goblins checks prove the baseline remains compatible;
`goblins-rooms-peering` proves the Rooms product lowers its private source
route into a baseline handoff a real Goblins vat can redeem. None proves
interoperability with an external route-bundle implementation, because the vat
correctly never receives that private vocabulary.

## Known gaps

- **Handoff coverage is split across transports.** These are separate outside
  checks, not one general proof for every transport other than TCP:
  - Over TCP, live Goblins covers glowcap in all three handoff roles: gifter,
    recipient, and exporter. The exporter check proves exact-object identity.
    The Goblins gifter primes the glowcap-hosted actor, glowcap replaces the
    alias with a decoy, and the Goblins recipient's withdrawn call must reach
    the primed original.
  - `goblins-rooms-dm-iroh` puts all three roles in one live iroh topology:
    the glowcap room gifts, a Goblins vat exports, and a browser redeems. The
    vat also acts as recipient when it starts a direct message to a native
    glowcap exporter.
  - `goblins-handoff-iroh` makes Goblins the gifter and exporter, with glowcap
    redeeming on a separate QUIC-authenticated session after the exporter
    changes its advertised `direct-addresses`. It changes the routing advice
    but keeps the original address reachable, so it proves session snapshot
    handling, not network migration.
  - On demand, `ocapn-conformance-onion` runs the upstream suite against
    glowcap in all three handoff roles over onion.
- **Goblins indexes an exporter session by the complete locator.** glowcap
  embeds the peer-owned advertised snapshot rather than reconstructing it at
  the handoff site. This is stable for Goblins Onion, whose locator is
  `(onion, service-id, #f)`. An iroh endpoint without reachability can update
  `direct-addresses`; the replacement snapshot applies to subsequent sessions
  and gifts. Goblins' full-value lookup remains worth an upstream report, but
  it is not a glowcap architecture boundary.
- Every CapTP session uses a fresh signing key, so a durable identity can only
  come from an authenticated channel. iroh supplies its QUIC endpoint id,
  `noise-tcp` and `noise-relay` prove the dialed key in their Noise handshake
  (ADR-0107), and WebRTC supplies the identity its signaling authorized. Raw
  keyed TCP and keyed relay report `unauthenticated`; matching the dialed key
  there only checks the target, and proves nothing.
- **Pinned Goblins can reject a valid receive certificate from an independent
  receiver.** It retains `handoff-count` on the Gifter-Exporter session even
  though the signed count belongs to the Receiver-Exporter session. Two
  independent receivers may therefore each correctly begin at zero while the
  latter is rejected. Glowcap's V1 Node-lifetime issuance cursor prevents one
  Node from moving backward across replacement sessions, but independent
  recipients cannot coordinate a counter the protocol assigns to separate
  sessions. `goblins-rooms-matrix-iroh` reproduces the rejection before its
  clean matrix; [upstream watch](upstream-watch.md#handoff-count-across-independent-receiver-sessions)
  owns the source analysis.
- Relaying a foreign promise is live in both directions. In
  `goblins-relayed-give`, glowcap gifts the Goblins-owned promise to a Goblins
  recipient. In `goblins-listen-recipient`, the owning native Session receives
  that promise, installs `listenTo` before Goblins settles it, recursively
  lifts the nested greeter, and calls it.
- Goblins can put canonical `op:get` and `op:index` frames on glowcap's wire.
  The Goblins-side netlayer probe observes glowcap's resolver-callback
  fulfillments for both projected answers. Goblins still has no public
  application-level API for sending those projection requests directly.
- A live Goblins vat accepts glowcap's one-way `tell` form. The check sends
  two answerless `op:deliver` frames and reads the changed state back through
  an answered call.
- OCapN Null waits on an upstream representation decision. `op:untag` ships on
  1.0 and `glowcap-next`; inbound support is unconditional, while a signed
  feature offer prevents Glowcap from sending it to a silent Goblins peer.
  Only a live external-peer exercise waits on upstream support.

[Known limitations](boundaries.md) explains the effect on users. Open OCapN
and Goblins questions live in [upstream-watch](upstream-watch.md). The
[roadmap](roadmap.md) lists glowcap-owned remaining work.

## Evidence

A **yes** in the CI column means the step appears in `ci/gates.sh` and runs in
the full lane after a push to main or dev. Pull requests run `zig build test`
and `zig build fmt-check` instead. `zig build source-check` derives this column
from the script, so a removed step cannot remain marked as recurring evidence.

| Evidence | CI | Proves | Does not prove |
| -------- | -- | ------ | -------------- |
| `zig build check` (includes `oracle-check`) | yes | In-tree protocol scenarios, message-arm coverage, committed Syrup fixtures, Cap'n Proto goldens, resource budgets, and a complete six-peer handoff scenario. | A live outside peer or a fresh upstream Syrup run. |
| `zig build ocapn-conformance` | yes | The upstream modules against the production Host/Node wire and authority paths, composed with canonical conformance actors and three suite-only interceptors that drive those library seams; plus handshake refusal and a portable pre-setup abort check. | An application with no conformance interceptors, future suite netlayers, or transport recovery after abort; the raw upstream `tests.op_abort` rejects Linux TCP reset. |
| `zig build ocapn-findings-check` | yes | The pinned sources still disagree on `op:listen` arity and locator-hints typing. | Which form upstream should choose. |
| `zig build goblins-interop` | yes | A live Goblins session in both directions over Syrup/TCP. Covers handshake, bootstrap, calls, promise settlement, bignums, enlivenment, pipelining, answerless delivers, actor calls, and Goblins-written `op:get` / `op:index` requests that settle through resolver-callback fulfillments. | A public Goblins application API for outbound projections, live `op:untag`, onion, or iroh. |
| `zig build goblins-rooms` | yes | A real Goblins vat and a glowcap member exchange room traffic while the same server records the Goblins session on Syrup/v1.0 and the glowcap session on Cap'n Proto/next. | Direct messages, browser behavior, or a secure transport; those have separate on-demand rows. |
| `zig build goblins-rooms-peering` | no | A real Goblins vat enters a foreign room through a glowcap directory publication over Syrup/v1.0, continues using the handed room after its publication is revoked, and lets the source reclaim and reuse the public name. | Recurring CI, browser behavior, a secure transport, or revocation of authority already handed to a member. |
| `zig build goblins-rooms-irc` | yes | Both shipped IRC application edges compose with a real Goblins vat. Fixture IRC traffic crosses the bridge both ways. Through the front, an ordinary IRC client and Goblins exchange native room lines; IRC then initiates a direct message, and Goblins replies on its arriving v1.0/Syrup TCP session. | A public IRC network, browser behavior, or the front's iroh deployment posture. The fixture is local and deterministic. |
| `zig build goblins-onion` | no | Live Goblins sessions both ways over the Goblins onion netlayer and glowcap's Tor resident. | Recurring CI (needs `tor` and outbound network), live scale, or hinted-onion sturdyrefs. |
| `zig build ocapn-conformance-onion` | no | Every portable upstream module against glowcap over the upstream Onion netlayer, including glowcap in all three handoff roles. | Goblins application behavior, recurring CI, live scale, or the reset-sensitive raw `tests.op_abort`. |
| `zig build goblins-iroh` | no | Live Goblins sessions both ways over the iroh netlayer this repository wrote for Goblins. | Recurring CI (needs cargo + racket), hole-punching, or non-TCP handoff roles beyond the on-demand rooms row below. |
| `zig build goblins-handoff` | yes | glowcap redeems a Goblins give. | glowcap as gifter or exporter. |
| `zig build goblins-gift` | yes | glowcap mints a give that Goblins redeems. | glowcap as recipient or exporter. |
| `zig build goblins-gift-hints` | yes | A hinted locator survives decode, re-encode, signature verification, and live Goblins redemption. | General route discovery or non-TCP handoff. |
| `zig build goblins-exporter` | yes | A Goblins pair deposits into and withdraws from glowcap's gift registry, and the withdrawn object is the exact actor the gifter mutated, across an alias replacement. | Alias removal mid-flight, or handoff over a non-TCP transport. |
| `zig build goblins-relayed-give` | yes | A Goblins recipient reads a signed give from a listener notification, dials the exporter, and calls the withdrawn capability. | glowcap receiving that live introduction through `listenTo`. |
| `zig build goblins-listen-recipient` | yes | Goblins delivers an unresolved promise to the owning native Session; one `listenTo` is ordered before one later Goblins settlement, whose nested capability glowcap lifts, calls, releases, and closes cleanly. | A three-party give in that fulfillment; `goblins-relayed-give` covers the reciprocal gifter topology. |
| `zig build goblins-gc` | yes | Live inbound `op:gc-exports` after Goblins drops a near export. In the reciprocal check, a Goblins weak reference proves that release of both capability occurrences and their answer permits collection while the owning Zig Session stays open; the first release leaves the second occurrence callable. | Automatic capability finalizers in host languages. |
| `zig build goblins-handoff-iroh` | yes | Goblins gifts and exports; glowcap redeems on a separate QUIC-authenticated exporter session after its advertised direct-address advice changes. | The original bound address stays reachable. This is a locator-snapshot proof, not NAT or endpoint migration. |
| `zig build goblins-rooms-dm` / `-iroh` | no | Three peers across two implementations take the three handoff roles: a glowcap room gifts, a real Goblins vat exports, and a glowcap browser peer redeems and reaches the vat off-room, over cleartext TCP and over iroh. The vat answers on the arriving connection, then acts as recipient when it starts a direct message to a native glowcap exporter over the same selected transport. | Recurring evidence: this heavyweight browser/Goblins topology is absent from `ci/gates.sh` and remains on demand. The smaller recurring `goblins-handoff-iroh` check covers Goblins as gifter and an advertised-address update. |
| Binding `*-goblins-interop` steps | yes | Deno, Python, Rust, and Racket dial Goblins, enliven a sturdyref, and call it. Each also releases two occurrences of a Goblins object, proves the retained occurrence survives, and observes remote collection after capability release and answer-wrapper finalization, before session close. | Bun, automatic capability finalizers, or the reciprocal listener direction, which the sibling listener matrix owns. | <!-- ci-gate: bindings-goblins-interop -->
| Binding `*-goblins-listen` steps | yes | Goblins dials Deno, Python, Rust, and Racket binding Hosts, enlivens one published actor, calls it, and reads its exact reply. | Bun, whose synchronous FFI cannot host the native loop. | <!-- ci-gate: bindings-goblins-listen -->
| Binding `*-goblins-handoff` / `*-goblins-gift` | yes | Deno, Python, Rust, and Racket act as recipient and gifter against Goblins; each gifter lifts a delegated capability from an ordinary vendor reply, returns it twice in one nested value, and Goblins redeems and calls both gives directly. | Bun or live recursive Tagged/user-record interop, which pinned Goblins does not implement. | <!-- ci-gate: bindings-goblins-handoff, bindings-goblins-gift -->
| Introducing-session promise proxy | yes | In-tree Node and Host coverage projects complete nested object/promise settlements through Host identity under both codecs, with independent recipient pressure and one signed give per object occurrence. The separate live recipient check covers glowcap's `listenTo` path against Goblins. | A second outside implementation beyond Goblins. | <!-- ci-gate: check -->
| `zig build fuzz` | yes | Coverage-guided inputs exercise codecs, framing, sessions, handoff, locators, the host, actors, persistent collections, and completion-loop accounting. Saved crashes replay under `check`. | Agreement with the specification, unreached code, or a well-formed but wrong decode. The recurring search is shallow. |
| `zig build cli-test` / `glowcap` | yes | CLI budgets, hang-proof dial, listen/call behavior, REPL, and MCP. | OCapN suite or Goblins behavior. | <!-- ci-gate: check -->

For a quick manual call over Syrup/TCP, use the [CLI walkthrough](cli.md).

## Divergences and watch items

- **Null.** glowcap has no OCapN Null value. Unknown Syrup records remain
  tagged values until upstream encoding and Goblins marshalling agree.
- **Set and Keyword.** The draft model lists neither. Goblins marshals both,
  so glowcap follows the Goblins wire, including canonical set order and
  duplicate refusal.
- **Projections.** `op:get`, `op:index`, and `op:untag` ship in-tree. The live
  limits are listed above.
- **Cap'n Proto.** It is a glowcap-to-glowcap codec. Handoff values carry the
  same structural locators, but their signatures still use the Syrup domain.
- **Start-session hints.** The suite requires non-empty locator hints to be
  consumed rather than rejected. Both codecs preserve them; Syrup also retains
  the original signed location record.
- **`op:listen`.** V1.0 follows the suite and Goblins Boolean
  `wants_partial` form. Next follows OCapN PR 282's integer modes and mandatory
  shortening subscriptions. A live object export settles immediately; a bare
  unresolved promise export is refused. Third-party promise relay and native
  `listenTo` use the ordinary listen and settlement path.
- **Handshake refusal.** An invalid signature, pinned-key mismatch, or version
  mismatch sends a typed abort and closes the CapTP session, matching the draft
  and Goblins. A corrected hello requires a new session.
- **Settlement.** Goblins CapTP 1.0 uses an inline resolver callback. Next
  receives the same fulfill or break callback through the mandatory listen and
  sends no wire `op:resolve`.
- **Negotiation.** `op:start-session` carries the baseline version string;
  codec, version, and feature preferences travel in its signed locator hints.
  Peers settle those offers after both verified hellos arrive.
- **Suite TCP.** Goblins interop uses the `tcp` transport symbol. The upstream
  suite uses its own `tcp-testing-only` URLs.
- **Target equality.** A remote target reached directly and through handoff
  on the same live exporter session canonicalizes to one Host identity, and
  repeated sturdyref enlivenment on a session deduplicates. Two parallel
  sessions to the same peer are not claimed to converge; ADR-0097's fresh-key
  peer selection owns that.
- **Signature verification.** Production uses `foundation.crypto`. The
  accepting verifier in test support is available only to in-process tests.

## Reproduce

The devcontainer initializes the submodules when it opens. From a checkout
that has not been through that hook:

```sh
bash conformance/bootstrap-submodules.sh
```

Then run:

```sh
zig build check
zig build ocapn-conformance
zig build ocapn-findings-check
zig build ocapn-conformance-onion
zig build goblins-interop
zig build bindings-goblins-listen
zig build goblins-handoff
zig build goblins-gift
zig build goblins-gift-hints
zig build goblins-relayed-give
zig build goblins-listen-recipient
zig build goblins-exporter
zig build goblins-gc
```

The live steps need Racket with Goblins; the suite needs `uv`. The devcontainer
provides both. `zig build goblins-onion` is the Goblins-native netlayer meeting;
it needs Tor and is not in that list. Pin changes live in
[`.devcontainer/pins.sh`](../.devcontainer/pins.sh).

Report protocol-invariant breaks privately through
[`SECURITY.md`](../SECURITY.md).
