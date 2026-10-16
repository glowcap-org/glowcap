---
id: ADR-0251
status: accepted
date: 2026-10-15
tags: [captp, next, conformance, negotiation, promises]
decision: "Next adopts the merged delivery and listen contracts and removes projections, while retaining the shared four-field hello and its crypto representations. One fingerprinted manifest governs upstream review and next-suite execution."
supersedes: []
superseded_by: []
amends: [ADR-0050, ADR-0052, ADR-0111]
amended_by: []
---

# ADR-0251 Next operations with retained crypto

## Context

The merged draft restores an inline resolver on `op:deliver`, adds its listen
mode, restores `op:deliver-only`, and removes the projection operations. Its
crypto transition also changes the opening record, which both profiles must
parse before negotiation. Goblins still speaks the old opening. Adopting the
operations does not require changing that shared grammar.

The upstream suite has a separate revision and still constructs baseline
operations. A baseline pass therefore cannot establish next conformance, and
excluding a hello test alone cannot protect against a change to shared setup.

## Decision

`1.0` retains its Goblins-compatible wire behavior. Next uses two-operand
`op:deliver-only` for sends without results and five-operand `op:deliver` for
calls: target, arguments, optional pipeline answer, mandatory resolver, and
listen mode 1 or 3. The inline subscription uses the ordinary answer listener
store, prepared before the receive commits. A resolver-only call has a private
answer identity independent of its callback capability, including while queued.

Queued work carries the reply's exact row identity and original import mentions
through GC, position reuse and argument shortening. Forwarding back to the
sender uses a fresh local resolver and settles that original reply. Returned
imports live with the stored answer, then leave through a bounded release
outbox. Its nullable pointer costs eight bytes per 64-bit session.

Next rejects `op:get`, `op:index`, and `op:untag` in both codecs and session
validation. Those operations remain available on `1.0`, subject to its existing
feature negotiation. Next advertises no `untag` feature. ADR-0050 and ADR-0052
continue to own the baseline projection machinery.

ADR-0111 still owns promise shortening, settling fan-out and callback lifetime.
Its operation/listen pair is replaced by the inline subscription. Sender-side
mode claims belong to the answer or imported-promise incarnation: modes cannot
overlap, and a first subscription must include shortening. GC ends that identity.

The shared four-field hello, structured keys/signatures and dependent signed
records stay deferred under the crypto transition plan. Signed locator offers
negotiate next after that one opening. There is no alternate hello or retry.

The conformance manifest fingerprints the whole pinned draft and every upstream
Python source for both profiles. A revision change requires explicit review of
adopted, deferred or pending rows. The next runner consumes those same suite
rows: pending sources fail, deferred modules report their owner, and skips fail.
Its socket fixture verifies signed next offers and native operation shapes,
then adapts the pinned suite's constructors while keeping its assertions. Gift
fixtures choose the draft's 32-byte identifier before signing. Local native
cases prove the new wire contracts the upstream suite does not yet test.

## Consequences

Spec and suite references can advance independently of implementation. The
manifest records the deliberate crypto deferral without claiming full-draft
conformance. Shared suite setup changes force fixture review. The adapter is
not a promise that arbitrary future upstream changes work without adjustment.

`ocapn-conformance-next` runs the baseline lane, fixture regressions, adopted
upstream cases on next, and draft-native cases. Both it and the mixed
next/Goblins gift check belong to recurring CI and `check-external`.
