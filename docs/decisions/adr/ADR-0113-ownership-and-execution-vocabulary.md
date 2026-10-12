---
id: ADR-0113
status: accepted
date: 2026-08-11
tags: [vocabulary, driver, net, c-abi, bindings, public-surface]
decision: "Public names describe owned concepts, not implementation techniques: driver.HostRuntime is the owning native face over the CapTP Host. DialRetry applies retry policy to caller-supplied dial attempts. Low-level framed handles are Connections while CapTP conversations and their terminal refusals are Sessions. The shared-readiness provider model is multiplexed, and the relay package owner is a Runtime. Resident remains the name for long-lived native transport state behind one or more netlayer contracts. Bindings with named send_redeeming results use SendRedeemingResult. Prerelease surfaces move directly with no aliases."
supersedes: []
superseded_by: []
amends: [ADR-0043, ADR-0066, ADR-0067, ADR-0068, ADR-0069, ADR-0072, ADR-0076, ADR-0079, ADR-0081, ADR-0082, ADR-0088, ADR-0090, ADR-0093, ADR-0096, ADR-0097, ADR-0098, ADR-0100, ADR-0102, ADR-0105, ADR-0107, ADR-0109, ADR-0112]
amended_by: []
---

# ADR-0113 Ownership and execution vocabulary

## Context

Public names should describe the owned concept. `PollHost` exposed the wait
primitive instead of the CapTP product it owns. `ResilientClient` owned no
client. Blocking frame shuttles were called endpoints even though `endpoint` is
reserved for transport-bound identity, and the provider ABI used endpoint for
another fact: one readiness source multiplexing stable connection ids. The relay
package owner was called one netlayer while it realizes two profiles. Bindings
disagreed on the result of `send_redeeming`, and the completion loop kept
`Locator` as the name of the netlayer-owned resolver after ADR-0079 selected
`DialResolver`.

## Decision

- `driver.HostRuntime` is the owning, blocking native face over one
  `driver_core.Host`. Polling is an implementation detail of that face, and `Host` is the
  multi-session CapTP product name across the core and bindings.
- `driver.DialRetry` owns a `DialPolicy` and outcome hook and applies them
  through `dial` to a caller-supplied attempt. It is neither a client nor a session owner.
- Binding frame-shuttle handles are `Connection` values, qualified by the
  transport where the language's module structure requires it. A CapTP
  `Session` and a byte connection are distinct. The Host core therefore
  reports `SessionCondemned` when that conversation has terminated and refuses
  further protocol verbs. Transport failures retain connection terminology.
- `MultiplexedResident` is the Zig runtime contract for one readiness
  descriptor and stable connection ids. Its C projection is
  `GlowcapMultiplexedTransport`. Provider entries select STREAM or MULTIPLEXED
  execution. `endpoint` is for an iroh identity, a bound
  address, or another actual transport endpoint.
- The relay archive's provider-only owner is `RelayRuntime` /
  `GlowcapRelayRuntime`, with `glowcap_relay_runtime_new` and
  `glowcap_relay_runtime_release` lifecycle verbs. It is not one netlayer.
- Bindings with named result types return
  `SendRedeemingResult { reply, via }` from `send_redeeming`. Racket returns
  the same pair as idiomatic multiple values. The result may contain an
  ordinary reply with no redeemed exporter, so the shorter adjective
  `Redeemed` would be wrong for some values.
- Completion loops call their transport-specific locator interpreter a
  `DialResolver` and validate it under that name.

`Resident` is concrete, long-lived native state that projects one or more
`Netlayer` contracts. Renaming it to `Transport` would collapse three facts: the
locator-selected transport symbol, the netlayer semantics, and the live
execution state. `Provider` is the artifact/package boundary that composes
profiles and leases that state.

Prerelease surfaces move directly with no aliases. Generated headers and binding
mirrors move in the same change.

## Consequences

The change is vocabulary only. It adds no allocation, copy, branch, or ownership
transition. Lifetime authority is unchanged:
`driver_core.Host` owns session shells and CapTP authority, `driver.HostRuntime`
owns wires and transport execution, residents own native transport state, and
provider leases keep archive callback contexts alive until the driver retires them.

The naming gate and generated-header checks reject stale names. Binding dogfoods
and the full `zig build check` gate prove the coordinated source and generated
surfaces.
