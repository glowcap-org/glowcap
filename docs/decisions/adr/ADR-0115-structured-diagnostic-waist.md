---
id: ADR-0115
status: accepted
date: 2026-08-15
tags: [diagnostics, lifecycle, c-abi, bindings]
decision: "Failures with a live caller use the ordinary error or close barrier; failures with no return recipient enter one typed, bounded diagnostic seam whose schema is shared across the core, C ABI, and bindings, whose storage belongs to an explicit surviving owner, and whose loss is observable."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0115 Structured diagnostic waist

## Context

Glowcap has several ways to preserve failures that cannot be returned. Rust
keeps an implicit-failure journal. Python has separate journals for trace,
transport, and finalizer failures. Racket retains finalizer and trace failures
through different APIs. TypeScript attaches later failures to error objects and
Host state. These mechanisms protect real failure paths, but they give one fact
several shapes and make saturation, ordering, and ownership differ by language.

The synchronous C `last_error` slots solve another problem. They attach detail
to the return code from one failed call and must be read before the next call on
that archive and thread. A peer's retained abort describes a protocol outcome.
The live trace describes protocol activity. None is a journal for callerless
runtime failures, and combining them would make an optional observer part of
control flow.

The C archives are symbol-disjoint. `c_abi/shared` is compiled into each
archive, so mutable state placed there would create several journals while
appearing central in source.

## Decision

A failure goes to the nearest deterministic recipient that still owns the
work. A function returns it, an asynchronous operation settles with it, or an
explicit close barrier reports it. Cleanup failures remain secondary to the
exact first cause. Only a failure for which no such recipient survives enters
the diagnostic seam.

The seam has one fixed-layout schema. A record carries an ordered sequence,
the owning layer, the operation, a lifecycle kind and stable identity, the
typed primary cause, the first typed secondary cause and total secondary count,
and an explicit count of records lost before it. Names and messages are bounded
byte views. An absent field is explicit rather than inferred from an empty
diagnostic string. The C boundary rejects result codes outside the stable public
vocabulary and rejects secondary fields that contradict their consequence count;
foreign causes remain representable by a name with result code zero.

Storage is fixed-capacity and allocated when the owner is configured. Recording
does not allocate, perform I/O, replace an operation's outcome, or invoke
application code. Its synchronization protects only bounded copies and queue
metadata. A full queue drops the oldest record and transfers its saturating gap
count to the new head, so a consumer cannot mistake the surviving suffix for a
complete history. Claiming is atomic and ordered: a claimed record cannot
reappear, and insufficient caller storage does not consume it.

An explicit `GlowcapContext` owns native diagnostic storage and is retained by
each Host built in it. The Context also assigns monotonically increasing,
nonzero lifecycle identities; zero means that no durable owner exists. These
identities are stable only within that Context, so two Hosts sharing one queue
remain distinguishable without retaining or exposing reusable pointer values.
Native Host construction assigns the Host identity; bindings only project it
and cannot create a Host that accidentally omitted this step.
Shared C ABI code owns only the POD schema and reusable queue mechanics. An
asynchronous driver event still has a deterministic
recipient, so its event carries the same primary/first-consequence/count
vocabulary inline rather than duplicating the failure into the journal. A
language failure that occurs after
its Host has genuinely died, such as a foreign finalizer or observer failure,
uses one runtime-local surviving queue with the same schema. The runtime may
retain the exact language exception as an attachment, but that attachment is
not a second cross-language taxonomy. Runtime-local queues retain the same
512-byte aggregate text bound and explicit truncation bits as the native
Context queue; bounding record count alone is not bounded diagnostic storage.

Bindings translate the schema into one idiomatic diagnostic API. They do not
create separate public journals by source. Process owners may drain, log, or
export records according to their own policy. Glowcap assigns no fatal policy
and the absence or failure of a diagnostic consumer changes no protocol or API
outcome.

## Scope (what this does not decide)

This decision does not replace returned errors, rejected promises, broken vows,
close barriers, per-call `last_error`, retained peer aborts, or the live protocol
trace. A failure deferred to the next operation or owning close barrier still
has a recipient and does not enter this seam.

This decision does not choose a logging or telemetry backend. It does not make
diagnostics reliable storage, and it does not retain an unbounded chain of
secondary failures.

## Alternatives Considered

- **Use the live trace for failures**: rejected because tracing is optional,
  lossy observation of protocol facts, while a diagnostic records a runtime
  failure that no caller can receive.
- **Use each archive's `last_error` as a journal**: rejected because the slots
  are thread-local, overwritten by later calls, and intentionally duplicated
  across symbol-disjoint archives.
- **Keep one journal design per language**: rejected because ordering, bounds,
  loss, and lifecycle identity would remain inconsistent at the bindings.
- **Put a process-global queue in `c_abi/shared`**: rejected because every
  archive compiles a separate copy and would therefore create a false central
  authority.
- **Retain every secondary failure**: rejected because an observer must not
  turn repeated cleanup failure into unbounded memory growth.

## Consequences

The shared C vocabulary gains the diagnostic record layout and constants. The
Context gains one bounded queue, one lifecycle-identity allocator, and a
caller-buffer claim API. Driver
failure events preserve the primary and secondary fields instead of flattening
them to one message. Each binding projects that queue and folds its
foreign-only failures into one runtime-local counterpart. Superseded journals
and observer-specific public accessors are removed as their producers move.

The record path is off the wire path and performs no steady-state allocation.
The configured queue pays one fixed slot allocation and one fixed payload
allocation per Context. Tests pin both the record footprint and
the saturation behavior.

## Evidence and gate

Zig tests cover ordered record and claim, primary and secondary preservation,
queue saturation, loss-count saturation, insufficient caller storage, and
lifecycle identity. Generated C and binding layouts come from the Zig
declaration. Binding dogfoods inject the same failure record and assert the same
fields and loss count. `zig build check` owns the complete contract.
