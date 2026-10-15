---
id: ADR-0216
status: accepted
date: 2026-10-13
tags: [rooms, persistence, storage, postgresql, loam, deployment]
decision: "PostgreSQL leaves Rooms. Kept public-room lines live in JSONL files under `history/` in the server's state directory, or in memory when there is no state directory, and the server has no separate storage destination option. The content records of the Rooms plan take the kept lines over when they land, with the kept-lines limits becoming the public room's content quota. A deployment backs up a stopped state volume as one unit, and a live snapshot of a running store is not built."
supersedes: []
superseded_by: []
amends: [ADR-0208]
amended_by: []
---

# ADR-0216 Rooms retention lives in files until content records take it over

## Context

ADR-0208 split a Rooms deployment's durable state into three stores and left
one question open: whether the Loam content records planned for Rooms would
take over the public-room scrollback seam. The Rooms plan answers it. Every
room's conversations and messages become content records under the room's
owner, so the kept-lines store would be a copy of those records with its own
eviction policy.

That answer changes what PostgreSQL is for. It had one job in Rooms, the
`room_lines` table behind the retention index, and the job is ending. Keeping
it until then means carrying a database service, two client crates, a mounted
secret, an image pin with its update rules, an opt-in proof, and a live dump
procedure for one derived table: a second deployment posture for one kind of
room, paid by every deployment on every start.

## Decision

**PostgreSQL leaves Rooms now.** The file backend is the retention store. With
`--history` on, a server keeps listed rooms' lines in JSONL files, one per
room, under `history/` in its state directory, and in memory for the life of
the process when it has no state directory. The `--storage` and
`--storage-password-file` options and their environment forms are gone: one
state directory is the whole durable location of a directory server, and a
second directory for lines was only ever the alternative to a database URL.
The index policy, eviction order, startup validation, and the rule that a
failed persistence effect ends the server are unchanged.

**Content records take the lines over.** When the Rooms plan's content seam
lands, kept lines are content records under the room's owner, the kept-lines
limits become the public room's content quota, and the file store is deleted
with its consumers. Until then the file backend is the retention store, and
nothing is built to bridge the two.

**Backup is a stopped volume on one host.** A deployment backs up its
directory and session state volumes while the stack is stopped, each as one
unit, which is how those two volumes were already kept. Kept lines ride in
the directory state volume. A live snapshot of a running store is not built.

## Scope (what this does not decide)

Directory authority stays in versioned files and the session workspace stays
in its Loam store, as ADR-0208 decided. Content records on managed
containment are not built. An online copy of a running store is not built.
Running a Rooms directory on more than one host is not supported.

## Alternatives Considered

- **Keep PostgreSQL until content records land.** Rejected because every
  deployment would keep minting a secret, pulling an image, and following a
  dump procedure for a seam that is being deleted.
- **Move the lines to a Loam projection now.** Rejected because the lines are
  derived and capability-free, as ADR-0208 found, and content records make a
  projection of them unnecessary.
- **An online backup command over the LMDB live copy.** Not built. The
  derived lines are droppable, and the two volumes that hold authority were
  already stopped-copy. A live copy is a Loam feature for the day a store
  needs one, not a Rooms procedure.

## Consequences

The server config, history seam, Rust workspace manifests, compose file,
deployment command and its checks, devcontainer pins and update rules, build
steps, and the dependency, operating, deployment, and shipped text lose
everything that existed for PostgreSQL in one change. The deployment command
manages two volumes and no secret. The operating guide's known limitations
record the one-host, stopped-volume backup posture.

## Evidence and gate

`zig build rooms-rust-test` holds the server config, which refuses
`--storage` as an unknown option, and the file backend's restore, repair, and
limit tests. `zig build glowcap-host-test` proves the deployment command over
two volumes with no secret. `zig build rooms-peers-test` restarts the
installed server with its history in the state directory.

## Notes

ADR-0208 keeps the directory and session decisions and the retention index.
ADR-0130 rejected a mandatory database for the member archive for the same
reason this record retires it from the directory.
