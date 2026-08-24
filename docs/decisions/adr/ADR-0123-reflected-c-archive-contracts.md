---
id: ADR-0123
status: accepted
date: 2026-08-24
tags: [c-abi, bindings, build, packaging, correctness]
decision: "Every separately loaded C archive exposes a fingerprint derived from its reflected function types, public constants, binding-crossing annotations, and canonical public struct manifests. The binding-projected rows in those manifests generate all binding layout expectations. Core, Host, driver, and transport loaders compare their generated value before any ordinary call."
supersedes: []
superseded_by: []
amends: [ADR-0059, ADR-0112]
amended_by: [ADR-0124]
---

# ADR-0123 Reflected C archive contracts

## Context

Transport archives already exposed build-derived fingerprints, but their
identity hashed selected source files. A formatting edit changed the value,
while an unlisted shared layout could change without doing so. The shared
managed-frame layout demonstrated the gap: every archive exchanged it, yet no
single reflected inventory owned both load-time identity and binding layout
generation. The core, Host, and driver archives had no fingerprint at all.

A separately loaded archive must be refused for observable ABI drift, not for
an implementation comment, and every public archive in one binding stack must
answer to the same rule.

## Decision

Each archive has an annotated symbol inventory and one or more canonical
layout manifests. The fingerprint hashes in canonical order:

- the archive family name;
- every public `PANCAKE_*` value, sorted by name (except the fingerprint itself);
- every symbol name and its reflected Zig function type;
- the out-buffer, opaque-pointer, blocking, and language-omission facts that
  control generated FFI crossing behavior; and
- every manifested struct's stable name, type identity, size, alignment, field
  names, field types, offsets, sizes, and alignments.

Implementation sources, comments, omission explanations, and documentation
sections do not enter the value. A behavior-only implementation edit therefore
does not create false binary incompatibility. A callable or layout change
cannot retain the value merely because somebody forgot to bump a version.

The shared manifest includes the complete frame, value, failure, Context,
locator, close, stream-provider, and multiplexed-provider vocabulary. Host,
driver, and each transport add their archive-local public structs. Every row
enters archive identity. Rows that language bindings hand-mirror additionally
enter their layout generator; `cOnlyLayout` marks public C structs that package
APIs consume opaquely and must not reopen a retired binding surface.

`libpancake_ocapn`, `libpancake_host`, and `libpancake_driver` now join every
transport archive in exporting `pancake_<family>_archive_fingerprint`. Rust,
TypeScript, Python, and Racket receive expected values from the ordinary
constant generators and compare each archive before its first operational
call. A missing fingerprint is stale just as a mismatched one is stale.

## Consequences

- Loading a current transport beside a stale core, Host, or driver fails at
  the archive boundary instead of at the first incompatible call.
- Adding a public C struct requires adding it to the owning manifest; that one
  row reaches load-time identity and, when binding-projected, generated layout
  evidence.
- C consumers can perform the same comparison through the exported functions.
  The release packages smoke-test that every separately shipped archive
  exposes its family fingerprint.
- Public numeric and string constants participate automatically, so a changed
  discriminant or limit cannot retain archive identity. Declaration reordering
  does not perturb it.

## Evidence

Generated-header and generated-binding checks hold symbol functions,
fingerprint constants, and layout manifests against the Zig declarations.
Every binding's loader tests exercise a matching archive; focused mismatch
tests pin typed refusal text and expected/actual values. The release-package
consumer smoke resolves each archive fingerprint before accepting a staged
bundle.
