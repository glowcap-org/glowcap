---
id: ADR-0211
status: accepted
date: 2026-10-13
tags: [host, durability, configuration]
decision: "A durable sturdyref survives a restart because the caller keeps its entropy and republishes with it. The Host has no registry durability option and no embedder registry store."
supersedes: []
superseded_by: []
amends: [ADR-0082]
amended_by: []
---

# ADR-0211 Durable names come from caller entropy

## Context

[ADR-0082](ADR-0082-adapter-continuity-and-host-resource-honesty.md) named a
`durable_bootstrap` Host posture whose registry would survive a restart
through an embedder-supplied store. `Host.init` refused it until that store
existed. No store was built, and the option could only fail.

Durable names already survive a restart another way. `Host.publishDurable`
derives the sturdyref from the caller's 16 entropy bytes, so a caller that keeps
those bytes republishes the same name for a new actor. The scenario
"durable publication: a sturdyref issued before a restart still names a live
object after it" in `test/driver/core_host/pairing_test.zig` holds that.
Applications that need durable objects use Loam, which stores the entropy with
the rest of their state.

## Decision

The Host keeps no registry durability setting. `Host.Options` has no
`bootstrap_durability` field and `Host.InitError` has no
`DurableBootstrapUnavailable`. The caller owns persistence of the entropy, and
the sync, no-I/O core owns only that a durable name is a pure function of it.

## Scope (what this does not decide)

Durable peer identity and Loam's storage contracts are unchanged.

## Alternatives Considered

- **Keep the refused arm.** Rejected because an option that only fails is a
  second way to ask for durability that does nothing.
- **Build an embedder registry store.** Rejected because entropy republication
  already gives the same restart guarantee with no store interface in the
  core, and Loam owns durable application state.

## Consequences

`src/driver/core/host/configuration.zig` loses the enum, the field, and the
error. The [known limitations](../../boundaries.md) page describes entropy
republication as the restart path.
