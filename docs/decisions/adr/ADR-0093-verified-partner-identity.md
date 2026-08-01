---
id: ADR-0093
status: accepted
date: 2026-07-29
tags: [captp, host, identity, bindings]
decision: "An application can ask a session who its partner is and get an answer the handshake proved rather than one the partner asserted; unverified and incomplete handshakes refuse."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0097]
---

# ADR-0093 Verified Partner Identity

## Problem

The handshake already learns everything an application needs to know about who
it is talking to. A keyed `op:start-session` carries an Ed25519 signature over
the partner's own `<my-location …>` record, and
`engine.verifyPartnerStartSession` checks it before the session opens and before
the key is recorded. The session then holds the partner's key, its signed
designator, and the verbatim location record those came from.

None of that was reachable. `Session.partnerSessionKey`,
`partnerDesignator`, and `partnerLocatorRaw` are core-side accessors, and
`src/c_abi/host/symbols.zig` exported no partner-identity entry point at all,
so no binding could read the identity the handshake had already verified.

What that costs shows up the moment an application routes on a name a caller
supplies. The rooms directory takes an exporter locator from the wire and
stamps it on the session, overriding the partner's signed location, so anyone
reaching the directory can point introductions at a third party. The
application cannot fix that properly on its own, because it has no way to ask
who the caller actually is.

## Decision

Add `driver_core.PartnerIdentity` and `Host.partnerIdentity(session)`, expose
them natively as `driver.Session.partnerIdentity()`, and wrap them for C as
`pancake_host_session_partner_identity` with a `PancakePartnerIdentity` view
struct.

**The policy lives in the core, not at the ABI.** The first cut read
`peer.session_state` directly from `src/c_abi/host/session.zig`, which put the
verified-or-refuse decision in the C wrapper where no Zig consumer could reach
it. It belongs in `driver_core` beside `Identity`, the type describing what
*this* side signs, with the C ABI and the native `driver.Session` both wrapping
one definition.

**A success means the signature was checked, and that is enforced rather than
documented.** `Options.verify_partner` defaults on and no ABI entry point turns
it off, but a Zig embedder can, so `partnerIdentity` refuses
`HostError.PartnerUnverified` on a session that does not verify its partner
instead of handing back bytes nothing proved. A partner that has not sent its
handshake half yet refuses `HostError.HandshakeIncomplete`. Between them, a
caller never has to ask how the session was configured before trusting what it
read. Injecting the removal of that check makes an unverified key come back
indistinguishable from a proved one, which is the whole reason the refusal is a
refusal and not a flag on the result.

**The designator question is answered once, in the library.** The signature
covers the whole location record, so the designator is bound to the key by the
same signature. `PartnerIdentity.designatorIsSessionKey` compares the
designator against the key in the canonical hex a key designator is spelled in,
and `pancake_host_session_partner_designator_is_key` wraps it, so no binding
re-derives that encoding. This is the same reasoning that put dial resolution in
`driver_core.dial_plan` rather than in four bindings.

## Scope (what this does not decide)

- Nothing here changes what is signed or verified. The handshake already
  proved all of it; this only makes the result readable.
- The answer is meaningful for a key-designator transport, the
  `DesignatorScheme.key` set that `designatorSchemeForTransport` names. An
  address transport such as `tcp` designates a socket address the key does not
  determine, so `designatorIsSessionKey` is false for a verified `tcp` partner,
  and false is the correct answer rather than a failure. A caller that wants
  "this locator is the partner's own" checks the transport's scheme first.
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
- **Expose the three accessors separately.** Rejected: they are one fact the
  handshake established, and splitting them invites a caller to read the
  designator without the key that binds it.
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
- `test/driver/core_host_test.zig` holds the contract, validated by injection:
  dropping the verification check, comparing raw key bytes instead of canonical
  hex, and reporting an absent key as an empty success each fail exactly one
  test. No case drives `iroh`, `webrtc`, or `keyed-relay`, so the
  key-designator claim rests on `keyed-tcp` plus the shared transport table.

## Notes

Sibling of [ADR-0092](ADR-0092-deterministic-capability-release.md), which added
the other session-scoped verb in the same shape and across the same four
bindings. The key-designator vocabulary it reads is
[ADR-0075](ADR-0075-keyed-tcp-designator.md)'s; the token-versus-position
distinction it stays clear of is
[ADR-0091](ADR-0091-reserved-position-bands.md)'s.
