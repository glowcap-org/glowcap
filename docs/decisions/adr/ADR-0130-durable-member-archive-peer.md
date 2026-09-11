---
id: ADR-0130
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, persistence, storage, iroh]
decision: "The standalone Rooms archive peer hosts ADR-0129's unchanged `put`/`read` object on a durable v1/Syrup Host. One required state directory retains the Host seed, publication entropy, and a bounded synced JSONL revision log; an operating-system lock grants one live writer, strict startup validation refuses corruption before the final append, and atomic compaction recovers only a torn final row. The peer announces one sturdyref, uses authenticated iroh by default, and keeps cleartext TCP for local development and self-contained checks."
supersedes: []
superseded_by: []
amends: [ADR-0129]
amended_by: [ADR-0131, ADR-0132, ADR-0140]
---

# ADR-0130 Durable member archive peer

## Context

ADR-0129 defines a bounded member-owned archive object and a browser-backed
implementation. A tab can host that object, but its process lifetime and
browser profile are poor custody for a reference that should survive a device
closing. The same object needs a deployable home without turning a directory
server or database account into archive authority.

Durability has three coupled names. The peer identity names who answers, the
publication entropy reproduces the same swiss authority, and the revision
cursor orders the retained records. Restoring only one or two would produce a
familiar-looking endpoint with different authority, or a familiar authority
whose readers can no longer resume.

## Decision

`zig build rooms-archive` runs the native Rust standalone archive peer. Its state
directory is required. `peer.json` retains a 32-byte Host seed and independent
durable-publication entropy. The peer uses them to republish ADR-0129's
unchanged behavior and prints the complete `ROOMS-ARCHIVE-LISTENING`
sturdyref. The Host speaks the v1.0/Syrup floor because the archive contract
needs no Rooms-next wire feature.

The ordinary transport is iroh, whose encrypted QUIC channel proves the node
identity. Discovery is the default because its bare node-ID locator survives
endpoint address changes across restart. Direct-address hints are an explicit
local posture. TCP remains available for self-contained checks and local
inspection. Its announcement is cleartext and makes no peer-identity claim.

`archive.jsonl` begins with a compacted high-water revision and its current
records, followed by one row per later revision. A put validates the record,
appends its next revision completely, syncs the file, and only then applies the
shared `ArchiveIndex` transition in memory. Reads wait for earlier writes, so a
process has one linear revision order.

The resident index keeps at most 5,000 current records. The log compacts after
512 revisions beyond its current snapshot, and the whole file may not exceed
128 MiB. Compaction writes and syncs a same-directory temporary file before
renaming it over the prior snapshot. Startup validates the header, every
record, revision order, capacity, row count, and byte ceiling before serving.
A crash may leave one unterminated final append; startup drops that fragment
and immediately compacts the recovered state. Invalid complete rows refuse
startup.

An operating-system file lock gives one live process custody of a state
directory. A second peer refuses immediately. The kernel releases the lock if
the owner crashes, so no stale PID or lock-file deletion procedure can split
authority after restart.

## Scope

The archive sturdyref can be dialed, enlivened, and handed through ordinary
OCapN code. ADR-0131 lets a Rooms reader select the whole-archive authority as
their recorder and fixes the browser's offline posture. Read-only and scoped
facets, reader-facing handover, and durable attachment homes remain separate
decisions.

The log is bounded durable custody, not a backup system. Eviction is part of
the archive contract, and an operator who needs disaster recovery must back up
the state directory as one unit while the peer is stopped.

## Alternatives considered

- Rewriting the full snapshot on every put makes each small chat line an
  operation proportional to all retained history and was rejected.
- Tolerating any malformed row would silently choose which member history to
  discard. Recovery is limited to the one boundary a crashing append can tear.
- Using the room server's retention backend would couple a member's authority
  to directory policy and would not cover direct messages.
- Making PostgreSQL mandatory would add an account and service boundary
  without improving the capability contract. A later backend can implement
  the same `ArchiveBackend` seam.

## Consequences

The durable peer and the browser backend share record validation, replacement,
eviction, revision ordering, and reads through `ArchiveIndex`. Filesystem code
owns only commit and recovery. Transport code owns only reachability. Neither
can redefine what an archive record means.

The printed sturdyref is bearer authority to read and write the whole archive.
Protect it like the archive contents; share a narrowed facet or revocable share
when a recipient needs less authority.

## Evidence

`zig build rooms-peers-test` proves native identity, exclusive custody,
TCP/direct-iroh restart and signal shutdown of the installed executable.
`zig build rooms-archive-test` proves the application contract, storage
restart, update continuity, torn-tail recovery, strict corruption refusal,
resident and disk bounds, single-writer custody, the v1/Syrup wire profile, and
redemption of the same sturdyref after a process restart. The Rooms server
suite and `zig build check` include that step. ADR-0131 owns the browser
selection proof.
