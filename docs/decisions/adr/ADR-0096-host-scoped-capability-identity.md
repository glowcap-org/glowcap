---
id: ADR-0096
status: accepted
date: 2026-07-31
tags: [actors, captp, handoff, identity, host, publication]
decision: "Host and Vat remain separate layers, while the standard multi-session product composes one of each through session-specific ports. Application-held capabilities are opaque Host-scoped identities. Wire positions are projections, publications are names for one vat target, and gifts retain the exact target deposited."
supersedes: [ADR-0092, ADR-0094]
superseded_by: []
amends: [ADR-0056, ADR-0059, ADR-0060, ADR-0062, ADR-0068, ADR-0069, ADR-0072]
amended_by: [ADR-0100, ADR-0101, ADR-0113, ADR-0196]
---

# ADR-0096 Host-scoped capability identity

## Status

Accepted and implemented. Fair queueing, one Host Vat with per-session Ports,
sparse lazy publication, the exact-target gift mechanism, the Host capability
table, the one-id C ABI, Wasm, and all four bindings ship. The owning `Session`
facade uses the opaque identity: every verb takes and returns
`driver.Capability`, arguments and replies use the Host-shaped `Value`/`Reply`
vocabulary with lift and lower at the Host boundary, and hosted behaviors answer
through the `Hosting` adapter. Wire references remain only on the explicit
`engine.Peer` and `BlockingSession` tiers.

Alias-only unpublish works through every publication tier (`Host.unpublish`, the
native `HostRuntime` / `Server` surfaces, `glowcap_host_unpublish`, and all four
bindings). A removed alias misses on every session, an issued capability stays
callable, and a deposited gift redeems the exact actor.

Separate records decide the related questions: actor reclamation
([ADR-0101](ADR-0101-actor-roots-and-reclamation.md)), fresh session identity
([ADR-0097](ADR-0097-captp-session-identity-attestation.md)), sturdyref
authority ([ADR-0098](ADR-0098-sturdyref-peer-authority.md)), and shared-Vat
scheduling ([ADR-0099](ADR-0099-shared-vat-scheduling.md)), which changes
pure-local Vat behavior even when no Host exists.

## Context

OCapN says a third-party gift is the imported reference the gifter holds and
that withdrawal returns that gift. Goblins implements those words directly: a
bootstrap stores the local object reference in its gift table, and withdrawal
returns that object. All of its CapTP sessions and bootstrap objects run in one
vat, so the same local reference can be projected onto a different session.

glowcap's earlier shape had four faults:

- every `HostSession` owned a separate `actors.Vat`
- Host-wide publication spawned a separate actor copy in every session vat
- a deposited local object was retained as `{ reference, swiss }`, but
  withdrawal ignored the reference and looked up the current swiss mapping on
  the recipient's session
- fetched far references were enrolled with their owning session, while
  ordinary reply, argument, and enliven references could escape as a bare
  import position

They are one fault: a name meaningful in one scope was used as capability
identity outside that scope. A swiss number is a bootstrap lookup key. An import
or export position is a session-local wire name. Neither is a Host object.

The visible failure: publish object A under swiss `S`, a gifter deposits A,
replace `S` with object B, withdraw over another session, and glowcap returns B
(or fails if `S` is absent). The same class lets two sessions' equal numeric
import positions be confused unless the application calls `enroll`. It also
blocks target pass-invariant equality: a target that leaves its home and
returns through another path must be recognized as the same target, not a new
proxy or an equivalent actor copy.

## Decision

### Host and Vat stay separate

`Host` is the CapTP control plane. It owns sessions, routing, crossed-hello
policy, handoff verification, and driver actions. `Vat` is the object execution
plane. It owns one local actor graph, turns, near calls, eventual local sends,
`become`, and snapshots. They remain different types, and the engine never
imports actors.

The standard `driver_core`/C/binding product composes exactly one Host with one
Vat. A `HostSession` owns a session-specific Port into that Vat. The Host's
`engine.Node` owns the Peer allocation. The Port borrows that Peer and owns the
actor-layer projections and listeners scoped to its session. Neither owns
another actor heap. A pure-local Vat remains usable without a Host. A raw
`engine.Node` remains usable with an application-supplied dispatcher instead of
glowcap's actor layer.

```text
standard runtime composition
├── driver_core.Host           CapTP node, sessions, routing, actions
├── actors.Vat                 one local object graph and turn queue
├── bootstrap publications     swiss -> local target identity
└── HostSession ...
    └── actors.Port
        ├── engine.Peer*        borrowed; Node owns the CapTP session allocation
        ├── far vows/listeners  answer positions for that session
        └── target projections  exports for that session
```

`actors.Vat` owns target identity, actor behavior, local vows, turns, snapshots,
and local queueing. `actors.Port` borrows its Node-owned `engine.Peer` and owns
every actor-layer fact containing a session name: export projections, far-vow
listeners, resolve interceptor, and dropped-answer bookkeeping. A far vow is
`{ port_id, answer_position }`, never a bare answer position in shared Vat
state. Equal answer or export positions on two ports therefore cannot collide.

A turn remembers its ingress port for replying, but `Turn.me()` is the Vat
target rather than a session position. Spawning from any turn joins the same
Vat. Moving the existing session tables from Vat to Port must not duplicate
them or introduce Host-wide scans. The per-Port shell remains measured by the
warmed-session footprint check.

The standard product has one-to-one cardinality, and the types stay separate so
local actor use, a custom dispatcher, and the sync no-I/O engine remain
independently usable.

### The four identity layers stay explicit

The composition uses four distinct representations:

- the local arm of `actors.Ref` identifies an actor only inside one Vat
- the opaque Host/application capability id identifies a live local or remote
  capability in one Host composition
- a Port projection maps between Host/Vat identities and one session's wire
  names
- `model.Reference` is wire-only protocol vocabulary

The base Vat API remains usable with `actors.Ref` and does not import Host
routing. The standard Host/Vat adapter wraps local targets as Host capability
ids and resolves them back at the Port seam. The Node carries opaque local
target ids for exact-gift projection and its own far routing tokens, but it
neither owns actor projections nor learns actor types.

### Application references are Host identities

The raw `model.Reference` remains codec-neutral wire vocabulary for `session`
and `engine.Peer`. It does not cross the Host/application boundary as a live
capability.

Host-facing and Host-composed actor surfaces use an opaque capability identity
with two internal forms:

- a local row naming one target in the composed Vat
- a remote row naming its owning `PeerHandle`, real import position, kind, and an
  import-row generation that makes reuse fail closed

The C and binding `Ref` types carry the opaque Host id. They expose no position
that a caller can combine with a separately selected session. Promise and
answer handles remain separate types.

An adapter chooses the id source. The C adapter maps one process-wide monotonic
source through a process-keyed 64-bit permutation because the ABI erases the
native registry-pointer scope. An opaque id is never issued by two Hosts,
reissued after retirement, or exposed as an adjacent scalar. Native scoped refs
use a Host-local monotonic source and carry the registry pointer as scope. A
Host-owned id index maps its live ids to reusable private slots. Another Host's
raw C id is absent and fails closed. A remote import row records its live id.
Repeated mentions retain that row and preserve wire-delta accounting. Final
application release removes the remote row and id index entry, then releases
the import. Session close invalidates every row homed there and removes its
target/canonical index immediately. A release-only row containing only the id
and outstanding application-retain count survives so a later binding finalizer
can settle each already-issued unit without addressing the dead session. It
cannot resolve or project, and disappears with the last release. A local
registry row remains only while an application handle retains it. Publications,
gifts, and Port projections retain the actor directly in the Host Vat. Ordinary
final release leaves no per-id tombstone, so retained storage is bounded by live
capabilities plus invalidated handles that applications can still drop. Stale
handles fail closed.

Every inbound reference is lifted while its owning session is known. This
includes fetch and enliven settlements, ordinary call settlements, delivered
arguments, references nested in pass-by-copy values, handoff redemption, and
local exports surfaced to the application. The live import row remains the
lifetime and deduplication authority, so lifting the same import reuses its Host
id.

Every outbound Host reference is lowered through a selected port. A local
target acquires or reuses that port's export position. A remote target lowers to
its real import position only on its home port. Use elsewhere asks the Node to
originate a handoff. A retired id has no fallback to the
caller-selected session.

There is no `session.enroll(ref)`. Lift records ownership.

### Lift does not add a second outbound walk

Automatic lift does not set `Node.foreign_active` merely because an application
received a capability. Lift records the Host id on the owning import row.

Host-shaped arguments are lowered at the application/Host boundary, where both
the destination Port and the Host ref are present. Translation is fused into
the outbound ownership clone that already walks an argument tree to move it
past the caller's lifetime. The one traversal clones values and replaces Host
refs with wire refs together. The engine then receives ordinary wire-shaped
arguments for same-home refs.

A scalar capability-free send keeps its existing direct clone path. A nested
capability-free value pays only the traversal its ownership clone already
requires. A capability-bearing value pays no second Host-ref scan. The Host
representation does not add an advisory `contains_refs` bit that can drift from
the value it describes.

`Node.foreign_active` remains reserved for Node-generated cross-home routing
tokens that can enter an already wire-shaped outbound message. Therefore a
two-party application that merely receives one capability does not switch on a
second walk for every later send. Host-shaped messages never reach the later
engine lowering walk. Node-generated wire messages may still use it when
`foreign_active` says a routing token exists. The migration must preserve this
one-materialization, one-traversal rule with scalar and deeply nested
allocation/performance scenarios.

### Local projection is canonical and sparse

Each live port starts with the bootstrap projection row required by CapTP.
Additional reverse rows are created only for targets projected on that
session. Re-projecting the same target on one live port reuses its export
position. Closing the session drops the projections, never the Vat targets.

An inbound delivery resolves its target through the port and runs the one Vat
actor. A reply containing `Turn.me()` is lowered through the reply port.
Projecting that actor onto another session creates another wire position for the
same Vat target.

The Host handoff router recognizes a local target returning through handoff and
asks the owning Port to map it to the existing Vat target. `engine.Node` carries
only the opaque local target needed for routing. The Host/Port layer owns the
actor projection. A returned local object never becomes a far proxy to itself.

### Publication is naming over targets

The Host publication registry is `swiss -> local target id`. Publishing a
behavior spawns it once in the Host Vat, then binds the name to that target.
Bootstrap fetch resolves the registry and lazily projects the target onto the
requesting port. New sessions neither replay every publication nor spawn actor
copies.

Replacing or unpublishing a name changes discovery only:

- a fresh fetch observes the new mapping or a miss
- capabilities already issued still name their original target
- gifts already deposited still retain their original target
- actor reclamation is currently Host-lifetime, not movement of a public name.
  Defining earlier collection requires roots across aliases, gifts,
  projections, queued turns, and issued capabilities

The distinction between mutable aliases and safely minted durable sturdyref
names belongs to ADR-0098. This record needs only the rule that a name is not
the target it currently discovers.

### Gifts retain the exact local target

The exporter resolves the deposited near reference through its port at deposit
time. The gift payload stores the resulting local target id. It stores no swiss
and performs no publication lookup at withdrawal. An unnamed exported object is
as giftable as a published one.

Withdrawal validates protocol authority in the engine, resolves the signed
`gifter_exporter_session` to its live session coordinator, and only then parks a
missing deposit. Once the row exists, the destination port projects the retained
target and fulfills with that near wire reference. Deposit and withdrawal may
still arrive in either order. The gift row belongs to the Gifter–Exporter Peer,
while replay authority belongs to the Receiver–Exporter Peer. Both are destroyed
with their sessions. No gift or replay table belongs to the Host or Vat.

The engine retains no actor pointer and imports no actor module. Its
cross-session identity is an opaque local-target id owned by the Host/Vat
composition.

### Snapshot and queue scope follows the Vat

One Vat changes the scope of actor-local operations:

- a snapshot of the Host-composed Vat covers every actor in that Host, including
  actors reached through different sessions
- restore rolls back that complete actor graph, while session/port protocol
  state remains outside the snapshot
- Host capability rows, publications, gifts, Port projections, and identity
  counters are authority and are never rewound
- a target created after the snapshot and removed by restore makes every
  surviving capability to it fail closed. Monotonic target ids are not reused
- if restore removes a target still named by a live Port export, an answered
  inbound delivery breaks that answer with a typed target-missing actor error.
  A one-way delivery is refused locally. Neither path aborts the session,
  retargets the export, or tears down another Port
- queue ownership and arena reset span the Host-composed Vat rather than one
  session. ADR-0099 owns the bounded, fair scheduling contract that wider scope
  requires.

ADR-0060's copy-on-write state-box semantics remain intact, with its scope
amended from one session to the composed Host Vat. The queue cannot be one
arena whose reset waits for every session to become quiescent (ADR-0099).

## Cost and lifetime posture

The design removes each session's retained Vat arenas and actor list, publication
replay, and per-session actor copies. It adds no eager all-object map to a
session. Every port has its mandatory bootstrap row, and later projection rows
are sparse.

Named costs are:

- lifting a newly observed import installs one Host row and records its id on
  the existing import row
- final release reclaims that row and retires its never-reused id. Session
  invalidation retains only the id and outstanding release count until those
  already-issued units settle, while ordinary capability churn retains no
  per-id tombstones
- projecting a local target on a new port installs one export and one sparse
  reverse row
- lowering is fused into the existing outbound ownership clone, with no second
  recursive walk
- queue widening pays only the costs accepted and measured by ADR-0099

The `HostSession` ceiling is `host_session_struct_budget_bytes`. The Vat is charged once per Host.
The [performance page](../../../site/content/performance.smd) charts the
current session and Host costs.
The warmed-session footprint, allocation budgets, and ordinary-send
performance tripwire keep their ceilings. The saving is not headroom for eager
routing tables.

## Required evidence

These production-Host scenarios hold the decision:

1. Publish stateful A, mutate it, deposit it, replace its alias with B, withdraw
   over another exporter session, and observe A's mutated state. A fresh fetch
   observes B. Repeat after unpublish: fresh fetch fails, while the gift and an
   already-issued A remain callable.
2. Deposit and withdraw an unnamed local export.
3. Withdraw before deposit, with session resolution and signature verification
   occurring before the wait is parked.
4. Put different remote objects at the same numeric import position on two
   sessions. Lift each through an ordinary reply, a delivered argument, and
   enlivenment. Every capability routes to its owner.
5. Project one stateful local actor over two sessions and observe one state and
   one `become` history.
6. Send a local target away and return it through direct passage and through
   handoff. Both recover the original local target id.
7. Reach the same remote exporter target once directly and once through handoff,
   with both paths explicitly using the same live exporter session and canonical
   import row. Both reuse one Host ref and compare Equal. This is the positive
   remote half of target pass-invariant equality. Parallel sessions carry no
   stable target id from which glowcap could infer equality. ADR-0097 must
   separately prove that fresh-key peer/session selection preserves convergence.
8. Close a session, reuse its numeric ranges, and prove every stale Host ref
   fails closed.
9. Run the identity and gift cases through Zig, the C ABI, Wasm, and
   every binding. Strengthen the live Goblins exporter fixture to mutate and
   invoke the withdrawn object instead of checking only descriptor shape.
10. Restore a Host Vat while two sessions remain live and remove a target still
    projected on one Port. An answered delivery to that export breaks only its
    answer with the typed target-missing reason. A one-way delivery is refused
    locally. Both sessions remain open and the position never retargets.
11. Under two-party traffic, lifting one remote capability leaves the
    scalar and deep capability-free send paths at their existing
    walk/allocation budgets, while a capability-bearing tree is traversed once.
12. Deposit through a production Gifter–Exporter session, close that session,
    then attempt withdrawal over a live Receiver–Exporter session. The gift is
    already reclaimed and redemption breaks because the gifter session is not
    open.

### Where each item is held

Items 1 and 5 are held by
[`test/driver/core_host/`](../../../test/driver/core_host/):
the alias-replacement scenario mutates A, deposits it through the
gifter-facing Port, replaces the alias with B, withdraws through a second
exporter Port, calls A through the redeemed capability, and fetches B by name
(also the shared-state half of item 5). The unpublish scenario holds item 1's
removal half, and the become scenario holds item 5's history half, one `bump`
per Port observed from the other. The same file holds item 2 (an unnamed
maker-spawned actor deposited and withdrawn as the exact mutated target),
item 7 (the redeemed route and a direct fetch over the same exporter session
lift to one Host identity and compare Equal), item 10 (restore under two live
sessions breaks only the missing target's answers, typed, with no retarget),
and item 12 (gifter-session close reclaims the gift and later withdrawal
fails closed). Item 3 is held in the two layers described below.

Items 4, 6, 8, and 11 are held by
[`test/driver/capability_registry_test.zig`](../../../test/driver/capability_registry_test.zig):
equal positions scoped per session, canonical lifts through ordinary replies
and delivered arguments, stale-id and foreign-Host refusal with never-reused
public ids, and the bounded-index first-lift / allocation-free repeated-lift
budgets. The engine's own send-path budgets are unchanged and hold the
capability-free arms.

Item 9: the engine scenario in
[`test/engine/cross_peer/`](../../../test/engine/cross_peer/)
holds the opaque capture/projection seam, and the driven oracle asserts the
recipient's direct call addresses the exact projected position. The C Host
handoff scenario additionally fetches the withdrawn target over its exporter
session and requires the two opaque ids to compare equal. Each binding
proves the exact-gift mutation case on its public surface: the Deno stack in
`bindings/ts/dogfood/gifter_handoff.ts`, Python in the `zig_smoke.py`
direct-message scene, Racket in the `zig-smoke.rkt` redeem-dial scene, and
Rust in `bindings/rust/examples/iroh_handoff.rs`. Each mutates the held
object, replaces the alias with a decoy, and asserts the withdrawn object is
the mutated original. Their recurring sturdyref scenarios also require a
cached Host id to compare equal through Rust `PartialEq`, Python `==`, Racket
`equal?`, and TypeScript `Ref.equals`. Release state is not part of that fact.
The browser surface shares the same `@glowcap/runtime`
gift logic over the wasm adapter, whose equivalence `zig build web-peer-test`
holds and whose live redemption `zig build rooms-web-dm` proves in a real
Chromium. The live Goblins exporter fixture (`zig build goblins-exporter`)
primes the glowcap-hosted actor from the Goblins gifter, replaces the
alias with a decoy, and requires the Goblins recipient's withdrawn greeting
to carry the mark.

Item 3 is held in two layers. The engine scenario verifies an early receive,
accepts its replay count before waiting, rejects a duplicate certificate, and
settles it after the deposit from the retained pending row. The production Host
scenario in
[`test/driver/core_host/`](../../../test/driver/core_host/)
proves that only a live session with a verified partner key can resolve the
gifter side and signed session name. Unverified sessions enter neither identity
index. Item 12 is held by the adjacent production Host scenario: it delivers the
deposit while retaining the give, closes both Gifter–Exporter halves, then
delivers the give and proves redemption fails closed over a fresh
Receiver–Exporter session.

## Scope (what this does not decide)

- Wire descriptors and signed handoff record shapes are unchanged.
- Raw `engine.Peer` callers may continue to use session-scoped
  `model.Reference`s. The Host boundary performs lift and lower.
- Fresh per-session CapTP signing keys and their transport authentication are
  ADR-0097's decision.
- Complete sturdyref peer matching and non-reassignable durable swiss names are
  ADR-0098's decision.
- Shared-Vat admission, fairness, queue chunking, and incremental reclamation
  are ADR-0099's decision.
- Duplicate simultaneous deposits under one live `(session, gift-id)` are an
  upstream watch item.
- Durable bootstrap storage across process restart is unimplemented.
- Promise pass-invariant equality is not required by the OCapN model. Target
  identity is.

## Alternatives Considered

- **Stable publication-generation id plus one actor copy per session.**
  Rejected: it selects equivalent copies, not the deposited object.
  State, `become`, stored refs, and child actors can diverge.
- **Re-resolve the swiss at withdrawal.** Rejected: naming is discovery, and
  later mutable publication state cannot replace a deposited capability.
- **Keep optional `enroll`.** Rejected: every live reference has an owner,
  whichever API produced it.
- **Cross-vat forwarding proxies.** Rejected: they preserve some calls but not
  object identity, turn context, local refs, `become`, snapshots, or
  pass-invariant equality. They also add a proxy allocation and promise bridge.
- **Merge Host and Vat.** Rejected: the boundary between CapTP routing and
  replaceable local execution stays.
- **Put actor objects in `engine`.** Rejected: the engine owns CapTP state and
  opaque routing identity, while actor policy remains replaceable above it.

## Consequences

- `driver_core.HostSession` loses its inline `actors.Vat`. Host composes one Vat
  with session-owned ports.
- The base actor layer keeps Vat-local target identity. The standard composition
  adds Host capability ids and Port projection instead of making pure-local Vat
  refs depend on Host routing.
- Far vows, listeners, resolve interception, dropped answers, and exports move
  from Vat to Port, so every session position retains its owner.
- Host gains the capability-id table and canonical local-target
  projection. `engine.Node` routes opaque ids without owning actor state.
- `GiftPayload.named_cap`, gift swiss copies, per-session giftable replay, and
  retired giftable rows are deleted.
- C and binding refs stop exposing live positions and stop requiring `enroll`.
- ADR-0100 supersedes ADR-0056: each CapTP session owns its gifts and scalar
  replay counters. This record supplies the exact local target retained in a
  Gifter–Exporter session's gift row.
- ADR-0068 stays the one-Host/many-session and crossed-hello design, with its
  actor composition amended from one Vat per session to one per Host.
- ADR-0069's generation-checked Node routing is the substrate, generalized from
  fetched/enrolled refs to every lifted capability.
- ADR-0094's explicit-enrollment application contract is superseded.

## Notes

The wire authority is the pinned OCapN CapTP and Model text. The runtime shape
is also exercised by the pinned Goblins endpoint and gift registry: one vat,
many sessions, with direct local references in naming and gift tables.
