---
id: ADR-0071
status: accepted
date: 2026-10-27
tags: ["session", "testing", "invariants", "gc", "promise"]
decision: "Local accounting is audited at teardown in safe builds and after engine and driver fuzz steps. Paired test drivers check open sessions at rest, and complete-release scenarios require zero remaining wire obligations."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0071 Session audit and pair agreement

## Context

The session keeps counters beside its tables so that admission and release
decisions stay constant time: import retains, held rows, deferred
settlements, Host promise marks, and the retained-answer and queued-call
byte charges. Each counter is a second statement of a fact its rows already
hold, and each moves at a different site. A drift between the two is
silent until a later admission refuses a correct peer or a release reaches
the wire twice.

Two sessions also hold one fact between them. An export this side counts
is an import the partner holds, a question this side asked is an answer the
partner keeps, and a settled answer has handed off every call and listener
anchored on it. No single session can see a violation of these relations.
Successive review passes found defects of exactly these two shapes, one
path at a time.

## Decision

`session.audit.check` checks import retain bounds, held-row counts,
projection membership, deferred settlements, and queued-call bytes against
the session tables. Reachable payloads give lower bounds for Host promise
subscriptions and retained resolution bytes, because carriers and Host
promises may hold payloads outside those tables.

`Session.deinit` runs the audit in safe builds, so every test and every safe
embedding checks its sessions at teardown. A violation panics as an internal
invariant. Teardown
also returns the charges the answer tables release, asserts the retained
and queued byte counters reach zero, and asserts no Host promise stays
subscribed. The engine and driver fuzz targets run
the audit after every step.

The ordinary check compiles the standalone fuzz root too. Corpus replay in
the main suite cannot prove that a separate test root has the module imports
it needs. Mutation search remains a separately budgeted operation.

`oracle.agreement.check` audits both sessions of a pair, then checks both
directions of the cross-session relations for a pair at rest
(`oracle.agreement.atRest`): wire holds, questions and answers, settled
answers that keep no work, and no settlement owed. A closed pair or one with
traffic in flight is refused by the check. Pair pumps explicitly exempt
closed sessions, whose teardown owns their cleanup. The engine fuzz targets
compare after settling, the Host pair harnesses after every quiescent pump,
and every oracle scenario that ends with its sessions open after shuttling
the traffic its trace leaves queued.

An outbound answer row that a listen records is local to this side, so it
carries `AnswerCell.listen_record` and is no question the partner keeps.
Session validation refuses to send its position as an answer descriptor or
wire release, and refuses an incoming wire resolve naming it. Resolver
callbacks may still settle the local record. Host vows record who releases an
answer and read its wire visibility from the session, including its exact
incarnation. Host custody claims cover local records as well as wire questions.
Stateless collection validates exact identities before serving callbacks.
Afterwards it leaves claimed answers and callback-retired incarnations alone.
Unclaimed local records retire locally, while wire questions leave in bounded
GC batches. Paired fixtures that install rows by hand install the matching
peer state too.

Both profiles deliver settlement through resolver exports. Retiring an answer
therefore frees its slot immediately. A resolver tombstone consumes a late
callback without addressing a replacement at the same answer position.

## Alternatives and consequences

Asserting each counter at the site that moves it checks one transition, not
the sum, and repeats the row walk at every site. Recomputing the counters
from rows on demand would make admission linear in table size. A
cross-session check in the engine would need two sessions in one place,
which only a test or the oracle has, so it lives in the oracle and runs in
tests alone.

The teardown audit costs one walk of the session's tables in safe builds,
the same order as the teardown itself, and nothing in unsafe builds. The
agreement holds only between sessions that both made any
out-of-band grant (`Peer.exportObject`), so a scenario grants on both sides
or reserves (`Session.reserveExport`). Revisit the teardown walk if a safe
embedding at scale measures it, or widen the agreement when the Host owns a
relation the sessions do not.

## Evidence

Each check was proved by injecting one defect of the class it claims and
running the session, engine, and driver suites:

| Injected defect | Failures named by |
| --- | --- |
| A stored-resolution hold leaves without lowering `held_rows` | `HeldRowsMiscounted`, at teardown and per fuzz step |
| A received `op:gc-exports` entry of delta one is ignored | `ExportWithoutImport` across the pair harnesses |
| A queued deferred settlement leaves `registry.deferred` raised | `DeferredSettlementsMiscounted` |
| A sent settlement skips its anchored calls and listeners | `SettledAnswerKeepsWork` |
| The whole stored-resolution hold release is omitted, keeping local counts consistent | The complete-release scenario retains more holds than its remaining owners |

Agreement alone cannot detect both peers keeping an unneeded reference.
`test/engine/fuzz/held_resolution.zig` drives stored far-import resolutions
through every owner release and requires zero import and wire retains while
both sessions remain open. Its generated cases vary repeated mentions,
answer owners, release order, profile, and codec. The engine operation
fuzzer also generates resolutions naming existing far imports.

`test/driver/promise_argument_test.zig` checks both release orders after a
Host lifts a stored import whose original retain was parked. The import
survives the first owner release and leaves after the second.

Deferred settlements have focused retry tests. These checks cover the
relations they name, rather than every session counter or every possible
conversation.
