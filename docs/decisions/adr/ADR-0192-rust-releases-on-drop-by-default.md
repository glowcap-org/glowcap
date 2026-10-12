---
id: ADR-0192
status: accepted
date: 2026-10-04
tags: [gc, bindings, rust, memory]
decision: "The Rust binding releases a far capability's Host retain when its last Ref clone drops, by default, and the setting belongs to the Host rather than each session. Bindings whose release rides a language finalizer keep ADR-0063's per-session opt-in."
supersedes: []
superseded_by: []
amends: [ADR-0063]
amended_by: []
---

# ADR-0192 Rust releases on drop by default

## Context

ADR-0063 kept distributed GC off by default in every binding, rejecting the
default as "a hidden runtime mutating the session". With it off, every far
reference a session fetches pins an export on the partner, Goblins included,
until the session ends, and a long-lived session reaches its import and export
caps. Rooms turned it on for almost every session it opens.

The rejection fits a finalizer: `FinalizationRegistry`, `weakref` and Racket
will-executors run on their own schedule, maybe never. It does not fit Rust,
whose `Drop` runs at a scope end the reader can see. Releasing on drop is how
Rust releases every resource.

The setting also sat on the session, although a `Ref` belongs to the Host and a
Host-level call has no arrival session to consult.

## Decision

- The Rust Host releases on drop by default. `Host::set_release_on_drop(false)`
  turns it off for outcomes minted afterwards, on every session of that Host.
- `Session::with_gc` is removed.
- TypeScript, Python and Racket keep ADR-0063's per-session `with_gc` /
  `withGc` opt-in, because their release timing is not deterministic.

## Consequences

A Rust application does not pin partner exports by holding nothing. An
application that hands capabilities across its own threads of ownership and
releases them explicitly turns the setting off.

## Evidence

The Rust binding's GC tests exercise release on drop without an opt-in.
