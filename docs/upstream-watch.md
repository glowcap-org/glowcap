# Waiting on upstream

These are open questions in OCapN and Spritely Goblins that glowcap cannot
settle alone, so they are not on [the roadmap](roadmap.md). Each section names
the proposal deciding it, because `glowcap-next` follows current direction as
well as merged text. Every number below was open at the last review.

Where two pinned sources disagree, `zig build ocapn-findings-check` reproduces
the disagreement against the exact upstream revisions this repository pins, and
fails if an observation stops matching its source. The
[findings corpus](../conformance/ocapn-findings/README.md) has the details.

## Session cryptography shape

OCapN PR 288 changes `op:start-session` from four fields to five by adding a
`crypto-version`. It also replaces the structured gcrypt public-key and
signature records with 32-byte Ed25519 public keys and 64-byte signatures.
That is a wire-breaking session change.

The merged text currently names the required version as `Ed25519_SHA256` when
describing the sender and `Ed25519` when describing the receiver. Keep the
specification pin at `d05fd192be530b448e6d80c14714b9ff16644c4e` until that
contract is consistent and glowcap can move its session codecs, fixtures, live
Goblins checks, and both profiles together.

As of September 13, 2026, the Racket and Guile Goblins issues for this change
are open and unassigned, with no public implementation. Racket Goblins `master`
and the pinned OCapN suite still use the four-field record.

The [transition plan](planning/ocapn-crypto-version-handshake.md) lists what
must be ready upstream and the steps after that.

## OCapN Null

Goblins does not marshal Null and the upstream encoding is unsettled, so
glowcap keeps unknown Syrup records as tagged values. Converging would mean a
model arm, codec round trips, and a live Goblins check.

## Live `op:untag`

glowcap accepts the operation from every 1.0 peer and sends it only after the
partner advertises the `untag` feature. Goblins has no live marshaller for it,
so no outside implementation exercises it yet.

## Promise-listening proposal

The settled draft shows two operands, while Goblins and the upstream test suite
use a third Boolean, `wants_partial`. OCapN PR 282 instead proposes integer
listen modes, removes the inline resolver from next-profile delivers, and makes
shortening listens mandatory. V1.0 follows Goblins. `glowcap-next` follows the
proposal while it is under review. The reviewed proposal revision is
`9ee6bb20e25fdd358b2c408fe76d38e4dd151d34`.

## Locator hints type

The draft describes hints as a mapping. The pinned Goblins constructor contract
accepts only false or a string. The wire unmarshaller builds nodes through the
raw constructor, so a mapping-shaped hints field does decode in practice.
`zig build goblins-gift-hints` observes this live and keeps it pinned with
opaque route metadata. No glowcap authentication mechanism depends on the
extension point.

## Handoff withdrawal lookup

Goblins resolves a give's session by the full node value including hints, while
its own node equality ignores hints. glowcap embeds the peer-owned
acceptable-location claim verbatim. That selected route may differ from the
transport carrying the session. Onion uses the stable hint-less locator. An
iroh direct-address refresh applies to subsequent sessions and gifts. This is
pinned interop behavior, not a glowcap architecture boundary.

## Handoff count across independent receiver sessions

Goblins records an accepted `handoff-count` on the Gifter-Exporter session.
The count belongs to the Receiver-Exporter session named by the receive
certificate. So two independent receivers that each start at zero collide on
their shared Gifter-Exporter session, and Goblins rejects the second valid
certificate. The same happens when one receiver reconnects with a fresh
counter.

glowcap's V1 redeem path issues from one counter for the Node's lifetime, so
its own replacement sessions never move backward
(`zig build goblins-rooms-dm-iroh`). Independent receivers cannot coordinate a
counter the protocol assigns to separate sessions.
`zig build goblins-rooms-matrix-iroh` reproduces the rejection, and
`conformance/ocapn-findings/` holds the source evidence.

## Promise settlement

Goblins CapTP 1.0 uses resolver-callback fulfill and break. OCapN PR 282 also
uses resolver callbacks, but obtains them through a following `op:listen`.
`glowcap-next` follows that proposal and sends no wire `op:resolve`. Revisit the
next profile when the proposal changes or settles.

## Message ordering

OCapN PR 281 would write down an end-to-end reference FIFO order: messages one
peer sends to a particular object or promise arrive in the order they were sent,
and that order survives promise shortening. glowcap's local invariant matches
that shape: every shortening edge names an import on the same session, so a
retargeted deliver leaves on the same wire its predecessors left on. A test in
`test/engine/peer/shortening_test.zig` pins the retargeting and same-wire
emission.

The receiver's half has no live outside evidence. Automatic shortening runs
only under `glowcap-next`, the Goblins checks use CapTP 1.0, and two glowcap
peers cannot test it either, because glowcap mints no free-standing promise for
a partner to listen on. Watch the proposal for a requirement that reaches
across sessions, which this session-local design cannot express.

## Goblins Error interop

The pinned OCapN Model defines Error as Passable data. OCapN PR 248 and issue
142 track its still-open invariants. glowcap carries that value through the
neutral model, both codecs, the owning Host, the C ABI, and every binding. A
broken promise remains a different result shape. The pinned Goblins
unmarshaller refuses an `<error>` record, so glowcap's Goblins-compatible
resolver callback keeps its established bare-Symbol break reason. Watch for a
shared live-peer form before changing that profile.

## Sets, keywords, and one concrete encoding

The draft model lists neither Set nor Keyword. Goblins marshals both, so glowcap
follows the Goblins wire, including canonical set order and duplicate refusal.
Issue 283 asks whether the model should carry maps and sets, and issue 275 asks
the wider question of a single concrete encoding. Either could move glowcap's
Syrup surface, and neither is settled.

## Sturdyrefs and tagged values in the model

PR 227 would add sturdy references to the model document, and PR 247 proposes a
Syrup representation for Tagged. glowcap ships both today, following Goblins.
What to watch for is a chosen representation that differs from the one on the
wire now.

## Deposit-gift descriptor direction

The CapTP text's `deposit-gift` example shows the gifted reference as a
`desc:import-object`. PR 244 reports that it should be a `desc:export`, because
the gifter is naming an object the exporter itself exported. glowcap sends the
exported form, the one the live Goblins gift checks redeem, and accepts
either shape on receive.

## Goblins over iroh

Goblins ships the standardized onion netlayer, but not an iroh netlayer.
`conformance/goblins-peer/racket/iroh-netlayer.rkt` is the repository-owned
iroh adapter, and `zig build goblins-iroh` holds a live session over it in both
directions. Watch upstream for an iroh netlayer: if Spritely ships one, the
locator value and hint names are what have to agree.

## Native Zig QUIC

glowcap uses iroh and does not implement QUIC. The decision reopens when
iroh's protocols stabilize and a production Zig QUIC stack exists
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).

## An encrypted identity layer

OCapN issue 208 proposes a Noise-based identity layer that would run inside any
byte transport, and an NLnet grant funds a standardized end-to-end encrypted
relay netlayer at Spritely. Neither has spec text yet. glowcap's own sealed
channel is [ADR-0107](decisions/adr/ADR-0107-sealed-byte-channel.md)
(`Noise_XK` under two glowcap-only symbols, `noise-tcp` and `noise-relay`).
If upstream lands a Noise netlayer, the handshake pattern, prologue, and
locator shape are what have to agree before the symbols can converge.

The `id` locator from
[ADR-0125](decisions/adr/ADR-0125-identity-route-multihome.md) is glowcap's
own, gated behind the negotiated `multi_location` feature, and the
[multi-home routes diagrams](protocol-diagrams/08-multihome-routes.md) describe
it. Carrier wrapping, route-key binding, and the hint schema are what must be
reconciled with future spec text.
