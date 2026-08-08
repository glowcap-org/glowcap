---
id: ADR-0098
status: accepted
date: 2026-07-31
tags: [host, identity, publication, sturdyref]
decision: "Host-facing enlivenment retains the complete sturdyref and refuses a mismatched or unverified selected peer before wire traffic unless a low-level caller explicitly opts into assertion-only TCP semantics. Hints remain routing advice. Mutable aliases structurally cannot enter the reserved, versioned namespace used by randomly minted durable swiss names."
supersedes: []
superseded_by: []
amends: [ADR-0012]
amended_by: []
---

# ADR-0098 Sturdyref peer authority

## Status

Accepted. This is the publication-namespace companion to ADR-0096. Enlivenment
migration steps 1–2, the durable/mutable namespace split, and the native
Host-level select-or-dial enliven all ship; the evidence standing below cites
the checks that hold each clause.

## Context

A sturdyref carries `(peer locator, swiss)`. Before migration steps 1–2,
Host-facing C and binding enlivenment parsed that shape, discarded the peer
locator, and fetched the swiss on a caller-selected session. Equal swiss bytes
at peers A and B could therefore redirect A's sturdyref to B. Every tier now
retains and checks the complete locator: the session-level path does, and
`Host.enlivenSelectOrDial` picks the peer the sturdyref names, dialing it when
no live session reaches it.

This is the same scope error as a mutable publication name being mistaken for
an object. The peer locator selects the authority that may interpret the swiss;
the swiss is meaningful only at that peer. Locator hints can change without
changing the peer, so they help select a route but do not participate in
identity.

The wire also carries no publication generation. A sturdyref holder cannot
recover an older object after its swiss is deliberately rebound unless that
older identity was encoded in the swiss itself.

## Decision

### Enliven retains and checks the complete sturdyref

The Host-facing enliven verb accepts a complete `model.SturdyRef`. The shipped
session-level form proves that its caller-selected session's recorded peer
identity equals the sturdyref's `(transport, designator)`. Hints are routing
advice and are ignored by the equality check.

A session-level convenience may use an already selected session, but it runs
the same peer check. A mismatch fails before bootstrap fetch, cache lookup, or
any other wire traffic. The C ABI, Wasm, and every binding retain the peer
locator until that check completes; no tier accepts swiss bytes plus an
unrelated session as equivalent authority.

The strength of the peer proof follows the netlayer. An authenticated
key-designator transport uses ADR-0097's verified durable identity. A plain TCP
dial may use its selected address as explicitly non-cryptographic dial-target
provenance. An accepted plain-TCP session has only the partner's assertion
about its listening address. Host-facing enlivenment refuses that session with
typed `PeerIdentityUnverified` before emitting wire traffic. Step 4 adds the
high-level Host verb that selects or dials the sturdyref peer instead of asking
the caller to supply a session.

A low-level session caller may explicitly request `assertion_only` semantics
when interoperability requires trusting that accepted peer claim. The opt-in
is named at the call site and remains reported as unverified provenance. There
is no default path on which namespace consistency is mistaken for peer proof.

Once the peer matches, ADR-0012's feature, open-session, in-flight, and
session-local dedup rules remain. The cache key can stay swiss-only because the
session has already fixed the peer that owns that namespace.

### Durable names and mutable aliases are different namespaces

Durable minted swiss names occupy a reserved, versioned binary namespace: a
fixed domain prefix followed by cryptographically random bytes. The low-level
bootstrap surface may bind, replace, or remove a caller-chosen mutable alias,
but structurally refuses that prefix. The durable publication API mints only in
that namespace and checks the active durable table before insertion. The two
surfaces therefore cannot collide, including after restart.

Rebinding a mutable alias affects future discovery only. Existing live refs and
ADR-0096 gifts retain their exact targets.

The safe sturdyref publication API instead:

- mints an unpredictable swiss from the adapter entropy boundary;
- binds it to one local target;
- refuses reassignment of that swiss to another target;
- returns the complete sturdyref containing the Host's peer locator and swiss.

Removing such a durable publication reclaims its live row. Future enlivenment
fails. A later random mint does not deliberately reuse the removed name;
uniqueness relies on the same
cryptographic assumption as swiss unguessability and still checks active rows.
An old sturdyref therefore misses rather than retargets. Durability across
process restart still requires durable registry storage and is outside this
record.

Mutable aliases remain available under an explicitly different discovery API.
The safe publication surface never mints or labels a sturdyref from one: equal
sturdyref bytes must not silently acquire different authority after a rebind.
Low-level code may parse a remote `(peer, swiss)` supplied by another system,
but pancake does not thereby vouch that the remote registry keeps that swiss
non-reassignable.

### Namespace separation is the retention rule

Only live mutable and durable rows consume Host publication storage. Removal
reclaims either row; there is no tombstone set and no tombstone exhaustion cap.
The durable prefix is the cross-restart invariant that prevents a mutable alias
from taking over an old sturdyref's bytes. Persistent durable rows are still a
separate storage feature; without them, restart makes old sturdyrefs miss.

## Required evidence

Acceptance requires:

1. Give peers A and B the same swiss. Enliven A's sturdyref on B's selected
   session and prove refusal occurs before any fetch frame is emitted.
2. Enliven two sturdyrefs whose locators differ only in hints and prove they
   select the same peer identity and session-local dedup row.
3. Enliven locators that differ in transport or designator and prove they do not
   share a session or cache row.
4. Run complete-sturdyref enlivenment through native Zig, C, Wasm, and every
   binding, including the mismatch refusal.
5. Refuse a mutable alias under the reserved durable prefix. Mint a durable
   swiss, remove it, simulate restart with an empty durable registry, and prove
   the old sturdyref misses. A mutable alias still cannot retarget it, and a
   fresh durable mint does not reuse the old bytes.
6. Rebind a mutable alias and prove a fresh fetch observes the replacement while
   an issued ref and deposited gift still reach the original target.
7. On accepted plain TCP, prove default enlivenment returns
   `PeerIdentityUnverified` without a fetch frame and Host-level enlivenment
   selects or dials the sturdyref peer instead. Prove the named `assertion_only`
   opt-in can proceed and reports unverified provenance.

## Migration order

1. Add one Host peer-match helper over `(transport, designator)` and use it on
   native session-level enliven before any fetch action.
2. Carry the full sturdyref through the C ABI, generated layout facts, Wasm, and
   all bindings; delete swiss-only Host-facing enliven verbs.
3. Add separate mutable-alias and minted-durable publication verbs, with entropy
   as an explicit Host action and namespace separation enforced at both APIs.
4. Add Host-level select-or-dial convenience only after every existing-session
   path shares the same peer check.

Steps 1–2 precede ADR-0096's capability-handle ABI migration. They close a
narrow authority boundary while the existing reference representation is
still available, rather than coupling two ABI changes into one landing.

## Migration standing

All four steps ship. `HostSession` retains the actual connection
transport, and `Host.enliven` accepts a complete `model.SturdyRef`. It compares
transport and designator before cache lookup or bootstrap fetch. Key-designator
sessions require the handshake proof; a dialed address session reports
`dial_target`; an accepted address session refuses `PeerIdentityUnverified`
unless native low-level code names `assertion_only`, whose result reports that
provenance explicitly.

The C host ABI now accepts the complete sturdyref URI with the same binary
function shape, and Rust, TypeScript/Wasm, Python, and Racket pass it through
without extracting swiss bytes. Native and C evidence proves mismatch refusal
emits no fetch frame, differing hints reuse the same session cache row, and the
accepted-TCP opt-in remains visibly unverified. The Wasm check proves the same
wrong-peer refusal through linear-memory exports. Each binding dogfood refuses
a wrong-peer sturdyref before its successful enlivenment.

The native authority checks are held by
[`test/driver/core_host_test.zig`](../../../test/driver/core_host_test.zig), and
the C ABI and hint-insensitive cache checks are held by
[`test/c_abi/host_test.zig`](../../../test/c_abi/host_test.zig). The binding
proofs live in the
[Rust session test](../../../bindings/rust/src/session_tests.rs),
[TypeScript smoke](../../../bindings/ts/dogfood/zig_smoke.ts),
[Python smoke](../../../bindings/python/zig_smoke.py),
[Racket smoke](../../../bindings/racket/zig-smoke.rkt), and
[TypeScript Wasm handshake smoke](../../../bindings/ts/web/wasm_handshake_smoke.ts).

Steps 3–4 ship the namespace split and the select-or-dial front door. The
session core reserves the versioned durable prefix (`pancake-durable-1-` plus
32 random hex digits) and refuses a mutable bind under it with a typed
`ReservedDurableNamespace`; `driver_core.Host.publishDurable` mints in that
namespace from caller-supplied entropy, checks the active table, and
`removeDurable` reclaims the row. `driver.Server.publishDurable` draws the
entropy at the adapter boundary and returns the complete sturdyref URI, and
`driver.PollHost.enliven` selects a live matching session or dials the
sturdyref peer before fetching. The C ABI carries the same verbs as
`pancake_host_publish_durable` / `pancake_host_remove_durable`, wrapped by all
four bindings; a C embedder composes select-or-dial from its own dial actions.
The namespace refusal, mint, removal, restart miss, and issued-authority
survival are held by
[`test/driver/durable_publication_test.zig`](../../../test/driver/durable_publication_test.zig)
and the durable-namespace scenario in
[`test/driver/core_host_test.zig`](../../../test/driver/core_host_test.zig);
the [Python smoke](../../../bindings/python/zig_smoke.py) and
[Racket smoke](../../../bindings/racket/zig-smoke.rkt) run the minted-name
fetch, removal miss, and surviving-ref scenes over the C ABI.

Retaining the transport adds no separate identity allocation: a dialed session
stores transport and selected designator in the one block it already required;
an accepted session owns one transport block. After the shared Vat moved out of
the per-connection shell, the `HostSession` shell is 496 bytes at its ceiling:
464 when this decision landed, plus 32 for ADR-0097's per-session signing
seed. The 448-byte Vat and its 4,152-byte fixed queue chunk are now charged
once per Host.

## Scope (what this does not decide)

- The sturdyref wire shape and equality remain `(transport, designator, swiss)`;
  hints do not participate.
- Signed or revocable sturdyref formats are not introduced.
- Durable bootstrap persistence across process restart remains unimplemented.
- CapTP session-key and durable-peer authentication are ADR-0097's decision.
- Host-scoped live refs, publication targets, and exact gifts are ADR-0096's
  decision.

## Alternatives Considered

- **Trust the caller-selected session.** Rejected: it discards half of the
  authority and permits same-swiss cross-peer substitution.
- **Include hints in peer identity.** Rejected: OCapN defines transport and
  designator as identity; hints are changeable route advice.
- **Hide a publication generation in Host state.** Rejected: the holder and wire
  carry no generation, so another process could not reproduce that meaning.
- **Forbid mutable bootstrap names.** Rejected: mutable discovery is useful when
  named honestly and kept separate from sturdyref minting.
- **Make every caller-chosen swiss non-reassignable.** Rejected: it conflates
  low-level bootstrap lookup with the safe high-level sturdyref minting API.
- **Retain removed durable names as Host-lifetime tombstones.** Rejected: the
  realistic retargeting threat crosses restart, exactly where an in-memory
  tombstone disappears. A reserved namespace prevents mutable takeover without
  retained rows or an exhaustion cap.
- **Treat an accepted TCP peer claim as verified.** Rejected: the address is an
  assertion, not evidence. The exceptional trust choice must be explicit.

## Consequences

- Host-facing APIs retain `model.SturdyRef` until peer selection is verified.
- The current session-local cache remains valid after the Host-level peer
  precondition; its key does not grow a redundant locator copy.
- Publication APIs expose the authority distinction directly instead of relying
  on comments about whether a swiss may be reused.
- Durable and mutable swiss namespaces are disjoint by construction. Removed
  rows are reclaimable and old sturdyrefs fail closed across restart.
- ADR-0012's model shape, feature gate, and dedup mechanism remain accepted.
  This record amends its statement that peer matching is merely an adapter
  concern by making that check mandatory at the Host boundary.

## Notes

ADR-0096 supplies the exact target identity a publication or gift retains.
ADR-0097 supplies cryptographic durable-peer provenance where the netlayer can
provide it.
