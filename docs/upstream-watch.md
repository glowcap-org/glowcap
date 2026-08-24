# Waiting on upstream

These are open questions in OCapN and Spritely Goblins. pancake cannot settle
any of them alone, so they are not on [the roadmap](roadmap.md). A few already
have an answer pancake meets; those say so, and say what holds it.

Each section names the proposal that owns the question, because `pancake-next`
follows current direction rather than only merged text. Every number below was
open at the last review of this page.

Where two pinned sources disagree, `zig build ocapn-findings-check` reproduces
the disagreement against the exact upstream revisions this repository pins, and
fails if an observation stops matching its source. The
[findings corpus](../conformance/ocapn-findings/README.md) has the details.

## OCapN Null

Goblins does not marshal Null and the upstream encoding is unsettled, so
pancake keeps unknown Syrup records as tagged values. Converging would mean a
model arm, codec round trips, and a live Goblins check.

## Live `op:untag`

The 1.0 responder, initiator, fixtures, C Host, and bindings ship. Pancake
accepts the operation from every 1.0 peer and sends it only after the partner
advertises the `untag` feature. Goblins has no live marshaller for the
operation, so there is no outside implementation path to exercise yet.

## Promise-listening proposal

The settled draft shows two operands, while Goblins and the upstream test suite
use a third Boolean, `wants_partial`. OCapN PR 282 instead proposes integer
listen modes, removes the inline resolver from next-profile delivers, and makes
shortening listens mandatory. V1.0 follows Goblins. `pancake-next` follows the
proposal while it is under review. The reviewed proposal revision is
`9ee6bb20e25fdd358b2c408fe76d38e4dd151d34`.

## Locator hints type

The draft describes hints as a mapping; the pinned Goblins constructor contract
accepts only false or a string. The wire unmarshaller builds nodes through the
raw constructor, so a mapping-shaped hints field does decode in practice, which
`zig build goblins-gift-hints` observes live.

`zig build goblins-gift-hints` keeps this pinned with opaque route metadata; no
pancake authentication mechanism depends on the extension point.

## Handoff withdrawal lookup

Goblins resolves a give's session by the full node value including hints, while
its own node equality deliberately ignores hints. pancake embeds the peer-owned
acceptable-location claim verbatim. That selected route may differ from the
transport carrying the session. Onion uses the stable hint-less locator; an
iroh direct-address refresh applies to subsequent sessions and gifts. This is
pinned interop behavior, not a pancake architecture boundary.

## Handoff count across independent receiver sessions

Goblins records an accepted `handoff-count` on the Gifter-Exporter session.
The count belongs to the Receiver-Exporter session named by the receive
certificate. Two independent receivers may therefore each use zero on their
first session, but Goblins compares the second receiver's value with the first
receiver's count retained on their shared Gifter-Exporter session and rejects
the valid certificate. The same mismatch appears when one receiver closes and
reconnects with a fresh session-local counter.

pancake's automatic V1 redeem path issues from one Node-lifetime monotonic
cursor, which keeps replacement sessions from moving backward against Goblins.
`zig build goblins-rooms-dm-iroh` closes the first browser DM, opens a distinct
replacement, and requires its first message and reply to cross the live Goblins
session. Accepted replay state and all next-profile issuance remain scoped to
the Receiver-Exporter session. Independent receivers cannot coordinate a
counter the protocol assigns to separate sessions. The pinned source evidence
lives in `conformance/ocapn-findings/`; `zig build goblins-rooms-matrix-iroh`
reproduces the live rejection before running its clean four-peer matrix.

## Promise settlement

Goblins CapTP 1.0 uses resolver-callback fulfill and break. OCapN PR 282 also
uses resolver callbacks, but obtains them through a following `op:listen`.
`pancake-next` follows that proposal and sends no wire `op:resolve`. Revisit the
next profile when the proposal changes or settles.

## Message ordering

OCapN PR 281 would write down an end-to-end reference FIFO order: messages one
peer sends to a particular object or promise arrive in the order they were sent,
and that order survives promise shortening. pancake's local invariant matches
that shape: every shortening edge names an import on the same session, so a
retargeted deliver leaves on the same wire its predecessors left on. A test in
`test/engine/peer/shortening_test.zig` pins the retargeting and same-wire emission.

The receiver's half of that claim has no in-tree scenario, and it cannot get one
between two pancake peers. Shortening starts from a promise this peer imported,
and `src/ocapn/engine/pipeline.zig` refuses a listen on a bare promise export,
because pancake mints no free-standing resolvable promise for a partner to
listen on. The peer that shortens is therefore always some other implementation,
so watching the arrival order is an interop question for a live Goblins vat
rather than a scenario the oracle can drive. Watch the proposal, too, for a
requirement that reaches across sessions, which this session-local forest cannot
express.

## Goblins Error interop

The pinned OCapN Model defines Error as Passable data. OCapN PR 248 and issue
142 track its still-open invariants. pancake carries that value through the
neutral model, both codecs, the owning Host, the C ABI, and every binding; a
broken promise remains a different result shape. The pinned Goblins
unmarshaller refuses an `<error>` record, so pancake's Goblins-compatible
resolver callback keeps its established bare-Symbol break reason. Watch for a
shared live-peer form before changing that profile.

## Sets, keywords, and one concrete encoding

The draft model lists neither Set nor Keyword. Goblins marshals both, so pancake
follows the Goblins wire, including canonical set order and duplicate refusal.
Issue 283 asks whether the model should carry maps and sets, and issue 275 asks
the wider question of a single concrete encoding. Either could move pancake's
Syrup surface, and neither is settled.

## Sturdyrefs and tagged values in the model

PR 227 would add sturdy references to the model document, and PR 247 proposes a
Syrup representation for Tagged. pancake ships both today, following Goblins.
What to watch for is a chosen representation that differs from the one on the
wire now.

## Deposit-gift descriptor direction

The CapTP text's `deposit-gift` example shows the gifted reference as a
`desc:import-object`. PR 244 reports that it should be a `desc:export`, because
the gifter is naming an object the exporter itself exported. pancake sends the
exported form, which is what the live Goblins gift checks redeem, and accepts
either shape on receive.

## Goblins over iroh

Goblins ships the standardized onion netlayer, but not an iroh netlayer.
`conformance/goblins-peer/racket/iroh-netlayer.rkt` is the repository-owned
iroh adapter, and `zig build goblins-iroh` holds a live session over it in both
directions. Watch upstream for an iroh netlayer: if Spritely ships one, the
locator value and hint names are what have to agree.

## Native Zig QUIC

pancake uses iroh rather than implementing QUIC. The decision reopens when
iroh's protocols stabilize and a production Zig QUIC stack exists
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).

## An encrypted identity layer

OCapN issue 208 proposes a Noise-based identity layer that would run inside any
byte transport, and an NLnet grant funds a standardized end-to-end encrypted
relay netlayer at Spritely. Neither has spec text yet. pancake's own sealed
channel is [ADR-0107](decisions/adr/ADR-0107-sealed-byte-channel.md)
(`Noise_XK` under two pancake-only symbols, `noise-tcp` and `noise-relay`);
if upstream lands a Noise netlayer, the handshake pattern, prologue, and
locator shape are what have to agree before the symbols can converge.

ADR-0125's identity-route implementation is present but not an upstream claim.
The model recognizes `id` and its `via` hint behind the negotiated
`multi_location` feature. Handoff redeem parses `id` and `alt-locators` through
the same route-bundle owner. Paths under `via` must prove the durable
key the outer `id` designator names; optional `alt-locators` are weak handoff
fallbacks that neither establish that identity nor become sturdyref dial
paths. Declared `via` order ranks a bounded two-attempt strong-route race;
`alt-locators` remain ordered and serial after every strong route fails, with no
transport-name weighting presented as upstream behavior. Session validation
keeps route vocabulary out of a first hello until the remote side has offered
`pancake-next` with the feature bit, and
settled-session payloads require the negotiated bit. Host-level `id` sturdyrefs
use the same opted-in feature gate and
resolve through the Node pending-dial waist rather than through a physical
`id` transport. Arbitrary carrier wrapping, route-key binding, and final hint
schema remain the private extension surface to reconcile with future spec text.
