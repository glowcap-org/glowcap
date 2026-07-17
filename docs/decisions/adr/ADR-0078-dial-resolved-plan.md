---
id: ADR-0078
status: accepted
date: 2026-07-12
tags: [bindings, c-abi, dial, netlayer, layer-separation]
decision: "A binding's dial is a thin interpreter over the core resolver: it marshals the posture policy, calls pancake_host_plan_dial to resolve the plan, and opens the byte channel the plan names. No binding carries transport dispatch, host:port grammar, the direct-addresses hint rule, the peer-id reachability decision, or dial error strings. connect and handoff-redeem are one path. Accept is the sibling: pancake_host_plan_accept resolves the signing designator and hint; bindings do not re-derive accept designator policy per server type. Open shapes are host_port and peer_id; the iroh locator scheme stays in the policy table only."
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
posture)` to a plan: an open shape (`host_port`, or `peer_id` with addresses
and reach; today the `iroh` locator scheme produces `peer_id`), and typed
errors. The plan tag names what to open, not which netlayer archive opens it;
the product string `"iroh"` stays in the policy table. It was exposed over the
C ABI as `pancake_host_plan_dial` on the driver tier (ADR-0072), but no binding
called it: each re-derived the same decisions.

This engages the first principle that the correct path is the easy path, and
the layer boundary: dial dispatch, grammar, and reachability are protocol
policy, which belongs in the core. A binding is an adapter that owns I/O, not
policy.

## Decision

A binding's dial is a thin interpreter over the core resolver. It does three
things: marshal the posture policy (redeem, explicit, or explicit-none), call
`pancake_host_plan_dial`, and open the byte channel the returned plan names,
a socket for the `host_port` shape, the iroh companion for the `peer_id` shape
(`PANCAKE_DIAL_SHAPE_PEER_ID`). No binding carries transport dispatch, host:port
grammar, the hint rule, the reachability decision, or dial error strings.

`connect` and handoff-redeem are one path. Both funnel through the same
resolve-then-open executor; the connect side-door that opened inline is gone.
A DIAL action carries only `ticket`; the binding borrows the pending view
(`pancake_host_pending_dial` → `PancakePendingDial`) and resolves through
`plan_dial` exactly as `connect` does: no URI re-parse.

The resolved plan is the transitory type that crosses the ABI:
`PancakeDialPlan`, a plain-data description of what to open. It is a reified
command, and the binding is its interpreter. The resolver and the C shim
(`src/c_abi/driver/mod.zig`, `pancake_host_plan_dial`) own the policy and the
error wording, so a binding surfaces the core's message and writes none of its
own.

## Accept (sibling of dial)

`planAccept` / `pancake_host_plan_accept` is the accept-side resolver: given
`(transport, server_designator, accepted_local_addr)` it returns an
`AcceptPlan`: the designator and direct-addresses hint the accepted session
signs. Bindings call it from `establishAccepted` /
`establish_accepted` / `establish-accepted-session` before
`pancake_host_session_open_accepted`. Native `acceptVia` calls the same
`planAccept` (no second scheme→hint switch). Listen modules pass the
listener's designator (or empty for address transports) and the
accept-reported local address; they do not choose signing bytes themselves.

## Native Zig dial admission

TCP host:port selection for `tcp` / `keyed-tcp` is one pure helper,
`model.uri.tcpConnectHostPort`. Both `driver_core.planDial` (bindings / C ABI)
and `tcp.DialResolver.resolve` (completion loop / blocking residents) call it.
Keyed-tcp and iroh designators are refused with `PeerKey.fromDesignator` in
`planDial` before any binding opens a channel; DialResolvers keep the same
predicate so a doomed dial never touches the network on either spine.

## Scope (what this does not decide)

- **Byte I/O stays in the binding.** The core resolves the plan; the binding
  opens the socket or QUIC connection. This is the sans-io boundary of
  ADR-0072, unchanged. Moving transport I/O into Zig (the completion-loop path)
  is a separate concern.
- **Consumer-injected transports.** `planDial` / `planAccept` are closed over
  the built-in schemes (tcp, keyed-tcp, iroh); an unknown scheme is a typed
  error. A consumer-supplied transport (for example a WebSocket transport for a
  wasm host) plugging in at the ABI is not implemented.

## Alternatives Considered

- **A per-binding transport registry** (each binding holds a scheme-to-transport
  table). Rejected: it re-homes the dispatch in every binding instead of
  removing it, and the policy (grammar, reachability) still duplicates four
  ways.
- **A resolver the binding calls but then re-dispatches on.** Rejected: it
  leaves the binding re-deciding after the core already decided, and the connect
  side-door survives.

## Consequences

- Adding or changing a dial policy: a new transport's grammar, a reachability
  rule, an error message: is a core change in `dial_plan.zig` and the shim,
  inherited by every binding with no binding edit.
- Each binding mirrors `PancakeDialPlan` (a 56-byte C struct) with a layout pin
  or assert: generated for TypeScript (`tools/gen/binding/ts_abi.zig`), a `ctypes`
  `_pin_layout` in Python, a `pin-layout!` cstruct in Racket, a `const` assert
  in Rust. Rust cfg-gates the peer-id plan fields and the `DIAL_REACH_*`
  constants so the tcp-only build stays dead-code clean.
- `tools/check/meta_check.zig`'s dial guard requires `pancake_host_plan_dial` in
  each binding's dial file and bans local host:port splitters; its accept guard
  requires `pancake_host_plan_accept` in each binding's session mint path.
- The DIAL action no longer hands a consumed locator to the bindings; the dead
  field, its read, and its forward dropped from each binding's action drain.
- Verified by the per-binding dogfoods plus the `*-keyed-tcp-restart` and
  `*-iroh-redeem-posture` interop steps: real tcp and iroh dials, including a
  three-party redeem under a configured posture, run through the resolved plan.

## Notes

ADR-0072 (the driver tier over the C ABI: the byte-fed host and its action
queue) and ADR-0076 (the loop-fed host bridge) are the lineage; this record
settles the binding-facing dial surface over that tier.
