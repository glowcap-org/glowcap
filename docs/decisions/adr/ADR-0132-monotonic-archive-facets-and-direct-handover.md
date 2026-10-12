---
id: ADR-0132
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, persistence, browser, security, handoff]
decision: "The archive object adds a synchronous `narrow` verb that intersects exact record filters and can only preserve or remove write authority. Rooms uses it to hand the other member of a direct conversation a read-only facet over that direct line. The receiving tab validates the exact directory and conversation scope before bounded retention, requires an explicit one-shot read or give-back, attributes the sender's archive account separately from live traffic, and releases every imported occurrence on consumption, refusal, session loss, or directory leave."
supersedes: []
superseded_by: []
amends: [ADR-0129, ADR-0130, ADR-0131]
amended_by: [ADR-0136, ADR-0140]
---

# ADR-0132 Monotonic archive facets and direct handover

## Context

A member archive (ADR-0129) is passable, but its whole object can read and write
every record. ADR-0131 lets the browser select that bearer as its recorder and
keeps it below presentation state. Giving the same bearer to another member
would grant unrelated conversations and mutation authority.

The narrowed object must remain an ordinary capability on the shipped
v1/Syrup floor, so a method that answers a capability returns its new actor
during the call turn. Deferring actor creation through an asynchronous backend
operation would turn the answer into data instead of a projected reference.

## Decision

The archive behavior adds `narrow(filter, access)`. The filter uses the same
bounded exact dimensions as `read`: source, generation, record kind,
conversation kind, directory, and conversation. A narrowed read intersects its
request with the facet's filter. Conflicting dimensions return an empty page.
An omitted dimension cannot widen the facet. A facet created from a read-only
facet cannot regain write authority. `put` succeeds only on a read-write facet
whose filter matches the record.

`narrow` validates its arguments and synchronously spawns the forwarding actor
on the current session. One session may mint at most 256 facets over its
lifetime. Release does not refill that budget because actor churn still spends
monotonic export positions. Storage remains behind `put` and `read`. Narrowing
does not call or copy a backend. The same behavior runs in the tab and
standalone archive peer.

The conversation details card offers one action for a direct line. It waits for
record writes already queued by that tab, asks the selected recorder for a
read-only facet scoped to `line`, `direct`, the directory identity, and the
other member's current directory name, then hands that occurrence over the
direct session. A selected archive peer that is unavailable refuses the action.
Rooms never substitutes the device archive or sends the whole-archive bearer.

The receiving tab accepts the occurrence only during its arriving session turn.
Before retaining it, the tab validates that the directory is the live directory
filing the offer and that the conversation is the name the directory currently
granted this receiver. It keeps at most 16 pending offers. The details card lets
the reader read one or give it back without reading.

A read walks bounded pages up to the archive's total-record ceiling. Successful
records enter the existing conversation under dividers that name the sender,
archive source, and conversation generation. Their `mine` flag is cleared
because it described the sender-recorder's viewpoint. The records do not become
live traffic or this receiver's archive writes. After one successful read, the
tab releases the occurrence and removes the offer. Refusal, explicit give-back,
directory leave, and an open owner session's cleanup release it too. A closed
owner session marks the offer unavailable because that session already reclaimed
its imports.

## Scope

This decision ships read-only handover for one direct conversation. It does not
add room, standing, multi-conversation, or durable share links. A live facet is
not revocable independently of its hosting session. Attachment metadata follows
line records through a facet, and the facet scopes each blob reader to its
owning line. ADR-0144 settles the deferred combination of several archive
accounts into one evidence-backed view.

## Alternatives considered

- Passing the whole sturdyref was rejected because it grants unrelated reads,
  writes, and durable authority when the action names one conversation.
- Trusting the sender's scope label was rejected because the receiving edge can
  validate both dimensions before it keeps the imported occurrence.
- Automatically reading an arriving facet was rejected because accepting a
  capability and disclosing its records are separate choices.
- Copying received records into the receiver's archive was rejected because it
  would turn somebody else's account into local history and lose provenance.
- Returning a promise from `narrow` was rejected because projected capability
  answers are created synchronously during the current CapTP turn.

## Consequences

Archive attenuation is monotonic in both record scope and access. The product
surface exercises ordinary three-party handoff without retaining a whole bearer
or teaching the directory about message history. A recipient has a bounded,
visible custody choice and every terminal path has an explicit release owner.

Long-lived or revocable sharing needs another authority shape.

## Evidence

`apps/rooms/test/archive/wire_test.ts` proves nested filter intersection,
read-only refusal, scoped write authority, no access widening, bounded whole
reads, and the facet mint ceiling over the Goblins-compatible v1/Syrup profile.
`zig build rooms-web-archive` drives two
browser profiles and a standalone iroh archive peer: one member records a line,
hands only its direct-conversation facet to the other, and the recipient reads
and returns it under separate attribution. The same check then proves durable
recovery and visible peer loss without delivery fallback.
