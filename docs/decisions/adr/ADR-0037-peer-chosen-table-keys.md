---
id: ADR-0037
status: accepted
date: 2026-10-19
tags: ["foundation", "session", "engine", "security", "performance"]
decision: "Every session table declares who chooses its keys."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0037 Peer-chosen table keys

## Context

A table indexed by untrusted positions faces a different collision risk from a table indexed by positions this process allocates. Independently compiled archives also cannot safely share an implicit module-global secret.

## Decision

Every session table declares who chooses its keys. Locally selected keys use their direct identity representation. Peer-selected keys hash under a session-derived secret multiplier and a public finisher. A peer-selected byte name (a swissnum, a gift id, a cached sturdyref) hashes under SipHash keyed by a bearer secret the Node derives beside the multiplier under its own domain (`foundation.bearer_table`), because a multiplier mixes words and a name is bytes of the peer's chosen length, and because what a peer learns about one table's buckets must say nothing about the other's. The owner holds each secret once and hands it to the table's verbs.

A compound key declares its identity words, and equality and hashing use those same words. A non-injective fold cannot stand in for the full identity. The Node supplies the session's secret explicitly from its owning identity and peer handle.

## Alternatives and consequences

A process-global variable would become a separate authority in each linked archive. A general-purpose hash adds unnecessary work to these small declared keys. Keying both sides of a relation would charge locally controlled positions for an adversary that does not choose them.

This is collision resistance for the selected table contract, not a cryptographic authentication primitive. It does not replace table capacity limits or justify accepting an invalid protocol position.

## Evidence

Session table, compound-key and independently linked archive tests run under `zig build test`. [Performance budgets](ADR-0009-performance-budgets.md) constrain the measured hot paths separately.
