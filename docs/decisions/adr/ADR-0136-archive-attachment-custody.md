---
id: ADR-0136
status: accepted
date: 2026-08-26
tags: [rooms, persistence, attachments, capabilities, history]
decision: "A Rooms archive line retains bounded attachment metadata and an archive-minted content digest when its archive also holds the bytes. Writers stream files through `putFiles`; scoped readers request one file capability through `attachment`; workspace and session checkpoints remain byte-free."
supersedes: []
superseded_by: []
amends: [ADR-0129, ADR-0131, ADR-0132, ADR-0135]
amended_by: [ADR-0140]
---

# ADR-0136 Archive attachment custody

## Context

The member archive retained a file line's caption but erased the fact that the
line carried files. After refresh, the same message silently became text-only.
That was not a blob-retention policy; it was loss of reconstructible message
state. Putting bytes into the checkpoint or line tuple would instead confuse
plain durable state with live capability authority and make every history read
pay the cost of every retained file.

## Decision

Every archive line carries zero to eight attachment metadata records. Each
record contains the original name, media type, byte size, and bounded image
dimensions. The archive parser applies the same file and aggregate limits as a
live message before a record reaches storage. A withdrawal must erase both text
and attachment metadata.

Metadata grants no byte authority. A blob-capable archive mints a SHA-256 digest
while streaming each file through `putFiles`. The digest identifies content in
the line record, while `attachment` returns the scoped capability that grants
access to those bytes. Callers cannot select an existing blob by supplying a
digest to `attachment`. ADR-0140 adds digest as a filter dimension that
authorizes `blob(digest)` only when the facet's current scope already includes a
line that names that digest. A metadata-only line still restores as explicitly
unavailable.

Browser IndexedDB and the standalone file archive store the same canonical line
record and enforce a 512 MiB aggregate blob ceiling. IndexedDB commits its line,
blob rows, replacement cleanup, and byte count in one transaction. File storage
writes content-addressed blobs before appending the line that names them; a
crash can therefore leave only an unreferenced file, which startup removes.
The shared record index reports the exact replacement or eviction in each
commit, so retained-byte admission accounts for the state after that transition.
Withdrawal and eviction remove their unreferenced bytes, and a failed physical
cleanup remains pending for the next archive mutation or startup pruning.

Native and Deno storage stream bounded chunks. The browser materializes one
bounded file because Web Crypto and IndexedDB accept complete browser values;
that allocation stays inside the browser storage adapter. Blob bytes never
enter workspace or durable-session checkpoint JSON.

## Consequences

Room and direct-message history reconstruct file names, types, sizes, layout,
and bytes when the selected archive retained them. Narrowed facets apply their
line scope again when minting a blob reader, so a digest cannot widen archive
authority. Session and browser views fetch archived bytes lazily, and small
images still load on arrival.

## Evidence

`apps/rooms/test/archive/protocol_test.ts` holds memory custody, exact wire bounds, and
withdrawal erasure. `apps/rooms/test/archive/storage_test.ts` proves bytes
survive file-archive restart and obey the byte ceiling. The baseline archive
wire and standalone peer tests fetch retained blob capabilities across OCapN
and process restart. The whole-page and shared-session browser checks recover
and decode files after browser and session restart.
