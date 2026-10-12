---
id: ADR-0208
status: accepted
date: 2026-10-11
tags: [rooms, persistence, storage, postgresql, loam, deployment]
decision: "A Rooms deployment keeps three durable stores with one job each. Directory authority lives in versioned single-document files under one state directory. A member session's workspace lives in a Loam store on LMDB with fixed bootstrap metadata. Public-room scrollback is derived retention behind one portable index with two backends: JSONL files for development and PostgreSQL for deployment. This record owns the split and its reasons. Whether the planned Loam content store subsumes the scrollback seam is an open question named here, not answered."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0208 Rooms retention storage split

## Context

Each Rooms surface documents only its own storage shape: the operator guide
lists the directory's files, the deployment guide names the volumes, and the
compose file comments on the database. Nothing else says why three storage
technologies hold one deployment's state. Loam exists to keep capability graphs
durable, so every store in the deployment looks like a candidate for it.

The three stores hold different kinds of things. Directory state is
authority with no record graph: one identity seed, one document of issued
room links, one file per minted capability swiss number. Session state is a
capability graph: held references, custody fields, and effect receipts that
must survive restart exactly. Scrollback is neither: bounded,
capability-free rows derived from traffic the live index already admits,
restored from the backend at startup, and droppable without injuring
identity, grants, or workspace.

## Decision

**Directory authority stays in versioned files.** `rooms.json` carries the
identity seed, from which the Host and its iroh endpoint id derive, and the
issued room links. `operations.json` carries listener and IRC choices, and
each minted capability keeps one swiss-number file. One live process holds
the state directory, backup is stop-and-copy as one unit, and the
version-one document is refused rather than rewritten on any other shape.
Loam's records, edges, and custody machinery buy nothing for a flat key set
with one writer. This state predates Loam hosting. Moving it is unscoped
work, not a defect.

**Session workspace state is Loam's job.** The session store is the one
deployment store that holds a live capability graph: held references,
custody, and effect receipts. That is the problem Loam exists to solve,
saving references and durable names with their records and restoring them
exactly after restart. The `loam/` LMDB directory plus fixed bootstrap
metadata (seed, store identity, owner identity, anchor) is the whole durable
state, and retired file layouts are refused with an explicit operator
reset.

**Public-room scrollback is derived retention behind one seam.** The
portable `Index` owns the policy: 500 kept lines per room, 4,096 lines
across 256 rooms, whole-room eviction of the least recently active room,
applied before any backend sees a write. Two backends serialize the admitted
effects. JSONL files are the development posture. PostgreSQL is the
deployment posture and owns only the `room_lines` schema, chosen for what an
operator-managed dataset wants: a session advisory lease so two servers can
never own one history, no automatic retry of an uncertain commit because
COMMIT may have landed without its answer, backup with `pg_dump` while
running, data checksums from initdb, health-gated startup ordering, and a
password carried by a mounted secret file rather than a command line or
environment. A failed persistence effect ends the server rather than
continuing from storage whose outcome no longer matches the live index.

## Scope

This record owns the current split and its reasons. Whether the planned
Loam content store's message and conversation records subsume the
`room_lines` seam is undecided. The
[storage and budget contract](../../planning/rooms.md) names
that boundary. Private rooms and direct messages are not retained by the
directory at all. Member-owned archives (ADR-0129, ADR-0130) are a separate
store with their own records.

## Alternatives considered

- Loam for the scrollback. The rows are derived, bounded, and
  capability-free. Nothing in them needs a record graph, durable names, or
  custody. Loam's general projections beyond the C, Rust, and browser
  resource profile are not built, and no work is scoped to build them for
  this seam.
- Mandatory PostgreSQL for every history posture. ADR-0130 rejected this
  shape for the archive: an account and service boundary without improving
  the capability contract. A destination that cannot be used stops startup,
  and files remain the development posture.
- SQLite beside the files backend. A second embedded engine next to LMDB
  that loses the managed-service posture (independent backup, health
  checks, checksums) while covering only what files already cover for
  development.
- Memory-only retention. Already the posture without `--state`. A
  deployment that forgets scrollback on every restart breaks the contract
  that saved conversations recover.

## Consequences

One authority per store: the operator and deployment guides describe shapes,
this record owns reasons, and the compose file carries operator mechanics. The
history seam keeps its two-backend shape, so any later store, including a Loam
projection if one is ever built, is a backend change behind the same index
rather than a protocol or deployment change. Naming the open boundary states
whether scrollback is in the persistence plan's scope.

## Evidence

`zig build rooms-rust-test` runs the Rooms cargo workspace natively: server
state documents, the file history backend, index policy bounds, session
platform storage, and the shared persistence-failure contracts. `zig build
rooms-server-test` proves the hermetic server and UI contract behavior.
`zig build rooms-postgres-test` proves the installed server against a live
PostgreSQL: exclusive custody against a rival server, restore across
restart, edits, withdrawals, and integrity refusal. `zig build
rooms-peers-test` proves server and session identity stability across
restart and signal shutdown.
