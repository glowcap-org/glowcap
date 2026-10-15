---
type: static
description: How an HTTP bearer-token design compares with what OCapN already provides, before the application adds its own identity and audit log.
sources: []
---

# HTTP and capability accountability

This application could carry its signed request over HTTP. HTTP is a transport,
not an authority model, and mutual TLS, signed bodies, macaroons, and OAuth can
all provide identity or delegation. The comparison here is narrower: what does
OCapN provide before the application adds its KERI-shaped identity and audit
log?

## The bearer-token version

Suppose A gives B the same API key, cookie, or unscoped bearer URL that A uses
to call service C. C can verify possession of the token but cannot distinguish
A from B. Revoking the token cuts off both holders.

An HTTP design can fix that. It can mint a separate credential for B, bind it
to B's key, narrow its scope, record who issued it, and keep revocation state.
Each is an application and infrastructure choice. A copied bearer token carries
no delegation, recipient identity, or per-recipient revocation by itself.

## What OCapN supplies

OCapN starts from live object references:

- Holding a capability is the authority to invoke that object.
- A narrower wrapper can expose fewer operations.
- A revocable forwarder can end one grant without changing the underlying
  object.
- Three-party handoff lets A introduce B to C, after which B holds a direct
  capability to C and A leaves the call path.

These properties answer *what may this peer call?* They do not, on their own,
answer *which real-world identity is this peer?*

This application adds that second answer. B signs the request and sends a key
history that binds the signing key to B's self-certifying AID. C validates the
history and signature before recording an Episode. A bad signature or a key
the history has retired is refused.

After A introduces B to C, the accepted Episode names B because B signed the
call. OCapN preserves the direct capability relationship. The application
provides identity and the audit record. The example does not record a complete
delegation chain from A to B.

## Why use OCapN here

An HTTP application could recreate this design with signed requests,
recipient-specific credentials, delegation records, scoped grants, and
revocation machinery. OCapN makes reference passing and three-party
introduction part of the network model, so the application can concentrate on
identity and the audit record.

Run `zig build accountability` for the Zig signed-call path and
`zig build accountability-three-party` for attribution after a live three-Host
TCP handoff. The [application guide](README.md) describes the limits: no witness
receipts and no cross-session duplicity detection.
