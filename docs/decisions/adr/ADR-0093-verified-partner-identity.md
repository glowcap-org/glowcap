---
id: ADR-0093
status: accepted
date: 2026-07-29
tags: [captp, host, identity, bindings]
decision: "An application can read a verified session key, the locator claim that key signed, and separate durable-authentication provenance. Unverified and incomplete handshakes refuse."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0097, ADR-0109, ADR-0113]
---

# ADR-0093 Verified Partner Identity

## Status

Accepted for the `PartnerIdentity` API and its verified-or-refuse contract.
ADR-0097 separates the per-session signing key from durable peer identity, and
ADR-0109 keeps durable-key attestation out of locator hints. A successful report
contains a verified session signer, that signer's locator claim, and separate
provenance that is authenticated only when the realized channel proved the same
durable key.

## Problem

The handshake learns the session signer and the locator that signer claims. A
keyed `op:start-session` carries an Ed25519 signature over the partner's
`<my-location …>` record, and `engine.verifyPartnerStartSession` checks it
before the session opens and before the key is recorded. The session then holds
the verified session key, the designator it signed, and the verbatim location
record. That signature proves control of the session key and authorship of the
claim. It does not prove durable ownership of the claimed designator.

`Session.partnerSessionKey`, `partnerDesignator`, and `partnerLocatorRaw` are
core-side accessors, so an application needs a partner-identity entry point
(`src/c_abi/host/symbols.zig` for bindings) to read the handshake facts the
session retains.

The need appears when an application routes on a name a caller supplies. The
rooms directory takes an exporter locator from the wire and stamps it on the
session, overriding the partner's signed location, so anyone reaching the
directory can point introductions at a third party. The application cannot
evaluate that claim without the verified session signer and any independent
durable-authentication provenance.

## Decision

Add `driver_core.PartnerIdentity` and `Host.partnerIdentity(session)`, expose
them natively as `driver.Session.partnerIdentity()`, and wrap them for C as
`glowcap_host_session_partner_identity` with a `GlowcapPartnerIdentity` view
struct.

**The policy lives in the core, not at the ABI.** The verified-session-or-refuse
decision belongs in `driver_core` beside `Identity`, the type describing what
this side advertises, with the C ABI and the native `driver.Session` both
wrapping one definition.

**A success means the signature was checked, and the core enforces it.**
`Options.verify_partner` defaults on and no ABI entry point turns it off, but a
Zig embedder can, so `partnerIdentity` refuses `HostError.PartnerUnverified` on
a session that does not verify its partner instead of handing back an unchecked
session key and locator claim. A partner that has not sent its handshake half
yet refuses `HostError.HandshakeIncomplete`. A caller never has to ask how the
session was configured before trusting the session key as verified. The locator
is the verified signer's claim unless `provenance` says a matching channel proof
authenticated its durable key. This is a refusal and not a flag on the result,
because removing the signature check would otherwise return an unverified
session key indistinguishable from a verified one.

**The library answers the literal designator comparison once.** The signature
covers the whole location record, so it binds the session signer to
the designator claim. `PartnerIdentity.designatorIsSessionKey` compares that
claim against the session key in the canonical hex encoding for a key
designator, so no binding re-derives the encoding. Equality is diagnostic only.
It does not authenticate durable ownership.

[ADR-0097](ADR-0097-captp-session-identity-attestation.md) makes that
comparison a diagnostic and gives the report a third field, and ADR-0109 removes
the attestation provenance arm. Whether a partner's durable name was
authenticated is `PartnerIdentity.provenance`, which every public tier reports
and which is positive only for matching authenticated-channel proof. Fresh
session keys are normally distinct from durable locator keys.

## Scope (what this does not decide)

- What is signed or verified is unchanged: the handshake verifies the session
  key's signature over the locator claim. This makes those facts and their
  distinct provenance readable.
- The answer is meaningful for a key-designator transport, the
  `DesignatorScheme.key` set that `designatorSchemeForTransport` names. An
  address transport such as `tcp` designates a socket address the key does not
  determine, so `designatorIsSessionKey` is false for a verified `tcp` partner,
  which is a correct answer and not a failure. A caller that requires
  an authenticated durable peer asks `durableIdentityAuthenticated`. Transport
  scheme and key equality are not substitutes for provenance.
- No application policy is imposed. `setExporterLocation` accepts the locator it
  is given. Whether a caller may claim one is the application's call, and this
  is the fact it needs.
- The views borrow session-owned bytes. They are written once when the
  partner's handshake half arrives, never rewritten, and freed with the
  session.

## Alternatives Considered

- **Report the identity with a `verified` flag rather than refusing.**
  Rejected: it makes the unverified case representable, and every caller then has
  to read the flag. A refusal leaves one path.
- **Expose the three accessors separately.** Rejected: they are one report with
  distinct meanings, and splitting them invites a caller to read the claimed
  designator without its verified session signer or provenance.
- **Let each binding hex-encode the key and compare.** Rejected: four
  re-derivations of one encoding is the shape `dial_plan` exists to prevent, and
  the comparison needs a single owner.

## Consequences

- `driver_core` has `PartnerIdentity` and two `HostError` arms. `src/c_abi/host`
  has one view struct and two entry points, mirrored in all four bindings and
  pinned by the generated layout facts.
- `NotAWirePosition` maps to `GLOWCAP_ERR_INVALID_ARGUMENT`, as the generated
  header for ADR-0092's `glowcap_host_session_release_import` promises.
- `test/driver/core_host/identity_test.zig` holds the report contract: signature
  verification gates success, the canonical comparison remains literal, raw
  keyed-TCP locator claims stay unauthenticated, and matching channel proof
  supplies authenticated provenance without equating session and durable keys.

## Notes

Sibling of [ADR-0092](ADR-0092-deterministic-capability-release.md), which added
the other session-scoped verb in the same shape and across the same four
bindings. The key-designator vocabulary it reads is
[ADR-0075](ADR-0075-keyed-tcp-designator.md)'s. The token-versus-position
distinction it stays clear of is
[ADR-0091](ADR-0091-reserved-position-bands.md)'s.
