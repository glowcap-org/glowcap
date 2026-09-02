---
id: ADR-0006
status: accepted
date: 2026-05-01
tags: [handshake, bootstrap, lifecycle, substrate, start-session]
decision: The `op:start-session` exchange and the bootstrap-`'fetch` flow are codec-neutral. The core ships their no-I/O halves (the wire record, the `negotiating` to `open` session machine, the sync in-process handshake driver, and both the bootstrap-fetch initiator and the inbound-`'fetch` responder (a session-owned swissnum-to-export-id `bootstrap` registry plus engine-side recognition and reply synthesis)) and an adapter drives the wire loop. Production netlayers are out of scope here; the netlayer contract is ADR-0043.
supersedes: []
superseded_by: []
---

# ADR-0006 Handshake substrate and bootstrap fetch

## Context

`op:start-session` is the exchange that promotes a session from `negotiating` to
`open`; the bootstrap object at a fixed export id is how a peer reaches a
capability behind a swissnum (CapTP `Specification.md` § op:start-session, § The
bootstrap Object). Both shapes are codec-neutral and spec-pinned, and both split
cleanly into a pure-computation half and a wire-driving half. The core owns the
pure half: the model record, the session state machine, the sync handshake
driver, and the bootstrap-fetch initiator. An adapter owns the wire loop.

Engages the [First Principles](../../../AGENTS.md#first-principles) _the
portable core stays sync and no-I/O_ (the handshake driver shuttles frames
in-process; no transport), _session state is authoritative_ (the lifecycle gate
and the bootstrap export install live in the session), and _protocol correctness
before convenience_ (the spec-pinned exchange installs the bootstrap export
rather than a shortcut).

## Decision

**Wire record.** [`Message.start_session`](../../../src/ocapn/model/mod.zig) is
a four-field record. `captp_version`, `session_pubkey`, `acceptable_location`,
`acceptable_location_sig`: matching CapTP § op:start-session. `session_pubkey`
and `acceptable_location_sig` are slice-borrowed byte views
([`SessionPubkey`](../../../src/ocapn/model/mod.zig) /
[`LocationSig`](../../../src/ocapn/model/mod.zig)); `acceptable_location` is the
existing `PeerLocator`. On receive the session compares `captp_version` for
strict equality against its own profile and rejects a mismatch with
`Error.CaptpVersionMismatch`.

**Session machine.**
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) gates the
`negotiating` state: `op:start-session` (and `op:abort`) is the only traffic
admitted before `open`; everything else is `Error.UnexpectedMessage` until
promotion. The session tracks both halves (local sent, remote received); once
both are observed it runs `transitionToOpen`, which installs the bootstrap
export at `BOOTSTRAP_EXPORT_ID = 0` (the one fallible step, run before the state
flip so a failed install stays atomic) and reserves locally-allocated export ids
past it.

**Handshake driver.**
[`src/ocapn/engine/pairing.zig`](../../../src/ocapn/engine/pairing.zig) drives
the in-process exchange with no transport: `paired` (stub-zero key / signature)
and `pairedWithKeys` (real Ed25519; see Peer authentication below) send each
side's `op:start-session`, then `shuttleUntilQuiescent` steps both peers and
feeds each outbound frame into the partner until both reach idle with no traffic
in flight. Both peers land in `open`. Entropy stays at the caller,
`pairedWithKeys` takes 32-byte seeds; the core generates no randomness.

**Bootstrap fetch (initiator).**
[`src/ocapn/engine/fetch.zig`](../../../src/ocapn/engine/fetch.zig) carries the
initiator halves: `prepareFetchSwissnum` allocates the resolver export plus
outbound answer and builds the canonical `op:deliver` to the bootstrap object
with `args = [fetch <swissnum>]` (adding the resolver-callback `resolve_me_desc`
only on the Goblins V1.0 profile); `tryMatchFetchOutcome` recognizes both
engine-local settlement shapes: a semantic `model.Message.resolve` keyed on the
answer, used by in-process helpers and tests, and an `op:deliver` to the
resolver export carrying `[fulfill|break, …]`; it hands unrelated traffic back
for the caller to buffer. Profile-specific wire rules live in the codecs and
session V1.0/next translation: next sends no wire `op:resolve` (ADR-0111). The
adapter sends the prepared message and feeds inbound frames to the matcher.

**Bootstrap fetch (responder).** Serving an inbound `'fetch` against the local
bootstrap exporter is codec-neutral and splits the same way: a passive session
lookup plus engine-side recognition and synthesis.

- The session owns a `bootstrap` registry, a swissnum-to-export-id
  [`StringHashMapUnmanaged`](../../../src/ocapn/session/mod.zig). It starts
  empty at `transitionToOpen` (the bootstrap export row at id 0 is already
  installed); adapters populate it through
  `Peer.registerBootstrapCap(swissnum)`, which allocates the export and returns
  its id (config-time, no wire). The session stays a passive observer,
  `bootstrapLookup(swissnum) -> ?export_id` is the only read; the session never
  synthesizes a message, matching the V1.0 resolver-callback separation.
- The engine
  ([`src/ocapn/engine/bootstrap.zig`](../../../src/ocapn/engine/bootstrap.zig))
  recognizes the inbound shape (`pendingBootstrapRequest`: target export 0,
  `args = [Symbol "fetch", Bytes swissnum]`, reply route lifted from `answer` vs
  `resolve_me_desc`) and synthesizes the reply (`resolveForSwissnum`):
  `Fulfill(Near(<export>))` for a known swissnum, `Break("unknown swissnum")`
  for a miss. The reply routes through a resolver-callback `op:deliver`
  carrying `[fulfill|break, …]`: next installs the callback with the mandatory
  listener, while Goblins V1.0 uses the inline `resolve_me_desc` resolver
  (reusing the existing `encodeResolverCallback`).
- The recognition branch lives in `Peer.dispatchOwnedFrameInner` after the
  pipelining branch and before the event append: on a match it runs
  `recordRecv`, emits `Event.deliver` for observability, then pushes the
  synthesized reply onto `pending_send` for `step` to encode. A non-matching
  deliver falls through unchanged. A malformed `'fetch` (wrong args) fails the
  structural match and surfaces as an ordinary deliver event: the application's
  concern, not a session refusal. Because the table is host-populated
  config-time state rather than partner-driven, it carries no resource cap
  (consistent with [ADR-0025](ADR-0025-session-table-cap-policy.md)).

Serving an inbound sturdyref enliven needs no separate code: enliven on the wire
**is** a `'fetch` to the partner's bootstrap, so the responder above handles it
([ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) is unchanged).

**Peer authentication.** The handshake is authenticated by an Ed25519 signature
over the Goblins-canonical `<my-location $acceptable-location>` record, not the
raw locator bytes. Signing the wrapped record matches Goblins's `pk-sign`
domain, so a Goblins peer verifies a glowcap signature and the reverse holds.
[`canonicalLocationSignedBytes`](../../../src/ocapn/codec/syrup/encode.zig) is
the profile-level signing domain both `sign` and `verify` call, so signer and
verifier cannot drift. Syrup verification uses the exact received locator record
when the decoder captured it; codecs without that raw capture, such as Cap'n
Proto, canonicalize the neutral locator into the same signing input.
[`foundation.crypto`](../../../src/foundation/crypto.zig) owns the Ed25519 math
(`SecretKey` / `PeerKey` / `Signature`, `sign` / `verify`, `SecretKey.fromSeed`)
as pure, wasm-clean computation; `fromSeed` is the entropy boundary, since the
core reconstructs a key from a caller's 32-byte seed and never generates
randomness. [`pairing.pairedWithKeys`](../../../src/ocapn/engine/pairing.zig)
signs each side's canonical bytes and drives the keyed Syrup handshake, and the
pairing tests also prove authenticated next handshakes over Syrup and Cap'n
Proto. A bad signature is a loud `Error.InvalidStartSessionSignature`, projected
to the `invalid_start_session_signature` typed abort and observable in a
scenario. The session keeps no key custody: authority lives in references, not
keys. Wire confidentiality (TLS or any transport encryption) is a netlayer
concern and is not implemented.

## Scope (what this does not decide)

- Production netlayers are out of scope here. The core ships the no-I/O halves;
  driving frames over a real transport (and the connection lifecycle around it)
  is an adapter concern, decided by the netlayer contract
  ([ADR-0043](ADR-0043-netlayer-contract.md)) and its transport residents
  ([ADR-0047](ADR-0047-in-memory-netlayer.md) in-process,
  [ADR-0055](ADR-0055-iroh-netlayer-sidecar.md) iroh).
- `deposit-gift` / `withdraw-gift` bootstrap methods: they ride the handoff
  cryptographic suite in [ADR-0009](ADR-0009-three-party-handoff-substrate.md).

## Alternatives Considered

- **Promote straight to `open` without driving the `op:start-session` bytes.**
  Rejected: the lifecycle gate (`negotiating` admits only start-session / abort)
  becomes a fiction, and the spec-pinned exchange is what installs the bootstrap
  export. Driving the real record now keeps the state machine honest.
- **Generate per-session keys inside the core.** Rejected: entropy is I/O.
  `pairedWithKeys` takes seeds, keeping the handshake driver deterministic and
  wasm-clean.
- **Fold the bootstrap-fetch send and wire loop into one core call.** Rejected:
  the core has no transport. `prepareFetchSwissnum` builds the message and
  `tryMatchFetchOutcome` matches a settling reply; the adapter owns send / recv
  between them.
- **Synthesize the inbound-`'fetch` reply inside `Session.recordRecv`.**
  Rejected: the session is a passive observer. `recordRecv` validates and
  updates tables, it never produces a message. Synthesizing a `Resolve` from an
  inbound `Deliver` would change that contract. The V1.0 resolver-callback
  translation already lives in the engine dispatch path; bootstrap serving fits
  the same pattern (session lookup, engine synthesis).

## Consequences

- The model carries `StartSession` plus the `SessionPubkey` / `LocationSig`
  slice-borrowed byte views; the start-session arm rides every `Message`
  dispatch path.
- The session owns the `negotiating` to `open` gate and the bootstrap export
  install at id 0; `op:start-session` is the only non-abort traffic the
  negotiating state accepts.
- `engine.pairing` `paired` / `pairedWithKeys` are the in-process handshake
  fixtures the oracle scenarios and the C-ABI dogfood build on;
  `shuttleUntilQuiescent` surfaces a non-terminating dispatcher as an
  iteration-cap error rather than a hang.
- `engine.fetch` exposes the initiator halves and `engine.bootstrap` the
  responder halves; the session gains a `bootstrap` registry and `Peer` gains
  `registerBootstrapCap`, so the exporter side is validated end to end by the
  `runHandshakeThenBootstrapFetch` oracle scenario (the responder
  auto-resolves; the round-trip tests stop hand-rolling the reply).

## Forward compatibility

The `op:start-session` record shape is final: real Ed25519 fills the
`session_pubkey` / `acceptable_location_sig` bytes (see Peer authentication
above) without reshaping the record or the session machine. A production
netlayer implements against the same model record and the same `negotiating` to
`open` machine, which is what the netlayer contract
([ADR-0043](ADR-0043-netlayer-contract.md)) did without reshaping either; the
`bootstrap` registry is session state (not codec state), so dispatch keys on the
codec-neutral semantic shape across the active codec.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the codec posture
this record encodes under. [ADR-0009](ADR-0009-three-party-handoff-substrate.md)
owns the `deposit-gift` / `withdraw-gift` bootstrap methods.
