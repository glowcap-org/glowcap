---
id: ADR-0047
status: accepted
date: 2026-10-19
tags: ["access", "grants", "transactions", "loam", "storage", "memory"]
decision: "One Zig planner validates grant mutations and prepares bounded deltas against exact graph and ledger revisions."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0047 Prepared grant mutations

## Context

A storage write can complete after the resource graph or grant state has changed, or fail without revealing whether it committed. Publishing a proposed grant before that outcome would expose uncommitted authority.

## Decision

One Zig planner validates grant mutations and prepares bounded deltas against exact graph and ledger revisions. Preparation copies retained inputs and reserves the relevant graph state before writing. It emits no committed event and publishes no authority.

An exact ticket binds the owner, sequence, base revisions and phase. Confirmed commit installs the prepared delta without allocation or policy re-evaluation. Known-unchanged completion discards it. Unknown outcome retains its memory and reservation and fences protected access until recovery resolves that same ticket.

Resident and loaded grant records use the same evaluator. A source lends one record at a time, and a new lookup refuses while the loan remains open in every build mode. Consumers copy any fields needed beyond release.

## Alternatives and consequences

Rebuilding a transition after storage commits could apply different policy. Copying the whole graph makes cost grow with population. Debug-only borrow stamps permit stale aliases in ReleaseFast. Independent content and grant writes cannot make one atomic owner change.

Cancellation is safe only before physical write submission. Started work must retire before borrowed memory is released. Tickets correlate completion plumbing but cannot make a malicious storage adapter truthful.

## Evidence

Prepared-state, stale-ticket, unknown-outcome, reservation and record-loan tests run under `zig build test`. [Storage integration](../../loam/access-storage.md) owns transaction and recovery procedures.
