---
id: ADR-0078
status: accepted
date: 2026-07-12
tags: [bindings, c-abi, dial, netlayer, layer-separation]
decision: "A byte-fed dial is a thin interpreter over the core resolver: it marshals posture, calls pancake_host_plan_dial, and opens the generic host_port, peer_id, signaling, or rendezvous shape returned. A native binding sends archive-owned shapes through the generic driver and its registered providers; its composition root may install an optional sidecar or an explicit signaling/rendezvous channel, but never re-derives transport policy. model.transport owns the one typed symbol-to-shape mapping. No binding carries transport grammar, direct-address rules, peer-id reachability policy, or dial error strings. pancake_host_plan_accept is the symmetric signing-plan resolver over a provider-declared designator scheme."
supersedes: []
superseded_by: []
---

# ADR-0078 Dial is a core-resolved plan; bindings are thin interpreters

## Context

Every binding (TypeScript, Python, Racket, Rust) carried its own dial
dispatcher: a switch on the locator's transport that split the host:port
designator, validated the direct-addresses hint, chose the peer-id reachability
posture, and crafted the error strings. Four copies of the same protocol
policy, in four languages, free to drift. Worse, the two dial entries diverged:
a top-level `connect` opened inline, while a three-party handoff redeem went
through the DIAL action and a separate executor, so the same policy was written
twice even inside one binding.

The policy already lives in the core. `dial_plan.planDial`
(`src/driver/core/dial_plan.zig`) resolves `(transport, designator, hint,
posture)` to a plan: `host_port`, `peer_id` with addresses and reach,
`signaling`, or `rendezvous`, plus typed errors. `model.transport.Known`
exhaustively maps transport symbols to those shapes. A plan tag names the host
integration required, not which provider implements it. The resolver was
exposed over the C ABI as `pancake_host_plan_dial` on the driver tier
(ADR-0072), but no binding called it: each re-derived the same decisions.

This engages the first principle that the correct path is the easy path, and
the layer boundary: dial dispatch, grammar, and reachability are protocol
policy, which belongs in the core. A binding is an adapter that owns I/O, not
policy.

## Decision

A binding's dial is a thin interpreter over the core resolver. It does three
things: marshal the posture policy (redeem, explicit, or explicit-none), call
`pancake_host_plan_dial`, and execute the returned integration shape. Native
archive-owned shapes enter the generic driver after any optional sidecar has
registered its provider; explicit signaling and rendezvous integrations open
their byte channel at the composition root. No binding carries transport
grammar, the hint rule, the reachability decision, or dial error strings.

`connect` and handoff-redeem are one path. Both funnel through the same
resolve-then-open executor; the connect side-door that opened inline is gone.
A DIAL action carries only `ticket`; the binding clones the complete typed
locator projected by `pancake_host_pending_dial` and resolves through
`plan_dial` exactly as `connect` does: no URI re-parse and no discarded hint.

The resolved plan is the transitory type that crosses the ABI:
`PancakeDialPlan`, a plain-data description of what to open. It is a reified
command, and the binding is its interpreter. The resolver and the C shim
(`src/c_abi/driver/mod.zig`, `pancake_host_plan_dial`) own the policy and the
error wording, so a binding surfaces the core's message and writes none of its
own.

## Accept (sibling of dial)

`planAccept` / `pancake_host_plan_accept` is the accept-side resolver: given
`(designator_scheme, server_designator, accepted_local_addr)` it returns an
`AcceptPlan`: the designator and direct-addresses hint the accepted session
signs. The provider declares the scheme when it registers; the Host never
recovers semantics from a closed transport-name table. Native listeners call
the resolver through their generic driver path. An embedder that explicitly
owns a byte-fed listener passes that provider declaration before
`pancake_host_session_open_accepted`; it does not choose signing bytes itself.

## Native Zig dial admission

TCP host:port selection for the TCP profiles is one pure helper,
`model.uri.tcpConnectHostPort`. Both `driver_core.planDial` (bindings / C ABI)
and `tcp.DialResolver.resolve` (completion loop / blocking residents) call it.
Keyed-tcp and iroh designators are refused with `PeerKey.fromDesignator` in
`planDial` before any binding opens a channel; DialResolvers keep the same
predicate so a doomed dial never touches the network on either spine.

## Scope (what this does not decide)

- **Byte I/O stays outside the core.** A byte-fed embedder interprets the plan
  and opens its explicit channel. The native driver instead dispatches to its
  registered provider and owns the I/O. Both preserve ADR-0072's sans-io core.
- **Consumer-injected transports.** `planDial` is closed over pancake's typed
  locator vocabulary; an unknown scheme is a typed error. A consumer-supplied
  byte-fed transport can still open a Host session directly, but extending the
  resolved-plan vocabulary is an explicit protocol/API decision.

## Alternatives Considered

- **A per-binding transport registry** (each binding holds a scheme-to-transport
  table). Rejected: it re-homes the dispatch in every binding instead of
  removing it, and the policy (grammar, reachability) still duplicates four
  ways.
- **A resolver the binding calls but then re-dispatches on.** Rejected: it
  leaves the binding re-deciding after the core already decided, and the connect
  side-door survives.

## Consequences

- Adding or changing dial grammar, reachability, or error policy is a core
  change in `dial_plan.zig` and the shim, inherited by every binding. A new
  provider artifact can require one composition-root registration, but never a
  binding-local policy dispatcher.
- Each binding mirrors `PancakeDialPlan` (a 56-byte C struct) with a layout pin
  or assert: generated for TypeScript (`tools/gen/binding/ts_abi.zig`), a `ctypes`
  `_pin_layout` in Python, a `pin-layout!` cstruct in Racket, a `const` assert
  in Rust. Rust cfg-gates the peer-id plan fields and the `DIAL_REACH_*`
  constants so the tcp-only build stays dead-code clean.
- Generated FFI and layout checks hold `PancakeDialPlan` and
  `pancake_host_plan_accept`; native binding fronts reach transport dispatch
  through the generic driver rather than carrying a parallel registry.
- The DIAL action no longer hands a consumed locator to the bindings; the dead
  field, its read, and its forward dropped from each binding's action drain.
- Verified by the per-binding dogfoods plus the `*-keyed-tcp-restart` and
  `*-iroh-redeem-posture` interop steps: real tcp and iroh dials, including a
  three-party redeem under a configured posture, run through the resolved plan.

## Notes

ADR-0072 (the driver tier over the C ABI: the byte-fed host and its action
queue) and ADR-0076 (the loop-fed host bridge) are the lineage; this record
settles the binding-facing dial surface over that tier.
