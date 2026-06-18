---
id: ADR-0064
status: accepted
date: 2026-06-18
tags: [actors, ocap, vat, bindings]
decision: "The vat gains an answer-forwarding primitive (Turn.forward): a handler may forward its turn's call to another reference — local or far — and defer its own answer onto the forwarded send's settlement. On it, the actor layer ships two membrane patterns — a revocable caretaker and a verb allow-list attenuator — as forwarding proxies over any reference, mirrored by per-binding wrappers."
supersedes: []
superseded_by: []
---

# ADR-0064 Object-capability membranes and answer forwarding

## Context

Two of the commonest object-capability patterns are *revocation* (hand a partner
a capability you can later switch off) and *attenuation* (hand a partner a
narrower view of a capability you hold — fewer verbs, less authority). Both are
the same shape: a forwarding proxy that sits between a caller and a target,
passing some calls and refusing others. Handing out an attenuated or revocable
view of a capability you imported over the wire is not a convenience on top of
capability networking — it *is* the point of it.

A proxy that wraps a **local** behavior is easy: the handler near-calls the
target and returns its value. A proxy that wraps a **far** reference is not,
because the value does not exist yet on this side — the target lives on a
partner, and the answer only arrives when the forwarded send settles. The vat's
inbound deliver path (`Vat.serve`) resolved a turn's answer from the handler's
*return value*, synchronously. A handler had no way to say "my answer is
whatever that other send resolves to." Without that, a membrane could only wrap
local targets, which would make the helpers a toy: the holder usually wants to
attenuate a reference it imported, i.e. a far one.

This engages **protocol-correctness-before-convenience** (a membrane must be
wire-transparent, not a local-only shortcut) and **explicit-over-implicit** (the
forwarding and the refusal must be visible at the actor boundary, not hidden
behind a proxy that silently swallows authority).

## Decision

### The primitive: `Turn.forward`

A handler may call `turn.forward(target, msg)` to forward its turn's call to
`target` (local or far) and hand its own answer to the forwarded send. The vat
resolves the turn's inbound answer when — and as — the forwarded send settles:
fulfilled with the target's value, broken with the target's break. Three cases,
one rule (the answer follows the forwarded send):

- **Eventual deliver with an answer.** `forward` eventual-sends to the target,
  registers a listener on the resulting promise, and marks the turn *forwarded*
  so `serve` skips its usual return-value resolution. When the promise settles,
  the listener resolves the deferred inbound answer. The target may be far: the
  send rides the wire, and the partner's `op:resolve` settles the listener,
  which resolves the original caller's answer. A partner pipelining on the
  proxy's answer queues on this side until the forward settles.
- **Inbound `tell` (no answer).** `forward` forwards fire-and-forget and marks
  the turn forwarded; there is no answer to defer.
- **Synchronous near-call (`$`).** A near-call wants a value *now*, so `forward`
  near-calls the target and returns its value directly. This is legal only for a
  local target — `near` refuses a far reference — which is the correct
  semantics: you cannot synchronously near-call through a membrane that fronts a
  far object.

`forward` returns `anyerror!Argument` so a near-forward propagates the target's
own error; the deferred paths return a placeholder the vat ignores once the turn
is marked forwarded.

### The patterns: caretaker and attenuator

On `forward`, `src/actors/ocap.zig` ships two membranes, each an actor whose
`handle` forwards or refuses and whose proxy is an ordinary `Ref` you delegate
like any other:

- **`caretaker(vat, target) → { proxy, revoke }`** — a revocable forwarder.
  Until `revoke()`, the proxy forwards every call to `target`; after, every call
  breaks with `Revoked`. A shared one-bit flag lives with the proxy actor and is
  freed with it.
- **`attenuate(vat, target, allowed) → proxy`** — a verb allow-list forwarder.
  A call whose verb is in `allowed` forwards to `target`; any other breaks with
  `Attenuated`. The allow-list is copied into the actor.

Refusals are typed breaks (`Revoked`, `Attenuated`): over the wire they surface
to the partner as a broken answer, in-process they propagate from `near`. The
refused authority is *unrepresentable* through the proxy, not permission-checked
after dispatch — an attenuated reference cannot express a verb it does not
forward. The two compose: a caretaker over an attenuator's proxy is a revocable,
narrowed view, because each is just a forwarding actor and each proxy is a
`Ref`.

### Mirrored in the bindings

Each language binding exposes `caretaker` and `attenuate` over its `Ref`/handle
type, wrapping any reference the application holds — including one imported over
the wire — so the membrane is wire-transparent in every language, not a
Zig-only affordance. The bindings carry the same deferred-answer behavior on the
C ABI seam the forward primitive exposes.

## Scope (what this does not decide)

- The attenuator filters on **verb**, not on arguments or on a richer policy. A
  predicate/argument-aware attenuator is a later lift; the verb allow-list is
  the common case and the boring surface.
- `forward` defers onto exactly one forwarded send. A handler that wants to
  forward to several targets and combine answers composes sends and listeners
  itself; `forward` is the single-hop primitive, not a join.
- Revocation is a local lever on the proxy's host. It does not retroactively
  recall capabilities the partner already *passed on* to a third party; it
  severs the proxy, and anything reached only through that proxy. (Transitive
  revocation is a caretaker-of-caretakers construction, not a new primitive.)
- This does not change the sans-io core. `forward` is vat-layer (actors)
  machinery over the existing send/resolve/listener seam; the session and codec
  are untouched.

## Alternatives Considered

- **Local-only proxies (handler near-calls the target, returns the value).**
  Rejected: it cannot wrap a far reference, which is the case that matters —
  attenuating an imported capability. It would ship a membrane that works only
  where you least need one.
- **Resolve the answer eagerly to the forwarded *promise* as a value.**
  Rejected: it would hand the partner a promise to a promise and leak the
  membrane's existence into the wire shape. Deferring the answer keeps the proxy
  transparent — the partner sees one answer that settles once.
- **A general interposition/membrane framework (per-message rewriting,
  trapping, transitive wrapping).** Rejected for now as more surface than the
  two patterns earn. `forward` is the primitive; caretaker and attenuator are
  the two shapes worth shipping. A fuller membrane can be built on the same
  primitive without changing it.

## Consequences

- The vat gains `Turn.forward` and the `inbound_answer`/`forwarded`/`near_call`
  turn fields that make the deferral explicit; `serve` and `callLocal` honor the
  forwarded flag. `makeBox` now moves `initial` into the heap state before its
  next fallible step, so a spawn-time failure reclaims a fully-formed value via
  `deinit` (the documented contract) — required now that spawned actors
  (the membranes) own heap state.
- `src/actors/ocap.zig` ships `caretaker`/`attenuate`/`Caretaker`, re-exported
  from `src/actors/mod.zig`. `test/actors/ocap_test.zig` gates them: local
  forwarding and refusal through `near`, composition, and an over-the-wire test
  where a far caller reaches a hosted caretaker proxy, the forward defers and
  settles the caller's answer, and a revoke then breaks it.
- Each binding gains `caretaker`/`attenuate` wrappers and a dogfood proving
  revoke and attenuate over a reference, exercising the deferred-answer path.

## Notes

Builds on the vat's send/resolve/listener machinery (ADR-0036's sync, no-I/O
actor layer). The forward listener reuses the same `on(promise, …)` seam the
finalizer→loop and far-promise paths use; a forwarded far send settles through
the ordinary `op:resolve` inbound path.
