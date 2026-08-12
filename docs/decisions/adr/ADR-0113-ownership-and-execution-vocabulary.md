---
id: ADR-0113
status: accepted
date: 2026-08-11
tags: [vocabulary, driver, net, c-abi, bindings, public-surface]
decision: "Public names describe owned concepts, not implementation techniques: driver.HostRuntime is the owning native face over the CapTP Host; DialRetry applies retry policy to caller-supplied dial attempts; low-level framed handles are Connections while CapTP conversations and their terminal refusals are Sessions; the shared-readiness provider model is multiplexed; and the relay package owner is a Runtime. Resident remains the name for long-lived native transport state behind one or more netlayer contracts. Bindings with named send_redeeming results use SendRedeemingResult. Prerelease surfaces move directly with no aliases."
supersedes: []
superseded_by: []
amends: [ADR-0043, ADR-0066, ADR-0067, ADR-0068, ADR-0069, ADR-0072, ADR-0076, ADR-0079, ADR-0081, ADR-0082, ADR-0088, ADR-0090, ADR-0093, ADR-0096, ADR-0097, ADR-0098, ADR-0100, ADR-0102, ADR-0105, ADR-0107, ADR-0109, ADR-0112]
amended_by: []
---

# ADR-0113 Ownership and execution vocabulary

## Context

The architecture had settled its ownership boundaries while several public
names still described an implementation, an old migration, or the wrong layer.
`PollHost` exposed the current wait primitive instead of the CapTP product it
owns. `ResilientClient` owned no client. Blocking frame shuttles were called
endpoints even though `endpoint` is reserved for transport-bound identity.
The provider ABI then used endpoint for a different fact: one readiness source
multiplexing stable connection ids. The relay package owner was called one
netlayer while it realizes two profiles.

Bindings also disagreed on the result of `send_redeeming`, and the completion
loop retained `Locator` as the name of the netlayer-owned resolver after
ADR-0079 had selected `DialResolver`.

## Decision

- `driver.HostRuntime` is the owning, blocking native face over one
  `driver_core.Host`. Polling is an implementation detail of that face, while
  `Host` remains the multi-session CapTP product name across the core and
  bindings.
- `driver.DialRetry` owns a `DialPolicy` and outcome hook and applies them
  through `dial` to a caller-supplied attempt. It is neither a client nor a
  session owner.
- Binding frame-shuttle handles are `Connection` values, qualified by the
  transport where the language's module structure requires it. A CapTP
  `Session` and a byte connection remain distinct. The Host core therefore
  reports `SessionCondemned` when that conversation has terminated and refuses
  further protocol verbs; transport failures retain connection terminology.
- `MultiplexedResident` is the Zig runtime contract for one readiness
  descriptor and stable connection ids. Its C projection is
  `PancakeMultiplexedTransport`; provider entries select STREAM or MULTIPLEXED
  execution. `endpoint` remains available for an iroh identity, a bound
  address, or another actual transport endpoint.
- The relay archive's provider-only owner is `RelayRuntime` /
  `PancakeRelayRuntime`, with `pancake_relay_runtime_new` and
  `pancake_relay_runtime_release` lifecycle verbs. It is not itself one
  netlayer.
- Bindings with named result types return
  `SendRedeemingResult { reply, via }` from `send_redeeming`; Racket returns
  the same pair as idiomatic multiple values. The result may contain an
  ordinary reply with no redeemed exporter, so the shorter adjective
  `Redeemed` is not true for every value.
- Completion loops call their transport-specific locator interpreter a
  `DialResolver` and validate it under that name.

`Resident` is retained for concrete, long-lived native state that projects one
or more `Netlayer` contracts. Renaming it to `Transport` would collapse three
separate facts: the locator-selected transport symbol, the netlayer semantics,
and the live execution state. `Provider` remains the artifact/package boundary
that composes profiles and leases that state.

Because pancake is prerelease, the old names are removed rather than retained
as aliases. Generated headers and binding mirrors move in the same change.

## Consequences

The change is vocabulary-only at runtime. It adds no allocation, copy, branch,
or ownership transition. Existing lifetime authority remains where it was:
`driver_core.Host` owns session shells and CapTP authority, `driver.HostRuntime`
owns wires and transport execution, residents own native transport state, and
provider leases keep archive callback contexts alive until the driver retires them.

The naming gate and generated-header checks reject stale spellings. Binding
dogfoods and the full `zig build check` gate prove the coordinated source and
generated surfaces.
