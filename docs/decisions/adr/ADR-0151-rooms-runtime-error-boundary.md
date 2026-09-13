---
id: ADR-0151
status: accepted
date: 2026-09-13
tags: [rooms, rust, runtime, errors, ownership]
decision: "Rooms runtime owners return one typed failure vocabulary; policy refusal, storage, owner retirement, CapTP, runtime operations, worker exit, and cleanup remain distinct until a product boundary renders them."
supersedes: []
superseded_by: []
amends: [ADR-0148]
amended_by: []
---

# ADR-0151 Rooms runtime error boundary

## Context

The shared Rooms runtime supervises durable session commands, grant commands,
directories, rooms, direct conversations, and archives. These owners used to
return `String`. A caller that received one could show it, but could not decide
whether retrying was appropriate or whether storage recovery, owner retirement,
or a policy refusal had occurred without interpreting prose.

The session service already had a typed dispatch error, but placing the shared
vocabulary there inverted the dependency for every owner below the service.
Keeping another enum in each owner would preserve types at the cost of repeated
conversion code and parallel cleanup rules.

## Decision

`rooms_runtime::Error` is the crate-level failure vocabulary. It distinguishes
policy refusals, durable state and storage failures, retired owners, CapTP
failures, other runtime operations, named worker exits, and cleanup that failed
beside an earlier error. The concrete storage adapter remains behind a boxed
error source, so the shared crate does not depend on `rooms-platform`.

Session-command and grant-command replies carry this type. Workers supervised
by the session and their shutdown paths return it too. `Error::fold` and
`Error::retain` keep the primary failure and the cleanup failure as separate
values instead of joining their messages.

The service module re-exports the same type for existing callers. It does not
own a second runtime enum. CapTP behaviors call `Display` only when they produce
a break reason for the remote peer.

## Scope

Protocol failures that are themselves wire values keep their protocol-defined
types. Operator notices also remain separate because a reported condition is
not necessarily the failure of the session that observed it. In particular, a
retired direct route whose transport cannot prove graceful physical cleanup
reports `DirectCleanupFailed` and leaves the shared dispatcher serving sibling
conversations. Whole-session shutdown still returns that cleanup failure to its
owner. Platform service fronts may add errors for listeners, process I/O, and
other effects that do not belong to the shared runtime.

## Consequences

Local and embedding callers can branch on failure class without matching
message text. Storage sources retain their concrete diagnostics through
`std::error::Error::source`, while the runtime crate stays independent of the
native and browser adapters. Adding another runtime failure class now changes
one enum and its edge projections.

## Evidence and gate

Runtime unit tests distinguish refusal, closure, storage, and retained cleanup
by variant. `zig build source-check` rejects the former `Runtime(String)` arm
and `Error::runtime` constructor anywhere under the shared runtime. The Rust
workspace tests exercise session and grant replies on native and browser
callers. The browser trace lifecycle proof closes one direct peer and requires
the sibling room session to remain live after direct-route cleanup.

## Notes

Amends [ADR-0148](ADR-0148-rooms-host-platform-and-services.md), which placed
shared execution below platform adapters and service fronts.
