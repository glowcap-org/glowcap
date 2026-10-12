---
id: ADR-0078
status: accepted
date: 2026-07-12
tags: [bindings, c-abi, dial, netlayer, layer-separation]
decision: "A byte-fed embedder may resolve a dial through glowcap_host_plan_dial and interpret its generic host_port, peer_id, signaling, or rendezvous result without re-deriving core policy. Native bindings do not project that plan: they pass typed locators through the generic driver to registered transport packages, which own locator interpretation and concrete I/O. The accept side resolves inside glowcap_host_session_open_accepted: the embedder passes the provider-declared designator scheme and listener facts, and the Host derives, retains, and signs the locator itself, never displacing one the embedder explicitly published."
supersedes: []
superseded_by: []
amended_by: [ADR-0112]
---

# ADR-0078 Dial is a core-resolved plan. Bindings are thin interpreters

> **Native-provider amendment (ADR-0112).** Native bindings pass a typed locator
> to the generic driver through the `libglowcap_driver` provider seam. Each
> registered transport package owns its locator interpretation and concrete I/O.
> The generic binding runtimes therefore expose neither `GlowcapDialPlan` nor its
> shape, reach, and posture constants. `glowcap_host_plan_dial` is the primitive
> for a direct byte-fed C embedder that owns the channel.

## Context

A per-binding dial dispatcher (TypeScript, Python, Racket, Rust) switches on
the locator's transport, splits the host:port designator, validates the
direct-addresses hint, chooses the peer-id reachability posture, and crafts the
error strings. That is four copies of the same protocol policy in four
languages, free to drift. If a top-level `connect` opens inline while a
three-party handoff redeem goes through the DIAL action and a separate
executor, the policy is also written twice inside one binding.

The policy lives in the core. `dial_plan.planDial`
(`src/driver/core/dial_plan.zig`) resolves `(transport, designator, hint,
posture)` to a plan: `host_port`, `peer_id` with addresses and reach,
`signaling`, or `rendezvous`, plus typed errors. `model.transport.Known`
exhaustively maps transport symbols to those shapes. A plan tag names the host
integration required, not which provider implements it. The resolver is exposed
over the C ABI as `glowcap_host_plan_dial` on the driver tier (ADR-0072), so a
binding has no need to re-derive its decisions. Dial dispatch, grammar, and
reachability are protocol policy, which belongs in the core. A binding is an
adapter that owns I/O.

## Decision

A byte-fed embedder's dial is a thin interpreter over the core resolver. It
marshals posture policy, calls `glowcap_host_plan_dial`, and executes the
returned integration shape. No such embedder needs to carry transport grammar,
the hint rule, the reachability decision, or dial error strings.

A native binding takes the provider path added by ADR-0112 instead. Its runtime
passes the complete typed locator through `libglowcap_driver`. The registered
transport package interprets the locator and owns the concrete dial. Generic
runtime code knows only providers and connectors, never concrete transports or
the byte-fed plan vocabulary.

`connect` and handoff-redeem are one path. Both funnel through the same generic
driver and registered provider. A DIAL action carries only `ticket`. The binding
clones the complete typed locator projected by `glowcap_host_pending_dial` and
resolves through `plan_dial` as `connect` does, with no URI re-parse and no
discarded hint.

For a direct byte-fed embedder, `GlowcapDialPlan` crosses the ABI: a plain-data
description of what to open that the binding interprets. The resolver and the C
shim (`src/c_abi/driver/mod.zig`, `glowcap_host_plan_dial`) own the policy and
the error wording, so a binding surfaces the core's message.

## Accept (sibling of dial)

`planAccept` is the accept-side resolver: given `(designator_scheme,
server_designator, accepted_local_addr)` it names the designator and
direct-addresses hint an accepted session would sign. The provider declares
the scheme when it registers. The Host never recovers semantics from a closed
transport-name table. Unlike the dial plan, this resolver has no C export:
`glowcap_host_session_open_accepted` takes the listener facts directly, runs
the resolver, and retains the result without displacing an advertised locator
the embedder published. That publication is deployment policy (a rendezvous
route carrying its relay hint, for one), and an accept that overwrote it would
strip the hints a handoff recipient dials back with. The accept-derived locator
becomes the selection only when there is none. A binding never composes or
applies the signing locator itself.

## Native Zig dial admission

TCP host:port selection for the TCP profiles is one pure helper,
`model.uri.tcpConnectHostPort`. Both `driver_core.planDial` (bindings / C ABI)
and `tcp.DialResolver.resolve` (completion loop / blocking residents) call it.
`planDial` refuses keyed-tcp and iroh designators with `PeerKey.fromDesignator`
before any binding opens a channel. DialResolvers apply the same predicate, so
a doomed dial never touches the network on either spine.

## Scope (what this does not decide)

- **Byte I/O is outside the core.** A byte-fed embedder interprets the plan
  and opens its explicit channel. The native driver instead dispatches to its
  registered provider and owns the I/O. Both keep ADR-0072's sans-io core.
- **Consumer-injected transports.** `planDial` is closed over glowcap's typed
  locator vocabulary. An unknown scheme is a typed error. A consumer-supplied
  byte-fed transport can still open a Host session directly, but extending the
  resolved-plan vocabulary is an explicit protocol/API decision.

## Alternatives Considered

- **A per-binding transport registry** (each binding holds a scheme-to-transport
  table). Rejected: it re-homes the dispatch in every binding, and the policy
  (grammar, reachability) still duplicates four ways.
- **A resolver the binding calls but then re-dispatches on.** Rejected: the
  binding re-decides after the core decided, and a connect side-door survives.

## Consequences

- Adding or changing dial grammar, reachability, or error policy is a core
  change in `dial_plan.zig` and the shim, inherited by every binding. A new
  provider artifact can require one composition-root registration and no
  binding-local policy dispatcher.
- The C header and ABI tests hold `GlowcapDialPlan` for direct byte-fed
  embedders. Binding generators omit it and `glowcap_host_plan_dial`. Native
  binding fronts reach transport dispatch through the generic driver and
  registered provider packages.
- The accept-side resolver has no separate C export or plan struct. Listener
  facts ride `glowcap_host_session_open_accepted` and the Host owns the
  locator derivation and retention.
- The DIAL action hands no consumed locator to the bindings.
- Verified by the per-binding dogfoods plus the `*-keyed-tcp-restart` and
  `*-iroh-redeem-posture` interop steps: real TCP and iroh dials, including a
  three-party redeem under a configured posture, run through the generic
  driver and their registered transport packages.

## Notes

ADR-0072 (the driver tier over the C ABI: the byte-fed host and its action
queue) and ADR-0076 (the loop-fed host bridge) are the lineage. This record
settles the binding-facing dial surface over that tier.
