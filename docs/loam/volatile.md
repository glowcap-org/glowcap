---
type: static
description: How to open Loam's in-memory engine from Zig, C, and Rust, and what its capacity bounds.
audience: human
sources:
  - resource: /src/loam/engines/volatile/
  - resource: /src/c_abi/loam_volatile/
  - resource: /bindings/rust/src/loam/volatile.rs
---

# In-memory operations

The in-memory engine keeps a Loam store in process memory, so it suits tests,
caches, and stores that end with the process. It honors the same transaction
contract as the disk engines, so everything above it runs unchanged.
[Stores, transactions and reads](store.md) covers that contract.

## From Zig

`Volatile` is part of the `glowcap.loam` module, so it needs no extra
dependency. Build it with an allocator, a store identity, and a capacity in
bytes, then open it:

```zig
var engine = try glowcap.loam.Volatile.init(allocator, store_id, 64 * 1024 * 1024);
defer engine.deinit();
const metadata = try engine.open();
```

The engine is synchronous and single-threaded, as the core layer requires.
Drive it from one thread, or put your own lock around each call. Multiple read
transactions may overlap. A write transaction needs exclusive access until
commit or abort, so a write during any transaction and a read during a write
return `Busy`. This keeps borrowed rows valid without copying them.

## From C and Rust

`libglowcap_loam_volatile` is the C archive, with the header
`glowcap_loam_volatile.h`. It exports the same verbs as the LMDB archive.
The open verb takes no path, because there is no directory to name. Each open
makes a new store, so two opens with one identity give two separate stores.
`create=0` returns `GLOWCAP_ERR_NOT_FOUND` since no store exists before it is
created, and `create=1` and `create=2` both create.

Rust enables the `loam` feature and opens `Volatile { identity,
capacity_bytes }` through `Store::open`. [C and Rust](c-and-rust.md) covers
the lifecycle both follow, and
[opening refusals](c-and-rust.md#opening-refusals) lists the return codes.

Storage workers and the Host thread both call the engine, and the engine is
single-threaded. The C archive therefore takes a spin lock around each engine
call. Each call walks memory without I/O, so the lock is held only briefly.

## What the capacity bounds

`capacity_bytes` bounds the keys and values the store holds together. It is
separate from the Store's cache and pending-write limits in `Limits`. Writes
collect in the transaction and are counted at commit, so a commit that would
pass the capacity is refused with nothing applied.

## Where a store ends

A store lives from its open until its release. Release frees every row, and
nothing survives to reopen. Use a disk engine for anything that must outlive
the process.

## Rooms documents

The Rooms runtime keeps its in-memory documents in
`apps/rooms/rust/runtime/src/documents/volatile.rs`. That store holds two
opaque documents, each with a fixed role and replaced whole. Loam's Rust API
stores managed resources and records with declared schemas, and has no place
for a whole opaque document, so Rooms keeps its own store.
