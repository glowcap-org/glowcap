---
id: ADR-0098
status: accepted
date: 2026-07-31
tags: [host, identity, publication, sturdyref]
decision: "Host-facing enlivenment retains the complete sturdyref and refuses a mismatched or unverified selected peer before wire traffic unless a low-level caller explicitly opts into assertion-only TCP semantics. Hints remain routing advice. Mutable aliases structurally cannot enter the reserved, versioned namespace used by randomly minted durable swiss names."
supersedes: []
superseded_by: []
amends: [ADR-0012]
amended_by: [ADR-0113]
---

# ADR-0098 Sturdyref peer authority

## Status

Accepted and shipped. This is the publication-namespace companion to ADR-0096.
The shipped state below cites the checks that hold each clause.

## Context

A sturdyref carries `(peer locator, swiss)`. An enlivenment that discards the
peer locator and fetches the swiss on a caller-selected session lets equal swiss
bytes at peers A and B redirect A's sturdyref to B. Every tier therefore
retains and checks the complete locator: the session-level path does, and
`Host.enlivenSelectOrDial` picks the peer the sturdyref names, dialing it when
no live session reaches it.

The peer locator selects the authority that may interpret the swiss, which is
meaningful only at that peer. Locator hints can change without changing the
peer, so they help select a route but do not participate in identity.

The wire carries no publication generation. A sturdyref holder cannot recover
an older object after its swiss is rebound unless that older identity is
encoded in the swiss itself.

## Decision

### Enliven retains and checks the complete sturdyref

The Host-facing enliven verb accepts a complete `model.SturdyRef`. The
session-level form proves that its caller-selected session's recorded peer
identity equals the sturdyref's `(transport, designator)`. Hints are routing
advice and are ignored by the equality check.

A session-level convenience may use an already selected session, but it runs
the same peer check. A mismatch fails before bootstrap fetch, cache lookup, or
any other wire traffic. The C ABI, Wasm, and every binding retain the peer
locator until that check completes. No tier accepts swiss bytes plus an
unrelated session as equivalent authority.

The strength of the peer proof follows the netlayer. An authenticated
key-designator transport uses ADR-0097's verified durable identity. A plain TCP
dial may use its selected address as non-cryptographic dial-target provenance.
An accepted plain-TCP session has only the partner's assertion about its
listening address. Host-facing enlivenment refuses that session with typed
`PeerIdentityUnverified` before emitting wire traffic. The high-level Host verb
selects or dials the sturdyref peer, so the caller supplies no session.

A low-level session caller may explicitly request `assertion_only` semantics
when interoperability requires trusting that accepted peer claim. The opt-in
is named at the call site and reported as unverified provenance.

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

- mints an unpredictable swiss from the adapter entropy boundary
- binds it to one local target
- refuses reassignment of that swiss to another target
- returns the complete sturdyref containing the Host's peer locator and swiss

Removing such a durable publication reclaims its live row. Future enlivenment
fails. A later random mint does not reuse the removed name: uniqueness relies on
the same cryptographic assumption as swiss unguessability, and the mint still
checks active rows. An old sturdyref therefore misses instead of retargeting.
Durability across process restart still requires durable registry storage and is
outside this record.

Mutable aliases remain available under an explicitly different discovery API.
The safe publication surface never mints or labels a sturdyref from one: equal
sturdyref bytes must not silently acquire different authority after a rebind.
Low-level code may parse a remote `(peer, swiss)` supplied by another system,
and glowcap does not vouch that the remote registry keeps that swiss
non-reassignable.

### Namespace separation is the retention rule

Only live mutable and durable rows consume Host publication storage. Removal
reclaims either row. There is no tombstone set and no tombstone exhaustion cap.
The durable prefix is the cross-restart invariant that prevents a mutable alias
from taking over an old sturdyref's bytes. Persistent durable rows are still a
separate storage feature. Without them, restart makes old sturdyrefs miss.

## Required evidence

Acceptance requires:

1. Give peers A and B the same swiss. Enliven A's sturdyref on B's selected
   session and prove refusal occurs before any fetch frame is emitted.
2. Enliven two sturdyrefs whose locators differ only in hints and prove they
   select the same peer identity and session-local dedup row.
3. Enliven locators that differ in transport or designator and prove they do not
   share a session or cache row.
4. Run complete-sturdyref enlivenment through Zig, C, Wasm, and every
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

## Shipped state

`HostSession` retains the transport, and `Host.enliven` accepts a complete
`model.SturdyRef`. It compares transport and designator before cache lookup or
bootstrap fetch. Key-designator sessions require the handshake proof. A dialed
address session reports `dial_target`. An accepted address session refuses
`PeerIdentityUnverified` unless native low-level code names `assertion_only`,
whose result reports that provenance.

The C host ABI accepts the complete sturdyref URI with the same binary
function shape, and Rust, TypeScript/Wasm, Python, and Racket pass it through
without extracting swiss bytes. Native and C evidence proves mismatch refusal
emits no fetch frame, differing hints reuse the same session cache row, and the
accepted-TCP opt-in remains visibly unverified. The Wasm check proves the same
wrong-peer refusal through linear-memory exports. Each binding dogfood refuses
a wrong-peer sturdyref before its successful enlivenment.

Session-scoped and Host-level enlivenment read the canonical persistent
sturdyref form, independent of live or preferred profiles. The Host's named profile variant
parses authority conveyed in another form.
Applications that already hold a typed locator and publication name use Host
`fetchAt`, so neither a CapTP version nor a sturdyref codec leaks into
application code.

The native authority checks are held by
[`test/driver/core_host/`](../../../test/driver/core_host/), and
the C ABI and hint-insensitive cache checks are held by
[`test/c_abi/host/verbs_test.zig`](../../../test/c_abi/host/verbs_test.zig). The binding
proofs live in the
[Rust session test](../../../bindings/rust/src/session_tests.rs),
[TypeScript smoke](../../../bindings/ts/dogfood/zig_smoke.ts),
[Python smoke](../../../bindings/python/zig_smoke.py),
[Racket smoke](../../../bindings/racket/zig-smoke.rkt), and
[TypeScript Wasm handshake smoke](../../../bindings/ts/web/test/wasm_handshake_smoke.ts).

The session core reserves the versioned durable prefix (`glowcap-durable-1-` plus
32 random hex digits) and refuses a mutable bind under it with a typed
`ReservedDurableNamespace`. `driver_core.Host.publishDurable` mints in that
namespace from caller-supplied entropy, checks the active table, and
`removeDurable` reclaims the row. `driver.Server.publishDurable` draws the
entropy at the adapter boundary and returns the complete sturdyref URI, and
`driver.HostRuntime.enliven` selects a live matching session or dials the
sturdyref peer before fetching. The C ABI carries the same verbs as
`glowcap_host_publish_durable` / `glowcap_host_remove_durable`, wrapped by all
four bindings. A C embedder composes select-or-dial from its own dial actions.
The namespace refusal, mint, removal, restart miss, and issued-authority
survival are held by
[`test/driver/durable_publication_test.zig`](../../../test/driver/durable_publication_test.zig)
and the durable-namespace scenario in
[`test/driver/core_host/`](../../../test/driver/core_host/).
The [Python smoke](../../../bindings/python/zig_smoke.py) and
[Racket smoke](../../../bindings/racket/zig-smoke.rkt) run the minted-name
fetch, removal miss, and surviving-ref scenes over the C ABI.

Retaining the transport adds no identity allocation: a dialed session stores
transport and selected designator in the block it already requires.
An accepted session owns one transport block. With the Vat owned by the Host,
the `HostSession` shell stays within `host_session_struct_budget_bytes`. The Vat and its queue
chunks are charged once per Host. The
[performance page](../../../site/content/performance.smd) charts the current
costs.

## Scope (what this does not decide)

- The sturdyref wire shape and equality remain `(transport, designator, swiss)`.
  Hints do not participate.
- Signed or revocable sturdyref formats are not introduced.
- Durable bootstrap persistence across process restart remains unimplemented.
- CapTP session-key and durable-peer authentication are ADR-0097's decision.
- Host-scoped live refs, publication targets, and exact gifts are ADR-0096's
  decision.

## Alternatives Considered

- **Trust the caller-selected session.** Rejected: it discards half of the
  authority and permits same-swiss cross-peer substitution.
- **Include hints in peer identity.** Rejected: OCapN defines transport and
  designator as identity. Hints are changeable route advice.
- **Hide a publication generation in Host state.** Rejected: the holder and wire
  carry no generation, so another process could not reproduce that meaning.
- **Forbid mutable bootstrap names.** Rejected: mutable discovery is useful when
  named for what it is and kept separate from sturdyref minting.
- **Make every caller-chosen swiss non-reassignable.** Rejected: it conflates
  low-level bootstrap lookup with the safe high-level sturdyref minting API.
- **Retain removed durable names as Host-lifetime tombstones.** Rejected: the
  retargeting threat crosses restart, where an in-memory
  tombstone disappears. A reserved namespace prevents mutable takeover without
  retained rows or an exhaustion cap.
- **Treat an accepted TCP peer claim as verified.** Rejected: the address is an
  assertion, not evidence. The exceptional trust choice must be explicit.

## Consequences

- Host-facing APIs retain `model.SturdyRef` until peer selection is verified.
- The current session-local cache remains valid after the Host-level peer
  precondition. Its key does not grow a redundant locator copy.
- Publication APIs expose the authority distinction directly.
- Durable and mutable swiss namespaces are disjoint by construction. Removed
  rows are reclaimable and old sturdyrefs fail closed across restart.
- ADR-0012's model shape, feature gate, and dedup mechanism remain accepted.
  This record amends its statement that peer matching is an adapter concern: the
  check is mandatory at the Host boundary.

## Notes

ADR-0096 supplies the exact target identity a publication or gift retains.
ADR-0097 supplies cryptographic durable-peer provenance where the netlayer can
provide it.
