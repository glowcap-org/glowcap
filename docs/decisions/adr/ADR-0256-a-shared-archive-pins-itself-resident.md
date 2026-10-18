---
id: ADR-0256
status: accepted
date: 2026-10-18
tags: [c-abi, lifecycle, threads]
decision: "Every libc-linked shared archive pins itself resident when the loader maps it, so an embedder's close never unmaps code a detached worker thread is still leaving."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0256 A shared archive pins itself resident

## Context

The transport runtimes and the driver loop each own a `std.Io.Threaded`. It
detaches its worker threads, and its `deinit` returns when their wait group
finishes: a worker's final wake runs after that, still in the archive's code.
An embedder that closes every FFI library at teardown (Deno drops its
libraries before the process exits) unmaps that code while the worker is
leaving it, and the worker faults. On one core the window is the embedder's
whole teardown: the worker is preempted right after its wake and runs again
only once the library is gone. The language bench pinned to one core showed
it as an exit-time `SIGSEGV` of the Deno client, with the faulting address
inside the just-unmapped TCP archive.

Joining the workers is not available to the archive: the standard library
owns them. Nothing the archive does at release can make an embedder keep it
mapped, so the archive has to say so itself.

## Decision

A shared archive that links libc emits one hidden loader entry
(`src/c_abi/shared/archive_pin.zig`, reached through the shared C ABI root)
that promotes `RTLD_NODELETE` onto its own already-loaded object with
`RTLD_NOLOAD`. Closing the library then drops the embedder's handle and
nothing else. Linking libc is where the loader's verbs live and is already
what every thread-owning archive does (`build.zig` names why), so the one
condition covers the one hazard. A libc-free archive runs nothing after its
last call returns and emits no entry. A static archive is part of its
executable and emits none either.

## Scope (what this does not decide)

The embedder's handle keeps its own lifetime: a close still invalidates the
symbols it held. Nothing here changes when a Threaded worker exits, only that
its code stays mapped until it does. Windows is not implemented.

## Alternatives Considered

- **`-z nodelete` at link time**: the same flag, declared statically. Rejected
  because the pinned `std.Build` exposes no way to pass it.
- **Join the workers at release**: the cause's own fix. Rejected because the
  standard library detaches them and owns their exit, so it is an upstream
  change.
- **Pin from each `Threaded` owner's constructor**: explicit, but six call
  sites and a per-archive check. Rejected because residency is a property of
  the artifact, not of one call.

## Consequences

`src/c_abi/shared/mod.zig` references the entry module, so every archive root
inherits it. `tools/check/archive_resident.py` runs at every libc-linked ELF
archive install the build host can load (`installArchive` and the two sidecar
archives): load, close, ask the loader. macOS runs the same entry unchecked.

## Evidence and gate

`tools/check/archive_resident.py` on each installed libc-linked ELF archive,
part of `zig build`. The language bench pinned to one core
(`zig build bench-langs -- --smoke --pin=2,3`) runs its Deno client clean.
