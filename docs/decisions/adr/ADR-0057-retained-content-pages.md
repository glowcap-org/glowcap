---
id: ADR-0057
status: accepted
date: 2026-10-19
tags: ["loam", "hosting", "bindings"]
decision: "A resource's content graph uses ordered bounded pages."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0057 Retained content pages

## Context

Application content can exceed one bounded record. Pinning all pages would make cache capacity scale with graph size, while following capability edges as payload would mix two authority domains.

## Decision

A resource's content graph uses ordered bounded pages. Shared preparation reads through a bounded window and retains the payload and links required by the operation. Replacement commits with the existing managed transaction.

Page links are distinct from capability reference fields. A callback receives its canonical bound-resource context. Receipt replay restores the retained result rather than recomputing content against a changed graph.

## Alternatives and consequences

A single larger record would evade the shared record bound. Pinning every page couples durable size to live memory. A second language-owned preparation loop would duplicate commit and recovery ownership.

The retained snapshot pays an explicit bounded payload and edge copy. It is not an unlimited lazy database view. Missing reads resume through the shared evaluator, and caller cancellation does not bypass physical effect retirement.

## Evidence

Content graph, bounded read-window, reference-field and receipt tests run under `zig build test` and the durable consumer suites. [Storage integration](../../loam/access-storage.md) owns the application contract.
