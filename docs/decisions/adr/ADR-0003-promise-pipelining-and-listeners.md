---
id: ADR-0003
status: accepted
date: 2026-10-19
tags: ["pipelining", "op-listen", "queue", "fifo-drain", "syrup-decompose", "listener-fire", "driver", "c-abi"]
decision: "A pending answer is a send target."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0003 Promise pipelining and listeners

## Context

Waiting for each result before sending the next call adds network round trips. A promise also needs one authority for queued calls, shortening, settlement and reclamation.

## Decision

A pending answer is a send target. The session owns its bounded FIFO of pipelined calls and listeners, and the engine drains it through exact-incarnation resolution links. A promise reference names one answer position. Structural projections remain explicit operations with their own answer lifetimes.

Caller APIs accept a capability or promise through the ordinary send operation. Applications do not allocate protocol positions or decode resolver callbacks. Received promise listeners and Node forwarding share session-owned resolver machinery.

The baseline and next profiles render their own listener forms. Next pairs an answered operation with its required settling listen and installs one private shortening subscription per received remote promise. Preparation is atomic, so allocation failure cannot publish half a required pair.

## Alternatives and consequences

An unevaluated path inside a promise reference would spread interpretation into validation, accounting and GC. An engine-owned shadow queue would duplicate session state. Separate public pipeline and send verbs would make the efficient path harder to choose.

Overflow refuses explicitly. Resolution cycles break their dependents. GC and close release the queues and retains owned by the affected answer. A racing callback can retire only its own claim.

## Evidence

Session, engine, actor and binding scenarios exercise pipelining, listener races, both profiles and failure cleanup. `zig build test`, `zig build oracle-check` and the checks in [community review](../../community-review.md) establish their respective scopes.
