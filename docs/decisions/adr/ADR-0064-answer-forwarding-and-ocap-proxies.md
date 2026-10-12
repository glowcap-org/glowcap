---
id: ADR-0064
status: accepted
date: 2026-06-18
tags: [actors, ocap, vat, bindings]
decision: "The vat gains an answer-forwarding primitive (Turn.forward): a handler may forward its turn's call to another reference (local or far) and defer its own answer onto the forwarded send's settlement. On it, the actor layer ships two forwarding-proxy patterns (a revocable caretaker and a verb allow-list attenuator) over any reference, mirrored by per-binding wrappers."
supersedes: []
superseded_by: []
---

# ADR-0064 Answer forwarding and object-capability proxies

## Context

Two common object-capability patterns are revocation (hand a partner a
capability you can later switch off) and attenuation (hand a partner a narrower
view of a capability you hold: fewer verbs, less authority). Both are a
forwarding proxy between a caller and a target that passes some calls and
refuses others. The holder usually wants to attenuate a reference it imported
over the wire, which is a far one.

A proxy that wraps a local behavior is easy: the handler near-calls the target
and returns its value. A proxy that wraps a far reference cannot, because the
target lives on a partner and the answer arrives only when the forwarded send
settles. The vat's inbound deliver path (`Vat.serve`) resolved a turn's answer
synchronously from the handler's return value, and a handler could not say that
its answer is whatever another send resolves to. Without that, forwarding
proxies could wrap only local targets. A forwarding proxy must be
wire-transparent, and the forwarding and refusal must be visible at the actor
boundary.

## Decision

### The primitive: `Turn.forward`

A handler may call `turn.forward(target, msg)` to forward its turn's call to
`target` (local or far) and hand its own answer to the forwarded send. The vat
resolves the turn's inbound answer when (and as) the forwarded send settles:
fulfilled with the target's value, broken with the target's break. Three cases follow
one rule, that the answer follows the forwarded send:

- **Eventual deliver with an answer, local or wire.** `forward` eventual-sends
  to the target, registers a listener on the resulting promise, and marks the
  turn forwarded so `serve` skips its usual return-value resolution. When the
  promise settles, the listener resolves the deferred inbound answer. The target
  may be far: the send rides the wire, and the partner's `op:resolve` settles
  the listener, which resolves the original caller's answer. A partner
  pipelining on the proxy's answer queues on this side until the forward
  settles.
- **Local or inbound `tell` (no answer).** `forward` forwards fire-and-forget and marks
  the turn forwarded. There is no answer to defer.
- **Synchronous near-call (`$`).** A near-call wants a value now, so `forward`
  near-calls the target and returns its value directly. This is legal only for a
  local target (`near` refuses a far reference), since a proxy fronting a far
  object cannot be near-called.

`forward` returns `anyerror!Argument` so a near-forward propagates the target's
own error. The deferred paths return a placeholder the vat ignores once the turn
is marked forwarded.

### The patterns: caretaker and attenuator

On `forward`, `src/actors/ocap.zig` ships two forwarding proxies, each an actor
whose `handle` forwards or refuses and whose proxy is an ordinary `Ref`:

- `caretaker(vat, target)` returns `{ proxy, revoke }`, a revocable forwarder.
  Until `revoke()`, the proxy forwards every call to `target`. After, every call
  breaks with `Revoked`. A shared one-bit flag lives with the proxy actor and is
  freed with it.
- `attenuate(vat, target, allowed)` returns `proxy`, a verb allow-list forwarder.
  A call whose verb is in `allowed` forwards to `target`. Any other breaks with
  `Attenuated`. The allow-list is copied into the actor.

Refusals are typed breaks (`Revoked`, `Attenuated`): over the wire they surface
to the partner as a broken answer, in-process they propagate from `near`. The
refused authority is unrepresentable through the proxy, not permission-checked
after dispatch: an attenuated reference cannot express a verb it does not
forward. The two compose: a caretaker over an attenuator's proxy is a revocable,
narrowed view, because each is a forwarding actor and each proxy is a `Ref`.

### Mirrored in the bindings

Each language binding exposes `caretaker` and `attenuate` over its `Ref`/handle
type, wrapping any reference the application holds, including one imported over
the wire, so the proxy is wire-transparent in every language. The bindings carry
the same deferred-answer behavior on the C ABI seam the forward primitive
exposes.

## Scope (what this does not decide)

- The attenuator filters on verb, not on arguments or a richer policy. A
  predicate/argument-aware attenuator is not implemented.
- `forward` defers onto one forwarded send. A handler that wants to
  forward to several targets and combine answers composes sends and listeners
  itself. `forward` is the single-hop primitive, not a join.
- Revocation is a local lever on the proxy's host. It does not recall
  capabilities the partner already passed on to a third party. It severs the
  proxy, and anything reached only through that proxy. (Transitive revocation is
  a caretaker-of-caretakers construction, not a new primitive.)
- The sans-io core is unchanged. `forward` is vat-layer (actors) machinery over
  the existing send/resolve/listener seam.
- A turn-time `forward` cannot carry a three-party gift. `turnTarget`
  (`src/c_abi/host/common.zig`) refuses a target foreign to the turn's own
  session, and `forwardListener` settles the answer without passing through the
  resolve interceptor that mints a give. Forwarding to an introduced exporter is
  therefore an ordinary send, not a `forward`. A give that arrives on the
  forwarded vow is broken with "introduction not forwardable", because a give is
  signed for this vat's session key (`src/actors/vat/forwarding.zig`).

## Alternatives Considered

- **Local-only proxies (handler near-calls the target, returns the value).**
  Rejected: it cannot wrap a far reference, which is attenuating an imported
  capability, the main use.
- **Resolve the answer eagerly to the forwarded promise as a value.**
  Rejected: it would hand the partner a promise to a promise and leak the proxy
  into the wire shape. Deferring the answer keeps the proxy transparent: the
  partner sees one answer that settles once.
- **A general interposition framework (per-message rewriting, trapping,
  transitive wrapping of every reference that crosses the boundary).** Rejected
  as more surface than the two patterns need. A fuller interposition layer can
  be built on the same primitive.

## Consequences

- The vat has `Turn.forward` and the `inbound_answer`/`forwarded`/`near_call`
  turn fields that make the deferral explicit. `serve` and `callLocal` honor the
  forwarded flag. `makeBox` moves `initial` into the heap state before its next
  fallible step, so a spawn-time failure reclaims a fully-formed value via
  `deinit`. Spawned actors such as the forwarding proxies own heap state.
- `src/actors/ocap.zig` ships `caretaker`/`attenuate`/`Caretaker`, re-exported
  from `src/actors/mod.zig`. `test/actors/ocap_test.zig` gates them: local
  forwarding and refusal through `near`, composition, and an over-the-wire test
  where a far caller reaches a hosted caretaker proxy, the forward defers and
  settles the caller's answer, and a revoke then breaks it.
- Each binding has `caretaker`/`attenuate` wrappers and a dogfood proving
  revoke and attenuate over a reference, exercising the deferred-answer path.

## Notes

Builds on the vat's send/resolve/listener machinery (ADR-0036's sync, no-I/O
actor layer). The forward listener uses the `on(promise, …)` seam the
finalizer-to-loop and far-promise paths use. A forwarded far send settles through
the ordinary `op:resolve` inbound path.

### Local eventual execution

Queued local calls carry a local answer distinct from synchronous near calls.
Their forwards reserve a continuation before sending. Settlement follows the
forwarded result, including a remote target or an off-turn resolver. Local
continuation chains settle iteratively and reuse the producer's settlement
borrow, so a long chain does not recurse through callbacks or clone each result at every
hop. Tells forward without minting a remote answer. Near calls
retain their synchronous local-only contract.

Rust routes every local application call through the Host, with no callback
index or separate local executor. The TS, Python and Racket bindings run a
local eventual call in process, outside the Host. The shared actor and C ABI
tests define the behavior, not those in-process paths.
