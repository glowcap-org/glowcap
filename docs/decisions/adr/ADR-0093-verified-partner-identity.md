---
id: ADR-0093
status: accepted
date: 2026-07-29
tags: [captp, host, identity, bindings]
decision: "An application can read a verified session key, the locator claim that key signed, and separate durable-authentication provenance. Unverified and incomplete handshakes refuse."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0097, ADR-0109]
---

# ADR-0093 Verified Partner Identity

## Status

Accepted for the `PartnerIdentity` API and its verified-or-refuse contract.
ADR-0097 separated the per-connection session key from durable peer identity,
and ADR-0109 removed durable-key attestation from locator hints. A successful
report now contains a verified session signer, that signer's locator claim, and
separate provenance that is authenticated only when the realized channel proved
the same durable key.

## Problem

The handshake already learns the session signer and the locator that signer
claims. A keyed `op:start-session` carries an Ed25519 signature over the
partner's `<my-location …>` record, and
`engine.verifyPartnerStartSession` checks it before the session opens and before
the key is recorded. The session then holds the verified session key, the
designator it signed, and the verbatim location record. That signature proves
control of the session key and authorship of the claim; it does not prove
durable ownership of the claimed designator.

None of that was reachable. `Session.partnerSessionKey`,
`partnerDesignator`, and `partnerLocatorRaw` are core-side accessors, and
`src/c_abi/host/symbols.zig` exported no partner-identity entry point at all,
so no binding could read the handshake facts already retained by the session.

What that costs shows up the moment an application routes on a name a caller
supplies. The rooms directory takes an exporter locator from the wire and
stamps it on the session, overriding the partner's signed location, so anyone
reaching the directory can point introductions at a third party. The
application cannot evaluate that claim properly on its own without both the
verified session signer and any independent durable-authentication provenance.

## Decision

Add `driver_core.PartnerIdentity` and `Host.partnerIdentity(session)`, expose
them natively as `driver.Session.partnerIdentity()`, and wrap them for C as
`pancake_host_session_partner_identity` with a `PancakePartnerIdentity` view
struct.

**The policy lives in the core, not at the ABI.** The first cut read
`peer.session_state` directly from `src/c_abi/host/session.zig`, which put the
verified-session-or-refuse decision in the C wrapper where no Zig consumer
could reach it. It belongs in `driver_core` beside `Identity`, the type
describing what *this* side advertises, with the C ABI and the native
`driver.Session` both wrapping one definition.

**A success means the signature was checked, and that is enforced rather than
documented.** `Options.verify_partner` defaults on and no ABI entry point turns
it off, but a Zig embedder can, so `partnerIdentity` refuses
`HostError.PartnerUnverified` on a session that does not verify its partner
instead of handing back an unchecked session key and locator claim. A partner
that has not sent its handshake half yet refuses
`HostError.HandshakeIncomplete`. Between them, a caller never has to ask how the
session was configured before trusting the session key as verified. The locator
remains the verified signer's claim unless `provenance` says a matching channel
proof authenticated its durable key. Injecting the removal of the signature
check makes an unverified session key come back indistinguishable from a
verified one, which is why this is a refusal rather than a flag on the result.

**The literal designator comparison is answered once, in the library.** The
signature covers the whole location record, so it binds the session signer to
the designator claim. `PartnerIdentity.designatorIsSessionKey` compares that
claim against the session key in the canonical hex encoding for a key
designator, so no binding re-derives the encoding. Equality is diagnostic only;
it does not authenticate durable ownership.

[ADR-0097](ADR-0097-captp-session-identity-attestation.md) later demoted that
comparison to a diagnostic and gave the report a third field. ADR-0109 then
removed the attestation provenance arm. Whether a partner's durable name was
authenticated is now `PartnerIdentity.provenance`, which every public tier
reports and which is positive only for matching authenticated-channel proof.
Fresh session keys are normally distinct from durable locator keys.

## Scope (what this does not decide)

- Nothing here changes what is signed or verified. The handshake verifies the
  session key's signature over the locator claim; this only makes those facts
  and their distinct provenance readable.
- The answer is meaningful for a key-designator transport, the
  `DesignatorScheme.key` set that `designatorSchemeForTransport` names. An
  address transport such as `tcp` designates a socket address the key does not
  determine, so `designatorIsSessionKey` is false for a verified `tcp` partner,
  and false is the correct answer rather than a failure. A caller that requires
  an authenticated durable peer asks `durableIdentityAuthenticated`; transport
  scheme and key equality are not substitutes for provenance.
- No policy is imposed on any application. `setExporterLocation` still accepts
  the locator it is given; deciding whether a caller may claim one is the
  application's call, and this is the fact it needs to decide.
- The views borrow session-owned bytes. Nothing here changes their lifetime:
  they are written once when the partner's handshake half arrives, never
  rewritten, and freed with the session.

## Alternatives Considered

- **Report the identity with a `verified` flag rather than refusing.**
  Rejected: it makes the unverified case representable, and every caller then
  has to remember to read the flag. A refusal makes the correct path the only
  path.
- **Expose the three accessors separately.** Rejected: they are one report with
  deliberately distinct meanings, and splitting them invites a caller to read
  the claimed designator without its verified session signer or provenance.
- **Let each binding hex-encode the key and compare.** Rejected: four
  re-derivations of one encoding, which is the shape `dial_plan` exists to
  prevent. An injected raw-bytes comparison passes a naive test, so the
  comparison earns a single owner.

## Consequences

- `driver_core` gains `PartnerIdentity` and two `HostError` arms.
  `src/c_abi/host` gains one view struct and two entry points, mirrored in all
  four bindings and pinned by the generated layout facts.
- `NotAWirePosition` was mapped while the neighbouring arms were being written:
  it fell through to `PANCAKE_ERR_INTERNAL` while the generated header for
  ADR-0092's `pancake_host_session_release_import` promised
  `PANCAKE_ERR_INVALID_ARGUMENT`. The mapping now matches the header.
- `test/driver/core_host_test.zig` holds the report contract: signature
  verification gates success, the canonical comparison remains literal, raw
  keyed-TCP locator claims stay unauthenticated, and matching channel proof
  supplies authenticated provenance without equating session and durable keys.

## Notes

Sibling of [ADR-0092](ADR-0092-deterministic-capability-release.md), which added
the other session-scoped verb in the same shape and across the same four
bindings. The key-designator vocabulary it reads is
[ADR-0075](ADR-0075-keyed-tcp-designator.md)'s; the token-versus-position
distinction it stays clear of is
[ADR-0091](ADR-0091-reserved-position-bands.md)'s.
