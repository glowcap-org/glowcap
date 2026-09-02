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

# ADR-0078 Dial is a core-resolved plan; bindings are thin interpreters

> **Native-provider amendment (ADR-0112).** The original binding projection
> below was retired when `libglowcap_driver` gained its provider seam. Native
> bindings now pass a typed locator to the generic driver; each registered
> transport package owns its locator interpretation and concrete I/O. The
> generic binding runtimes therefore expose neither `GlowcapDialPlan` nor its
> shape, reach, and posture constants. `glowcap_host_plan_dial` remains the
> right primitive for a direct byte-fed C embedder that owns the channel.

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
exposed over the C ABI as `glowcap_host_plan_dial` on the driver tier
(ADR-0072), but no binding called it: each re-derived the same decisions.

This engages the first principle that the correct path is the easy path, and
the layer boundary: dial dispatch, grammar, and reachability are protocol
policy, which belongs in the core. A binding is an adapter that owns I/O, not
policy.

## Decision

A byte-fed embedder's dial is a thin interpreter over the core resolver. It
marshals posture policy, calls `glowcap_host_plan_dial`, and executes the
returned integration shape. No such embedder needs to carry transport grammar,
the hint rule, the reachability decision, or dial error strings.

A native binding takes the provider path added by ADR-0112 instead. Its runtime
passes the complete typed locator through `libglowcap_driver`; the registered
transport package interprets the locator and owns the concrete dial. Generic
runtime code knows only providers and connectors, never concrete transports or
the byte-fed plan vocabulary.

`connect` and handoff-redeem are one path. Both funnel through the same generic
driver and registered provider; the connect side-door that opened inline is gone.
A DIAL action carries only `ticket`; the binding clones the complete typed
locator projected by `glowcap_host_pending_dial` and resolves through
`plan_dial` exactly as `connect` does: no URI re-parse and no discarded hint.

For a direct byte-fed embedder, the resolved plan is the transitory type that
crosses the ABI:
`GlowcapDialPlan`, a plain-data description of what to open. It is a reified
command, and the binding is its interpreter. The resolver and the C shim
(`src/c_abi/driver/mod.zig`, `glowcap_host_plan_dial`) own the policy and the
error wording, so a binding surfaces the core's message and writes none of its
own.

## Accept (sibling of dial)

`planAccept` is the accept-side resolver: given `(designator_scheme,
server_designator, accepted_local_addr)` it names the designator and
direct-addresses hint an accepted session would sign. The provider declares
the scheme when it registers; the Host never recovers semantics from a closed
transport-name table. Unlike the dial plan, this resolver has no C export:
`glowcap_host_session_open_accepted` takes the listener facts directly, runs
the resolver, and retains the result without displacing an advertised locator
the embedder explicitly published, because that publication is deployment
policy (a rendezvous route carrying its relay hint, for one) and an accept
that overwrote it would strip the hints a handoff recipient dials back with.
The accept-derived locator becomes the selection only when there is none. A
binding therefore never composes or applies the signing locator itself; the
first shipped version of this seam had every binding do exactly that with a
displacing set, and the browser rendezvous route lost its relay hint on the
first accepted session.

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
- **Consumer-injected transports.** `planDial` is closed over glowcap's typed
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
- The C header and ABI tests hold `GlowcapDialPlan` for direct byte-fed
  embedders. Binding generators deliberately omit it and
  `glowcap_host_plan_dial`; native binding fronts reach transport dispatch
  through the generic driver and registered provider packages.
- The accept-side resolver has no separate C export or plan struct; listener
  facts ride `glowcap_host_session_open_accepted` and the Host owns the
  locator derivation and retention.
- The DIAL action no longer hands a consumed locator to the bindings; the dead
  field, its read, and its forward dropped from each binding's action drain.
- Verified by the per-binding dogfoods plus the `*-keyed-tcp-restart` and
  `*-iroh-redeem-posture` interop steps: real TCP and iroh dials, including a
  three-party redeem under a configured posture, run through the generic
  driver and their registered transport packages.

## Notes

ADR-0072 (the driver tier over the C ABI: the byte-fed host and its action
queue) and ADR-0076 (the loop-fed host bridge) are the lineage; this record
settles the binding-facing dial surface over that tier.
