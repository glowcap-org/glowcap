---
id: ADR-0049
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "actors", "memory", "hosting", "lifetime", "rooms"]
decision: "Record-backed actors attach to the existing Host and Vat."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0049 Record-backed hosting

## Context

A large durable graph cannot require a live actor for every record. A live capability also cannot survive runtime teardown merely because its numeric handle was stored.

## Decision

Record-backed actors attach to the existing Host and Vat. Activation restores needed records and local capability edges lazily within configured bounds. Mutation replies remain withheld until their storage transaction commits.

A live hosting lifetime has its own transactionally advanced restart marker. The Store opening incarnation fences storage writers and does not stand in for a Host lifetime. Restarting a Host within one Store opening still retires the prior live authority.

Ordinary durable save requests refuse live-only capabilities. Exact live custody uses the separately bounded runtime recipe mechanism. Advancing a lifetime marker performs no population-sized scan.

## Alternatives and consequences

Eager activation would make startup memory proportional to graph size. A Store incarnation alone misses a runtime restart within that opening. Serializing Host handles lets reused numeric identities acquire the wrong authority. Rewriting every live row at restart would make restart work depend on population.

Lazy hosting keeps runtime occupancy distinct from retained graph size. It does not make pending network messages durable or restore a seat, upload or other live-only object after its lifetime ends.

## Evidence

Cold activation, commit-before-reply, lifetime restart and stale-reference tests run under `zig build test` and the disk-engine suites. [The managed session guide](../../rooms/session.md) describes production use of these lifetimes.
