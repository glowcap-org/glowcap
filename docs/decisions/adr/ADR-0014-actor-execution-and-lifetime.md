---
id: ADR-0014
status: accepted
date: 2026-10-19
tags: ["actors", "vat", "layer", "sans-io", "bindings", "racket", "goblins", "seam"]
decision: "The Vat is a synchronous no-I/O actor layer above the engine."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0014 Actor execution and lifetime

## Context

Applications need local actors and eventual sends without putting a scheduler into the protocol engine. One active ingress must not retain every queue allocation or starve its siblings.

## Decision

The Vat is a synchronous no-I/O actor layer above the engine. Typed actors support near calls, eventual sends, vows and deferred behavior replacement. A Host composes the Vat with session-specific ports rather than making either layer own the other.

The Vat owns bounded, reclaimable batches attributed to an ingress. Admission checks both turn count and retained bytes atomically. Generic drives rotate fairly, and Host batch drives respect each Port's budget.

A hosted actor remains alive through explicit roots owned by publications, Host capabilities, port exports and exact gifts. Queued turns do not root actors. Retirement happens at the outermost turn boundary, and a queued call to a retired target receives the ordinary typed refusal.

A resolver vow lets an application defer its answer. Off-thread completion carries plain data through a bounded mailbox and wake mechanism. Capability transfer and Host mutation stay on the owning thread.

## Alternatives and consequences

A global FIFO permits one ingress to retain all work. A count-only cap misses large messages. Session closure cannot destroy an actor still held through another root. A general thread pool would hide execution policy in the library.

Bindings keep their language's application idioms while consuming the shared Host machinery. A slow behavior still stalls its Host. Separate Hosts supply independent execution.

## Evidence

Actor, Host, ingress-budget and off-turn settlement tests run under `zig build test`. [Architecture](../../architecture.md) describes the ownership seams.
