---
id: ADR-0027
status: accepted
date: 2026-10-19
tags: ["session", "engine", "actors", "driver", "c-abi", "security", "gc", "wire-delta"]
decision: "Export rows distinguish their local baseline from wire-held authority."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0027 Wire retains and export admission

## Context

Reserving an export position is a local naming act. A partner must not gain authority by guessing that position before it has received a grant. Session machinery also holds imports that an application cannot release on its behalf.

## Decision

Export rows distinguish their local baseline from wire-held authority. A partner may address an export only after a wire reference or explicit grant establishes its held share. Reservation alone grants nothing.

Import rows record the retains owned by session machinery, including listeners, resolver callbacks and shortening links. An application's release is validated against the remaining share. GC validates all deltas before applying them and refuses underflow.

## Alternatives and consequences

Random positions would obscure a missing authorization check rather than fix it. Lazy minting would split the eager identity already returned by the public ABI. Separate retained-count maps or a special floor for every listener case would multiply authorities and add fallible inserts to commit paths.

Locally selected positions can remain dense without becoming guessable authority. Releasing the last application retain does not remove a row still owned by protocol machinery, and protocol cleanup retires only the retains it owns.

## Evidence

Grant-before-use, guessed-position, mixed-retain and GC-underflow tests run under `zig build test` and `zig build oracle-check`.
