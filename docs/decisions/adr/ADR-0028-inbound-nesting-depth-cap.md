---
id: ADR-0028
status: accepted
date: 2026-06-04
tags: [session, limits, resilience, security, model]
decision: "Inbound argument-tree nesting is bounded by `SessionLimits.max_nesting_depth` (default 64). The recursive validate / install walk fails loud with `NestingTooDeep` → `resource_exhausted` abort instead of overflowing the native stack; `view.toOwned` and `model.argumentsEqual` carry an independent fixed depth ceiling as a model-layer backstop."
supersedes: []
superseded_by: []
---

# ADR-0028 Inbound nesting-depth cap

## Context

The OCapN value tree is recursive — `list` / `set` / `tagged` arguments nest
arbitrarily ([ADR-0021](ADR-0021-ocapn-value-tree-breadth.md)) — and every
inbound frame is attacker-controlled until validated
([First Principles](../../../AGENTS.md#first-principles): resilience). The
session's validate and install walks recurse one native-stack frame per nesting
level, and the codec projects nested containers lazily, so a single small frame
carrying a few KB of nested `[` markers drives unbounded recursion: a one-packet
native-stack overflow (a crash, not a typed error). [ADR-0025](ADR-0025-session-table-cap-policy.md)
bounds partner-driven table *breadth* but says nothing about tree *depth*.

## Decision

`SessionLimits.max_nesting_depth` (default 64) in
[`src/session/mod.zig`](../../../src/session/mod.zig) bounds inbound
argument-tree depth. The recursive `validateInboundArguments` /
`installIntroducedImports` walkers thread a depth counter and return
`Error.NestingTooDeep` past the cap;
[`src/engine/abort_projection.zig`](../../../src/engine/abort_projection.zig)
projects it to a `resource_exhausted` `op:abort` with `close = true`, the same
fail-loud-and-close posture as the ADR-0025 caps (the partner's frame is
well-formed but exceeds the resource budget). Because validation runs before any
materialization, a malicious deep frame is rejected before it can be owned or
queued.

As a model-layer backstop independent of session policy,
[`src/model/view.zig`](../../../src/model/view.zig) `toOwned` (`max_owned_depth`)
and [`src/model/equality.zig`](../../../src/model/equality.zig) `argumentsEqual`
(`max_equality_depth`) carry their own fixed ceiling (256, well above the
session cap), so a direct materialization or comparison that skipped session
validation also fails closed rather than overflowing. Conformant wire data,
already bounded to 64 by validation, never reaches these ceilings.

## Scope (what this does not decide)

- **Outbound depth.** pancake builds its own outbound trees, so the cap bounds
  inbound (partner-driven) depth only — symmetric with ADR-0025's outbound-table
  exemption.
- **Per-deployment tuning.** The default 64 is generous for honest workloads;
  per-deployment tuning of the limit is an adapter concern.
- **Iterative rewrite.** The walkers stay recursive-with-a-bound; converting to
  an explicit work-stack is not required once the depth is bounded.

## Alternatives Considered

- **Leave the walk unbounded.** Rejected: a one-frame stack overflow is a remote
  crash; attacker-controlled recursion must be bounded where the data is
  validated.
- **Bound only at decode.** Rejected: the codec projects nested containers
  lazily and does not itself recurse, so the depth must be bounded in the
  consumer that walks it.
- **Reuse `protocol_error`.** Rejected: a deeply-nested frame is
  structurally valid but over-budget, so `resource_exhausted` ("back off") is the
  honest kind, consistent with ADR-0025.

## Consequences

- `SessionLimits` gains `max_nesting_depth`; the session error set gains
  `NestingTooDeep`, projected to `resource_exhausted`.
- Evidence: the deep-nesting fail-closed (and at-cap accept) case in
  [`test/session/session_test.zig`](../../../test/session/session_test.zig).

## Notes

- [ADR-0025](ADR-0025-session-table-cap-policy.md) owns the
  `resource_exhausted` cap taxonomy this extends from table breadth to tree
  depth; [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) owns the recursive
  value-tree shape that creates the surface.
