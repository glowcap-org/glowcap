---
id: ADR-0116
status: accepted
date: 2026-08-16
tags: [captp, handoff, promises, host, lifecycle]
decision: "A signed handoff give may occur recursively in Passable data. Inbound gives become Host-owned capability promises immediately. Outbound foreign objects and promises project through one bounded, failure-atomic transaction that retains every capability occurrence until publication or terminal cleanup. Session-owned gift and replay authority remains on Peer."
supersedes: []
superseded_by: []
amends: [ADR-0009, ADR-0066, ADR-0069, ADR-0090, ADR-0100]
amended_by: [ADR-0121, ADR-0235]
---

# ADR-0116 Inline Passable handoff

## Context

The pinned CapTP draft permits a signed `desc:handoff-give` anywhere a Passable
value may occur. Handoff that completes only for a foreign capability that is the top-level
fulfillment of an answer refuses the same capability inside a list, set, tagged
value, struct, ordinary call argument, or fulfilled value, or lets it reach the
outbound token guard.

An inline give has two independent delays. A receiver must expose a usable
promise before exporter discovery and withdrawal finish. A gifter cannot emit
the containing message until the process owner supplies a gift id and every
exporter deposit can commit. Binding policy for either delay would give each
language a different capability lifecycle and failure contract.

## Decision

Inbound signed gives are lifted recursively by the Host. Each occurrence mints
one opaque Host capability whose target is a deferred promise row. The
containing call or fulfillment is delivered immediately. Sends and listeners
against that identity queue behind the row until the Node's ordinary redemption
state machine fulfills or breaks it. The row records the introducing session.
That session's close breaks the promise and cancels any not-yet-started
withdrawal because its session key is the recipient authority named by the
give.

Outbound owning-value verbs retain every capability occurrence before lowering.
The Host exposes those retains to the Node only for the synchronous call into
the recipient Peer. The Node claims the retains for cross-session tokens and
adopts the complete owned message. Unclaimed retains return to the
Host immediately. Claimed retains stay with the staged transaction until the
message publishes or fails terminally.

One staged transaction requests one gift id per foreign-object occurrence and
retains no partially published wire result. After all ids arrive, the Node
groups deposits by exporter and reserves each exporter's complete queue batch.
For each distinct foreign promise it prepares one shared home listener and a
paired promise export/import escrow for every recipient occurrence. It then
recursively rewrites object leaves to signed gives and promise leaves to the
recipient promises. The recipient message commits first. Prepared listeners,
escrows, and deposits then publish through infallible reserved carriers.
Independent transports may deliver those committed frames in either order,
which the handoff protocol permits.

A locally originated promise is allocated as one explicit export-to-answer
projection. Export and answer positions are independent namespaces, so equal
integers imply no relationship. A bare unresolved promise export is the
lower-level primitive used by a third-party proxy and receives no local answer
semantics by inference.

The recipient Peer charges the complete parked semantic payload against its
outbound byte budget. That payload is either an ordinary `Message` or an answer
settlement retaining its exact session-local `AnswerTarget` (wire-or-virtual
name plus incarnation stamp), stable answer payload, and `Resolution`. A virtual
answer is not coerced into a wire `op:resolve`. `op:gc-answers` releases the
partner's pipelining name, not a resolver or listener notification already
accepted for that incarnation. Such a notification moves to a private stamped
owner until it publishes, so legal name reuse cannot cancel the old result or
redirect it to the replacement question.
When a settlement commits, its resolution charge moves one-for-one out of the
transient outbound waterline and into the Session answer store's separate
durable-byte cap. Answer GC, local-promise retirement, or teardown releases the
exact charge.
The queued store-borrow carrier keeps its complete fixed footprint charged
beside that resolution. Answer-payload and export-table capacity are acquired
before any export mention or answer status changes. A V1 export mention is
retained only when the answer has a resolver callback, while next retains each
mention with the listener fire that will publish it.
The Node bounds aggregate staged occurrences per recipient by that session's
queue cap. One queued terminal consequence and one capability-release
consequence per occurrence are reserved before adoption. Entropy failure,
object/promise home loss, origination refusal, proxy pressure, or recipient
admission failure cancels every sibling effect, publishes no deposit or
listener, and asks the Host to run the recipient session's complete close
barrier. That barrier breaks already-returned vows and cancels admitted turns.
Terminal capability cleanup consumes each transferred retain once. Failure to
publish GC condemns a still-live home.

The Peer owns deposited gifts, replay state, session names, and
wire accounting as decided by ADR-0100. The Node owns only the bounded in-flight
transaction, routing tokens, and scheduled consequences. The C ABI and language
bindings project Host values and lifecycle outcomes. They do not originate
gives or keep a second promise state machine.

## Scope (what this does not decide)

Pinned Goblins recursively recognizes gives in lists, sets, and hashes. Its
user-record path does not recursively transform record fields, so live Goblins
evidence uses the shared container forms and does not claim tagged-value
coverage on that peer.

## Alternatives Considered

- **Require applications to return every delegated capability.** Rejected
  because it narrows Passable below the pinned protocol and makes an ordinary
  push impossible.
- **Let each binding create a language-native promise and handoff worker.**
  Rejected because protocol authority, close behavior, and failure delivery
  would be reimplemented per runtime.
- **Publish deposits as gift ids arrive.** Rejected because a later sibling or
  recipient refusal would leave externally visible gifts for a message that
  never existed.
- **Keep raw Host capability ids without retaining them.** Rejected because the
  caller may release its final handle while entropy is pending, retiring the
  route before the accepted message can publish.

## Consequences

- The owning `Value` APIs pass foreign objects and promises recursively.
  Raw/model APIs refuse cross-session arguments because they carry no Host retain that a
  delayed transaction can adopt.
- Actor answer settlements and ordinary messages select different semantic
  roots but share the same recursive count, collect, rewrite, and rollback
  passes. Completion moves the rewritten resolution through the named-answer
  enqueue/store transaction. Codecs and bindings never stage it themselves.
- A delayed outbound occurrence adds one bounded staging row, one Host retain,
  and reserved terminal consequences. Promise occurrences additionally consume
  one bounded proxy-recipient seat. Occurrences sharing a home promise share its
  single listener. Ordinary same-session messages do not enter this path.
- Closing the introducing session ends inbound redemption authority. An
  installed Host session-key resolver does not substitute the Node's durable key
  for a missing session.
- A staged failure is a session lifecycle outcome.

## Evidence and gate

- `test/engine/node/gift_test.zig` covers recursive and repeated object/promise
  occurrences, shared promise listeners and settlement, mixed atomicity,
  out-of-order gift ids, both codecs, no partial deposit, entropy failure,
  recipient refusal, and object/promise home close.
- `test/engine/node/answer_settlement_test.zig` covers wire and virtual named
  settlements returning repeated nested foreign references through real V1
  resolver callbacks and next-listener notifications, all-or-nothing gift-id
  completion across answer GC and legal name reuse, zero V1 wire holds without
  a resolver, resolver-only virtual-row retirement, retained-byte
  transfer/release, and allocation or admission refusal without answer or
  projection authority loss. `test/session/answer_notification_test.zig` pins
  allocation-atomic detachment, retry, and duplicate-GC refusal.
- `test/driver/core_host/give_test.zig` covers immediate inbound promise identity,
  pipelining, introducing-session close, retained outbound capability lifetime,
  and settlement of a returned vow through terminal failure.
- `test/c_abi/host/handoff_test.zig` carries two nested occurrences through three Hosts
  and the C behavior surface while the caller releases its original handle.
- `zig build bindings-goblins-gift` carries two nested occurrences through Deno,
  Python, Rust, and Racket. Live Goblins redeems and calls both direct exporter
  capabilities in every leg.
