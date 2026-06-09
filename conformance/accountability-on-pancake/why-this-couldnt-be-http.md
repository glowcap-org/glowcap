# Why this couldn't just be HTTP

The accountability app makes one claim that is hard to fake: **every invocation
produces a verifiable Episode attributing the true caller.** That claim is what
forces a capability protocol instead of HTTP. The argument is not "OCapN is nicer."
It is structural.

## The thing HTTP cannot do

Picture three parties. **A** holds a capability to a service **C**. A wants **B** to
use it on A's behalf, so A introduces B to C. Later C does something costly and an
auditor asks: *who actually invoked this?*

Over HTTP, A shares the capability by handing B a bearer token (a URL, an API key, a
cookie). From that moment:

- **C cannot tell B from A.** The token authenticates *possession*, not identity. B's
  call and A's call are byte-identical to C. The Episode C writes can only say "the
  bearer of token T," which is not an answer to "who."
- **Attenuation is ambient.** To let B do less than A, someone has to mint a second
  token, run a proxy, or push policy into C's application code. The narrowing lives
  in infrastructure, not in the reference B holds.
- **Revocation is global.** Revoke T and you cut off A and B together. There is no
  per-recipient handle to revoke, because the token *is* the authority and it was
  copied.
- **The introduction leaves no honest trace.** "A let B in" is a log line in some
  gateway, not a property of the call C received. An auditor reconstructs it from
  correlated logs across machines, and trusts every hop in between.

You can bolt attribution on — mutual TLS, signed JWTs, an OAuth actor claim, an
SPIFFE identity per workload. Each is real engineering, and each re-introduces the
same gap one layer up: the receiver still trusts a *header* it was handed, and the
delegation chain still lives outside the call. The attribution is asserted by
infrastructure, not carried by the authority itself.

## What the capability wire gives you instead

In this app the authority C accepts is a **capability**, and the call B makes is an
**object-capability invocation**, not a request to a URL. Two consequences fall out:

1. **The reference is the authority.** B holds a specific imported reference to C's
   Affordance, distinct from A's. There is no shared bearer secret to be
   indistinguishable about. When OCapN's three-party handoff (ADR-0009) introduces B
   to C, C ends up with a *distinct* import for B — so "who called" is answered by
   the reference itself, before the application logic runs.

2. **Attribution is attested at the call, not trusted from a header.** The app does
   not let C believe a "caller" field. The caller signs the request with its KERI
   key; C verifies that signature against the presented verkey before it writes an
   Episode, and **refuses** — a clean broken promise, no Episode — for anything it
   cannot attest (step 6 of the run). The proof of "who" rides *inside* the
   invocation and is checked by the party that accounts for it.

The Episode C writes is therefore not "someone with a token did X." It is "this AID,
whose key I verified, invoked X, and here is the signature chain that an auditor can
re-check offline, for that point in time, even after the key rotates or is revoked."

## Why OCapN, specifically

HTTP's unit is a *request to a location*; its trust model is *who can reach the URL
and present the token*. OCapN's unit is an *invocation of a reference*; its trust
model is *who holds the capability*, and a three-party handoff preserves the
distinctness of "who holds it" across an introduction. Accountability that survives
delegation is a direct consequence of that, not a feature layered on top.

That is the bite OCapN can take out of HTTP: not raw speed, not a nicer RPC, but a
class of guarantees — unforgeable attribution, per-recipient authority, delegation
that is visible in the call — that HTTP's bearer-token shape cannot express, only
approximate. This app is the smallest honest demonstration of it running on pancake.

## Honest scope of *this* run

The two-party invocation, the attested refusal, and the verifiable Episodes are
shipped and run from `zig build accountability`. The same Affordance is reached from
**Deno** and **Python** callers over the C ABI — three languages, one OCapN wire. The
**three-party handoff** attribution test (`zig build accountability-three-party`)
proves in memory that B's Episode attributes B, not A, after a handoff. The
over-TCP three-vat variant is the next frontier. This page states the structural
argument the shipped pieces already support.
