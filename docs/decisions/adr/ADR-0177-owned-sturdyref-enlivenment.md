---
id: ADR-0177
status: accepted
date: 2026-09-26
tags: [captp, ownership, loam]
decision: "Own Host completion values and capability retains, and admit an owned enliven recipient before cached, wire, or parked resolution."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0182]
---

# ADR-0177 Owned sturdyref enlivenment

## Context

Loam foreign-reference preparation needs to await a checked sturdyref without
consuming unrelated Host actions. The existing select-or-dial API returns a vow
ID before a session necessarily exists. Parked operations and cache hits can
therefore finish without a row on which a caller can install `vowOn`.

A preparation also needs to cancel before reclaiming its arena. A callback left
on the network producer could otherwise address reused call memory. The public
vow-release operation refuses an installed observer.

The existing action FIFO cloned raw Arguments without retaining their capability
observations. A later cached enliven could acquire and release the last retain,
leaving an earlier queued or transferred completion with an unusable reference.
Cloning bytes alone did not establish ownership.

## Decision

`Host.enlivenCapability` returns one allocator-owned operation with `result`,
`take`, and `deinit`. A ready result borrows an ordinary retained Host capability
and reports the peer provenance. Taking transfers that retain. Failure reports
the existing Host failure category and bounded diagnostic text.

The existing enliven producer selects either an action or an owned observer
before starting. Both destinations share identity checks, cache admission,
fetching, and Node dial selection. Owned outcomes never enter the embedder's
completion FIFO. A cache hit may complete before the constructor returns.

Connected admission reserves the observer's answer-release carrier before the
fetch commits. Cancellation detaches the exact producer and publishes that
reserved release without allocating or invoking the observer. Normal Host
progress handles the resulting wire work. Parked cancellation removes only
that observer and its owned locator bytes. The shared dial remains Host work
until its executor reports an outcome or Host shutdown cancels and joins it.
The operation must be destroyed before Host destruction.

The same capability registry canonicalizes wire and cached results. An invalid
result or failed projection retires all unexposed reference observations through
the existing Host cleanup path. Session teardown and remote rejection use the
same failure classifier as action-based completions.

Settled Host actions own a Host `Value`, its arena storage, and one retain per
capability occurrence. Materialization lifts capabilities and copies data in one
walk. Cached action results acquire an ordinary application retain without
inventing a wire occurrence. Borrowed pops, retries, transferred actions, and
parked adapter completions carry this same owner. Live disposal releases the
retains. Aggregate destruction frees storage after the other owners retire.

`projectCompletion` grants independent consumer retains before converting
representation. Refusal rolls back just those new retains, leaving the action
available for retry. The stable Value tree supplies the rollback prefix without
a scratch allocation. The callback's byte views still borrow the action unless
it copies them. `projectCompletion` takes no scratch allocator. Projection uses
each capability's Host owner, not the session that delivered it. Plain data,
local capabilities, and third-party capabilities may outlive that session. An
invalidated capability reports closure.

## Costs and alternatives

The constructor allocates one fixed-size operation from the caller's allocator.
Its bounded failure buffer needs no allocation at completion. Existing connected
enlivenment already allocates a vow row and cache bridge. Observed admission
additionally reserves the ordinary answer-release carrier. Each parked row adds
its completion recipient. Session struct size does not increase. Action size
increases from 64 to 80 bytes for the inline arena state. The Host's last-action
slot increases the safety-build aggregate from 2,344 to 2,360 bytes. Both are
pinned by the Host footprint test. Scalar and cached capability completions need
no arena backing. Composite data is materialized once. Up to eight lift receipts
stay inline. Larger receipt lists use temporary Host allocation freed before
publication, rather than remaining in the action arena. Projection adds no
allocation for capability custody.

Generalizing signed-handoff capability promises would introduce new producer
authority and lifecycle semantics that foreign-reference preparation does not
need. A second Loam proxy queue or action dispatcher would duplicate Host
ownership. Method-declared preparation can instead await a ready capability
through this operation while unrelated local calls continue offline.

## Evidence and remaining integration

[Owned enliven tests](../../../test/driver/core_host/enliven_test.zig) cover
wire/cache identity, parked completion, exact cancellation, shared observers,
public-completion coexistence, session closure, missing targets, allocation
refusal, and cancellation under allocator pressure. Existing enliven and handoff
scenarios use the same producer. [Completion custody
tests](../../../test/driver/core_host/completion_test.zig) cover nested
duplicate retains, projection refusal and retry, source closure, borrowed-action
retry and disposal, and allocation refusal before and after the inline receipt
boundary. Releasing a cached observation while an earlier completion is
transferred is covered by a regression case.

This is a public Zig Host operation. Loam's foreign recipe format, preparation,
and dependent disclosure remain with the
[access API contract](../../loam/access-api.md#c-and-rust-bindings). This operation alone does
not implement foreign durable fields or establish that a supplied sturdyref
designates a separately held capability.
