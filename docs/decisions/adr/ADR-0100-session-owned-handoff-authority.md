---
id: ADR-0100
status: accepted
date: 2026-08-01
tags: [captp, handoff, session, authority, gifts]
decision: "Each CapTP Peer owns its session's deposited gifts, accepted replay counter, and spec-profile emitted counter. Withdrawal resolves the live Gifter–Exporter Peer named by the signed give, verifies with that Peer's session key, consumes from that Peer's gift table, and records replay state on the Receiver–Exporter Peer. Closing a Peer destroys the authority it owns. A Node's automatic V1 redeem path uses a separate host-lifetime emitted-count cursor for Goblins reconnect interoperability; this changes count issuance only and never receive-side validation. Fresh per-session signing keys (ADR-0097) isolate reconnect incarnations on ordinary product Hosts. Node otherwise keeps only authority-neutral handoff routing and scheduler state."
supersedes: [ADR-0056]
superseded_by: []
amends: [ADR-0025, ADR-0066, ADR-0068, ADR-0072, ADR-0083, ADR-0096]
amended_by: [ADR-0113, ADR-0116]
---

# ADR-0100 Session-owned handoff authority

## Status

Accepted and shipped for session-owned storage and replay state. Engine tests
hold session-local gift ids, scalar replay, verify-before-wait, admission OOM
rollback, and re-deposit semantics. Production Host scenarios prove both
closure orders while no replacement session reuses the closed session's names:
a deposited gift dies before a later withdrawal, and an early withdrawal
already parked on another session wakes and breaks when its required
Gifter–Exporter Peer closes.

The scheduler route is also shipped. Pending admission registers one
`(Gifter–Exporter PeerHandle, 128-bit gift digest)` dependency per receiver group
before replay authority advances. A deposit marks only that exact group;
protocol/session close marks each still-live group rooted in the closing
gifter. Both transitions allocate nothing. Each receiver indexes its parked
rows by the same fixed-size key, so a wake retries only that gift's rows rather
than scanning up to `max_pending_withdraws`. The Host has already reserved one
dirty-FIFO slot and one flush plus one close action slot per live shell. A drive
that encounters OOM keeps the exact wake and dirty row for the next action
drain.

Reconnect-incarnation isolation is shipped at every Host surface. `HostRuntime`,
the C Host, and the bindings mint fresh session keys from a rooted entropy
seed, and the reconnect evidence there holds. The C Host refuses a
durable-only 32-byte seed. The sans-I/O `driver_core.Host.init` requires a
separate per-process session root, so omitting entropy or silently reusing the
durable identity is not a representable constructor mode.

The V1 Goblins compatibility case is also shipped. Goblins 0.15 retains the
last accepted count on its Gifter–Exporter coordinator, so it rejects count
zero when a Receiver–Exporter session closes and a fresh one redeems another
introduction. A Node's automatic V1 redeem path now issues monotonically for
the Node lifetime. The spec/next path remains session-local, and accepted
replay state remains session-local in both profiles.

## Context

ADR-0056 correctly deleted duplicate handoff implementations but chose the
wrong surviving owner. It argued that a per-session gift table could not serve a
deposit on Gifter–Exporter followed by withdrawal on Receiver–Exporter, so it
put gifts and replay maps in the Vat and later the Host.

OCapN specifies the opposite composition. A gift is deposited in the table for
the Gifter–Exporter session. At withdrawal, the Exporter uses the signed give's
session name to find that still-open session, its verification key, and its gift
table. The implementation guide states that both Gifter–Exporter and
Receiver–Exporter sessions must still exist; after the gifter aborts, the
Exporter should have neither the gift table nor the relevant key. Goblins uses
that shape: one Vat hosts many sessions, while handoff code resolves the gifter
session before consulting the gift table it owns.

A Host-wide table weakened that rule. Copying the gifter key into a gift row
let a deposited gift survive after the authenticating session closed. It also
made unrelated sessions share replay-map lifetime and required gifter identity
as an extra row-key dimension only because the containing session namespace had
been erased.

## Decision

Every `engine.Peer` owns one `GiftRegistry` for its CapTP session:

- `gifts[gift_id]` contains only deposits made on that session;
- `accepted_handoff_count` is the monotonic replay guard for receives arriving
  on that session;
- `next_emitted_handoff_count` mints counts for standalone and next-profile
  withdrawals emitted on that session.

For automatic V1 redemption, `Node.next_v1_emitted_handoff_count` supplies the
wire value across replacement Receiver–Exporter sessions. This cursor grants no
authority and validates nothing. It only avoids reusing a lower value against
the long-lived coordinator where Goblins 0.15 records its check.

A gift row stores its payload, not a copied gifter key or side. Gift ids need no
gifter dimension because the containing Gifter–Exporter session is their
namespace. Re-depositing one id on that session replaces its live row; another
gifter owns another Peer and cannot collide.

On `withdraw-gift`, the Receiver–Exporter Peer first resolves the signed give's
side and session name through the Host's live-session directory. The result
borrows the Gifter–Exporter Peer's public key and gift registry. The responder
verifies both certificates, validates and records replay against the
Receiver–Exporter registry, and consumes the payload from the Gifter–Exporter
registry only after its settlement is durably queued. An early withdrawal may
park after verification; every retry resolves the gifter session again. If that
Peer closed while it waited and no replacement Peer has reused its names, the
answer breaks instead of consulting stale authority. ADR-0097 must make those
names unique to one connection incarnation before closure alone provides that
guarantee across reconnects.

`Peer.deinit` frees every unconsumed gift and destroys both scalar counters.
`Node` and `Host` own no gift or replay table. `Node` does own
authority-neutral scheduler dependencies keyed by Gifter–Exporter `PeerHandle`
plus a 128-bit BLAKE3 tag of the gift id, then receiver `PeerHandle`. A receiver
owns one pending group for that key; multiple receives for the same gift share
it. The relation stores no partner-sized gift bytes, key, receive, or
capability. The digest is not authority: a collision can only cause an extra
bounded retry because withdrawal still checks the exact signed gift id against
the exact registry key.

Each dependency reserves one changed-list slot at admission. A deposit marks
that exact key; close walks only the live dependency keys rooted in that gifter
and marks each. The Host consumes one change, installs its scalar key on each
affected receiver, and drives those receivers to quiescence before consuming
another change. Each receiver therefore needs no second wake queue and looks
up only the matching pending group. The Host reserves one dirty-FIFO slot per
live shell at mint, so notification after authority mutation allocates nothing;
a drive-side OOM retains the scalar wake and requeues the receiver before it
propagates.

ADR-0116 also gives the Node bounded, in-flight coordination ownership while an
outbound Passable value waits for inline object gifts. That transaction stores
no deposited gift or replay authority. The exporter Peers acquire those facts
only when the complete local transaction commits.

The pending-withdraw cap is checked against the borrowed request before the
handoff is materialized or signatures are canonicalized. Once admitted, the
pending-group allocation and scheduler dependency are reserved before replay
state advances. No fallible operation follows that advance. A propagated OOM
therefore leaves no pending row, accepted count, or orphan dependency.

## Evidence

- [`test/engine/gift_registry_test.zig`](../../../test/engine/gift_registry_test.zig)
  pins session-local id namespaces, scalar accepted/emitted counts,
  re-deposit replacement, and bounded live rows.
- [`test/engine/cross_peer/parked_test.zig`](../../../test/engine/cross_peer/parked_test.zig)
  pins live-session resolution, signature verification, verify-before-wait,
  replay rejection, exact-target projection, admission OOM rollback, and the
  borrowed immediate-withdraw path's allocation count. The admission sweep uses
  an adopted Peer and includes scheduler-dependency allocation.
- [`test/engine/node/`](../../../test/engine/node/) pins exact
  gift dependencies, deposit and protocol-close notification, targeted receiver
  selection, change consumption, failed adopted-peer registration cleanup, and
  scheduler backing release at total quiescence. A 256-row pressure scenario
  in the cross-peer suite proves one gift wake performs one resolver check,
  not a scan of unrelated pending rows. The admission sweep above
  removes an adopted receiver while its real pending row remains, proving that
  receiver teardown removes the dependency rather than merely invoking the
  scheduler callbacks by hand. The suite also decodes automatic withdrawals on
  fresh exporter sessions. V1 requires Node-lifetime counts `0`, then `1`,
  while next requires session-local counts `0`, then `0`.
- [`test/driver/core_host/`](../../../test/driver/core_host/)
  pins the production Host directory, the close-after-deposit failure, and both
  outcomes of one discriminating early-withdraw composition. A deposit arriving
  on a distinct Gifter–Exporter Port traverses Node and Host to settle and flush
  the Receiver–Exporter Port; with no deposit or unrelated traffic, closing the
  gifter instead wakes and breaks that same wait. These scenarios do not
  reconnect a replacement Peer under the reused Host key.
- The pinned OCapN implementation guide's handoff section supplies the external
  session-liveness authority; live Goblins fixtures remain the interop gate for
  wire behavior.

## Alternatives considered

- **Keep Host-wide gifts but always consult the live-session resolver.**
  Rejected: it repairs one authorization check while retaining the wrong owner,
  copied provenance, cross-session row keys, and teardown lifetime.
- **Move gifts into the Vat.** Rejected: a gift table and replay counter are
  CapTP transcript state. A pure-local Vat has neither sessions nor handoffs,
  and snapshot/restore must not rewind protocol authority.
- **Keep per-gifter replay maps.** Rejected: `handoff-count` is monotonic within
  the live Receiver–Exporter session. One scalar expresses that namespace and
  cannot grow from partner-chosen identities.

## Consequences

- Closing either required Exporter Peer destroys that Peer's gift and replay
  state. Failure stays closed while its session names remain absent; ADR-0097
  owns the fresh-key work that makes those names unique across reconnects.
- Automatic V1 redeems from one Node do not restart their emitted wire count
  when an exporter session is replaced. Independent receivers still cannot
  coordinate around Goblins' misplaced comparison; that upstream defect
  remains recorded in `docs/upstream-watch.md`.
- Gift rows no longer duplicate a 32-byte gifter key or carry a gifter-side map
  dimension; replay counters allocate no map rows.
- `max_seen_handoff_counts` and `HandoffCountCapExceeded` are deleted. The
  remaining gift and pending-withdraw caps still project loud resource refusals.
- Host and Vat remain the one-to-one standard composition decided by ADR-0096,
  but neither becomes the owner of session transcript authority.
- Scheduler rows are proportional to live `(gifter, gift-tag, receiver)`
  groups. The fixed-size tag prevents partner-chosen gift-id length from
  entering scheduler storage. While any dependency group
  remains, its receiver map and the outer/change tables may retain historical
  peak capacity; total scheduler quiescence frees all three backings. Deposit,
  close, and dirty-FIFO insertion are allocation-free. The Host FIFO backing
  retains its historical peak live-shell capacity until Host teardown. The
  Host action FIFO also reserves two notification slots per live shell (one
  flush and one close) and retains that historical peak. Deposit wake work is
  proportional only to receivers waiting for the changed gift; close work is
  proportional to still-live gift groups rooted in the closing gifter.
