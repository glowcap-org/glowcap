---
id: ADR-0124
status: accepted
date: 2026-08-24
tags: [c-abi, bindings, session, memory, configuration]
decision: "The C Host applies selective session limits through one versioned, caller-owned GlowcapSessionLimitOptions record. Zero fields preserve the current value; the record includes independent transient outbound and durable sent-answer byte budgets, and every binding projects it as one named options value."
supersedes: []
superseded_by: []
amends: [ADR-0082, ADR-0121, ADR-0123]
amended_by: []
---

# ADR-0124 Versioned session-limit options

## Context

The byte-fed Host originally exposed three positional limit arguments. Adding
the durable sent-answer budget from ADR-0121 would have made four adjacent
integer parameters with different ownership and lifetimes. That surface was
easy to transpose and had no principled extension point. Leaving the durable
budget at its default in C and the bindings would also make the public Host less
resource-honest than the Zig Host it wraps.

glowcap is prerelease, so preserving the positional spelling as a compatibility
shim would retain the ambiguity without serving a released consumer.

## Decision

`glowcap_host_set_session_limits` borrows a
`GlowcapSessionLimitOptions`. The record carries `abi_version`, `struct_size`,
and four selective overrides:

- inbound frame bytes;
- pending-answer queue entries;
- transient outbound bytes; and
- durable bytes retained by sent inbound answers.

Every zero field preserves the Host's current value, and every nonzero field is
copied before the call returns. The record is validated in full before the Host
mutates. Unknown versions, undersized records, null records, and durable budgets
above the core's `u32` capacity fail as invalid arguments. Already-minted peers
keep their own limit snapshot.

Rust, TypeScript, Python, and Racket expose one named options value in their
native conventions. They validate target-width values before crossing FFI and
carry the durable budget independently of transient flow pressure. The public C
record joins the reflected Host layout manifest, so its exact layout and the
function signature participate in the archive fingerprint.

## Consequences

- A future field can extend the versioned record without adding another
  positional parameter.
- C and every binding can tune the durable answer-store budget rather than
  accepting an unchangeable default.
- Configuration costs one caller-owned fixed-size record per call. Session
  construction copies scalar values; steady-state framing, settlement, and
  answer GC gain no allocation, copy, or additional per-peer field.
- The prerelease positional C function and binding methods are removed rather
  than retained as parallel APIs.

## Evidence

The C Host tests pin null, version, size, target-width, selective-update, and
minted-limit behavior. Rust and TypeScript tests and the Python and Racket
dogfoods set transient and durable limits independently. Generated header,
layout, signature, archive-fingerprint, and binding checks keep every mirror on
the reflected declaration.
