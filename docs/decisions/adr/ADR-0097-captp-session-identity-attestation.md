---
id: ADR-0097
status: accepted
date: 2026-07-31
tags: [captp, handshake, identity, keyed-tcp, transport]
decision: "Every CapTP session uses a fresh signing key. The signed locator is that session signer's claim, while durable peer authentication is separate connection provenance. ADR-0109 retires the durable-key hint credential. Without matching authenticated-channel proof, a durable locator claim remains unauthenticated."
supersedes: []
superseded_by: []
amends: [ADR-0068, ADR-0075, ADR-0093]
amended_by: [ADR-0105, ADR-0109, ADR-0113]
---

# ADR-0097 CapTP session identity and durable-key attestation

## Status

Accepted for fresh per-session signing keys and for keeping session identity,
durable locator identity, and provenance distinct. ADR-0109 retires the
durable-key credential and its provenance arm. ADR-0105's surviving rule is
that provenance belongs to the realized connection, not to a transport symbol.

The current contract is:

- The ordinary hello signature verifies control of `session_pubkey` and binds
  that session signer to the complete locator claim it signed.
- The signed designator and locator record remain claims. That signature does
  not prove durable locator ownership.
- A matching key supplied by the code that realized the authenticated channel
  is the only positive durable provenance. Raw `keyed-tcp` and `keyed-relay`
  claims are unauthenticated.
- A dial's expected key is a target requirement, not authentication evidence.
- Every session on every tier signs with its own key, derived from a
  per-process root. `driver.HostRuntime` draws that root at the I/O boundary,
  because the sans-io core draws no entropy. A caller's keyed identity is the
  durable identity and supplies the advertised designator. It never signs a
  session.
- `glowcap_host_new` takes a 64-byte seed. The first 32 bytes are the durable
  identity and stay stable, because a keyed locator's designator derives from
  it. The next 32 are the session-key root and must be fresh per process. A
  32-byte seed is refused. Each binding draws the root at its own entropy
  boundary (Rust `getrandom`, TypeScript and Wasm `crypto.getRandomValues`,
  Python `secrets`, Racket `crypto-random-bytes`).
- `PartnerIdentity` keeps session identity, durable identity, and provenance
  as three fields at every tier (`GLOWCAP_DURABLE_PROVENANCE_*` in C).
  `durableIdentityAuthenticated` is the check an API that needs a proved
  durable peer asks, and `Host.matchSturdyrefPeer` asks it.
- A `desc:handoff-receive` is signed by the key of the session the give
  arrived on (the give's `recipient_key`, which the exporter verifies), while
  its side and session names come from the recipient and exporter session
  where the withdrawal happens. Goblins draws the same line.
- A handoff certificate from an earlier connection resolves to nothing on a
  reconnect, because it names a session that no longer exists. That resolver
  is the only path from a withdrawal to a gift registry.
- Replaying a whole captured keyed-TCP hello is outside this guarantee. The
  hello signature covers a static locator claim, so fresh keys isolate honest
  reconnects without making a cleartext channel replay-safe.

Crossed sessions keep two axes apart. Ordering compares the two sessions' own
identifiers. Matching uses a durable identity the channel authenticated:
`refuseDuplicatePartnerKey` asks `Host.peer_by_durable` before the session-key
index, because two sessions to one peer never share a signing key. Only a
proved durable identity may collapse a session, so a partner that merely
asserts a name cannot condemn a live one. A transport that proves no durable
identity has no collapse here, and the declared-location match of ADR-0030 is
its only one. The index is keyed by the durable key's bytes, so the pre-apply
duplicate check can write a row from the borrowed hello view.

Evidence: the provenance, reconnect, and crossed-session scenarios in
[`test/driver/core_host/`](../../../test/driver/core_host/) (raw keyed-TCP keeps
both crossed sessions, and an iroh-shaped pair with channel proof collapses to
one survivor on both ends), and the two-session byte-fed scenario in
[`test/c_abi/host/authority_test.zig`](../../../test/c_abi/host/authority_test.zig).
The live `iroh-interop` check requires the designator to be the authenticated
node id and the session key to differ from it.

## Context

OCapN defines `session_pubkey` as the public half of a per-session key pair.
Goblins generates a fresh pair for every CapTP session. glowcap originally
seeded every session in a Host from one durable Host key. That collapsed two
identities:

- the durable peer identity named by a locator
- the ephemeral CapTP session identity named by `session_pubkey` and signed
  handoff records

A `keyed-tcp` locator's designator is the listener's durable Ed25519 key, while
the TCP stream is cleartext and authenticates nothing. The dial-side proof was
`session_pubkey == locator designator`, which a fresh session key makes false.
iroh has the needed lower-layer fact (QUIC authenticates the durable endpoint
key and protects the stream carrying the hello), and WebRTC has an authenticated
pipe (DTLS verifies the fingerprint exchanged through capability-authorized
signaling).

## Decision

### Every CapTP session has a fresh key

Each `HostSession` receives a fresh Ed25519 signing seed from the adapter entropy
boundary. The sync no-I/O core generates no entropy. Zig drivers draw the
seed while opening a connection. Byte-fed C and Wasm Hosts receive it through
an explicit entropy action or caller-provided bytes. Tests use deterministic
seeds.

The session key signs `acceptable_location` and every handoff record that names
that session. Reconnecting the same peers creates a different session public
key and therefore a different handoff session name. An old give cannot name the
new connection merely because the durable peers are unchanged.

`DesignatorScheme.key` describes locator grammar. It does not mean the
designator bytes equal `session_pubkey`.

### Identity reporting carries three facts

Host state retains these separately:

- `session_pubkey`, the exact CapTP session identity
- peer `(transport, designator)`, the locator identity
- verification provenance, set by the realized connection (ADR-0105)

`PartnerIdentity` reports all three. `designatorIsSessionKey` is a literal
comparison for diagnostics and is not an authentication predicate. APIs that
require durable peer authentication ask the provenance-bearing predicate.

This amends ADR-0093: the signature under `session_pubkey` proves that session
key's claim about its locator. Durable ownership comes from independent channel
proof.

### Crossed hellos and handoff use the right identity

Crossed-hello matching and crossed-hello ordering are separate operations:

1. Match an inbound hello to an outstanding outbound dial by verified durable
   peer identity where available, or by the OCapN-declared location on an
   address transport with its existing stated weakness.
2. Derive the two OCapN session identifiers from the outbound connection's
   fresh local `session_pubkey` and the inbound connection's fresh remote
   `session_pubkey`.
3. Sort their serialized identifiers and abort the lower session, exactly as
   the OCapN crossed-hellos algorithm requires.

Durable identity detects which two connection attempts race. Fresh session
identity selects the winner. Established peer lookup and exact handoff-session
lookup are separate indexes. An unverified partner-declared key is never
promoted to durable Host identity.

The exact `session_pubkey` continues to name a handoff session, verify gives,
and index live session coordinators. It is never used as a reconnect-stable peer
id. On an honest reconnect, a fresh key means an old give does not name the new
session coordinator. A replayed complete keyed-TCP hello can revive its old
static session claim on another cleartext connection.

This amends ADR-0068's reused-Host-key assumption while keeping its
one-Host/many-session and crossed-hello structure. It amends ADR-0075's
equality pin and ADR-0093's partner report.

## Retired credential mechanism

The first design had keyed-TCP and keyed-relay hellos carry a
`session-key-attestation` hint: a 64-byte signature by the durable key over the
canonical Syrup record
`<session-key-attestation-v1 transport designator session-pubkey>`, authorizing
the fresh session key for that locator identity. ADR-0105 extended it to every
key-scheme transport. ADR-0109 retired the credential, its hint, and its
provenance arm. A raw `keyed-tcp` or `keyed-relay` claim is unauthenticated, and
only matching authenticated-channel proof raises provenance.

## Scope (what this does not decide)

- keyed-TCP is cleartext and provides no channel confidentiality, integrity,
  freshness, or replay resistance.
- Locator identity is `(transport, designator)`. Hints stay outside equality.
- OCapN handoff descriptor shapes and signature domains are unchanged.
- Sturdyref peer matching is ADR-0098's decision.

## Alternatives Considered

- **Keep one durable key as every CapTP session key.** Rejected: it contradicts
  per-session identity and lets reconnect reuse handoff names.
- **Change fresh keys everywhere except keyed-TCP.** Rejected: CapTP session
  semantics would depend on the selected transport and keyed-TCP reconnects
  would retain the defect.
- **Treat any key-shaped designator as proof.** Rejected: syntax proves no key
  possession.
- **Add a keyed-TCP transport preface.** Rejected: it duplicates CapTP hello
  framing, forces the transport resident to learn CapTP session keys, and does
  not fit the byte-fed Host.

## Consequences

- Signing-key entropy is per session rather than per Host.
- The engine's expected-partner contract is a verification strategy over durable
  identity and session identity, not `expected_partner_key == session_pubkey`.
- Host session registries distinguish durable peer lookup from exact CapTP
  session lookup.
- ADR-0068, ADR-0075, and ADR-0093 remain accepted in substance and are amended
  by this separation.

## Notes

ADR-0096 owns Host-scoped capability identity and exact gifts. ADR-0098 owns
sturdyref peer authority.
