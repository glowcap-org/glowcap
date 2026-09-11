---
id: ADR-0107
status: accepted
date: 2026-08-05
tags: [captp, handshake, identity, transport, relay, keyed-tcp, noise, browser]
decision: "One end-to-end sealed channel, Noise_XK over any byte pipe, carried by two new netlayer symbols. The two CapTP peers run the handshake themselves, so a relay in the path forwards ciphertext and proves nothing. The core Host owns the channel and is its own realizer, so every tier above it and every binding inherits the proof without wiring."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0113, ADR-0117]
---

# ADR-0107 A sealed byte channel for the cleartext netlayers

`noise-tcp` and `noise-relay` ship through the native Host tiers, the generic C
driver, and all four native bindings. Browser wasm peers do not compose the
`noise-relay` provider: they use WebRTC for an authenticated channel, or
cleartext `keyed-relay` rendezvous.

## Context

Two of the shipped netlayers are production transports and three are not. The
architecture rule's table records the split: `iroh` and `webrtc` carry a peer
proof and an encrypted channel, while `tcp`, `keyed-tcp`, and `keyed-relay`
carry neither and are marked trusted-network only.

[ADR-0105](ADR-0105-connection-scoped-durable-authentication.md) settled that
authentication belongs to the realized connection. On `keyed-tcp` the
designator is a durable key, but TCP proves no possession of it. The session
therefore reports `unauthenticated`, and a captured hello can be replayed onto
another cleartext connection.

`keyed-relay` is worse in a way the two-key split makes precise. The relay
terminates each side's connection and opens its own onward
([ADR-0086](ADR-0086-byte-transparent-relay.md)), so the far end of a browser's
byte channel is the relay. Authenticating that leg perfectly would prove the
relay's identity, not the peer beyond it. The end-to-end session therefore
remains `unauthenticated`, which is the honest answer and the whole problem.

For native peers there is no gap. An iroh connection carried over an n0 relay is
still QUIC end to end: the relay forwards encrypted datagrams and never holds
the keys, so a relayed iroh session reports `authenticated_transport` exactly as
a direct one does. `zig build iroh-reachability` and
`zig build demo-rooms-dm-iroh-discovery` hold that today.

The gap is a browser. A browser cannot open a UDP socket, so it cannot speak
QUIC to an iroh endpoint, which is why `keyed-relay` exists at all
([ADR-0088](ADR-0088-fully-functioning-browser-peer.md)). Browser-to-browser is
covered by WebRTC ([ADR-0089](ADR-0089-webrtc-datachannel-netlayer.md)), whose
DataChannel is DTLS-protected. What is left uncovered is a browser reaching a
peer it cannot open a DataChannel to, which today means a cleartext session
through a relay that can read and rewrite every byte.

This engages the first principle that protocol correctness and capability
semantics come before implementation convenience. A capability system whose
browser tier requires a trusted intermediary has not delivered the semantics it
claims.

## Decision

Add one **sealed channel** layer that runs between the byte transport and CapTP,
and let every cleartext transport inherit it rather than fixing each transport
separately.

The two CapTP peers run a **Noise_XK** handshake with each other, inside
whatever byte pipe already connects them. A relay in that path forwards
ciphertext. The realizer is the sealed layer rather than the socket, so when the
handshake completes it asserts the remote's durable key through
`engine.Peer.bindVerifiedChannelKey` and the session reports
`authenticated_transport` about the **partner**, not about the carrier.

Two new netlayer symbols carry it: **`noise-tcp`** and **`noise-relay`**. Each
keeps the designator scheme and address shape of the cleartext symbol it sits
beside, so a peer's existing durable key is its identity on both.

The symbol says which protocol to speak. It does not license any conclusion
about who is at the far end. That conclusion still comes from the handshake
completing, through the same seam every other realizer uses, which is what keeps
this consistent with ADR-0105 rather than reintroducing the transport table it
deleted.

The channel composition is one type, `foundation.sealed.SealedChannel`, and
each stream tier is a thin owner and its own realizer. The byte-fed core Host
boxes one per sealed session, so the native `driver.HostRuntime`, the language
bindings' byte pumps, and the wasm Host a browser runs
([ADR-0070](ADR-0070-browser-binding-via-wasm.md)) inherit the proof with no
wiring. The completion-loop tier ([ADR-0076](ADR-0076-loop-fed-host-bridge.md))
drives `engine.Peer` directly and holds no `HostSession`, so its owner is its
one byte-transform seam, the completion backend: a sealing adapter completes
the handshake before the loop hears the dial connected and answers
`verifiedChannelKey`, the same realizer seam the iroh backend uses, so
`driver.Bridge` binds the proof unchanged.

## The handshake, exactly

**Pattern.** `Noise_XK_25519_ChaChaPoly_BLAKE2s`. All three primitives are in
`std.crypto`, so this adds no dependency, only code in `foundation`.

**Why XK and not IK.** Both are candidates once the responder's key is known in
advance, which a key designator supplies. They differ in when the initiator
sends its own static key. `IK` sends it in the first message, encrypted under
the responder's long-term key. Recording that message and later compromising the
responder's static key reveals who connected. `XK` sends the initiator's static
in the third message, under keys derived from an ephemeral-to-ephemeral
exchange, so a later compromise of the responder's key reveals nothing about who
talked to it.

That difference decides it here rather than in general. The point of this design
is to put an untrusted relay in the path deliberately, and a relay is perfectly
placed to record first messages and wait. In a capability system, who connected
to whom is often more sensitive than what was said. The cost is one extra round
trip at setup, which a long-lived room session pays once.

**Static keys.** A peer's Noise static is its durable Ed25519 key converted to
X25519 by the standard birational map. The initiator derives the responder's
X25519 public key from the designator it already holds, which is what lets `XK`
work against locators that exist today and keeps dial-by-key working for
relay rendezvous and sturdyrefs.

**Exact identity binding.** The map drops the Edwards sign bit, so equality of
X25519 images is not proof of one exact Ed25519 encoding. Messages two and
three therefore carry the sender's 32-byte Ed25519 key and a 64-byte Ed25519
signature. The signed statement domain-separately binds that exact key, the
sender's authenticated X25519 static, its initiator/responder role, and the
initial Noise transcript after the protocol name, prologue, and responder
pre-message. The initiator additionally requires message two's key to equal
the locator's responder designator. Both payloads ride encrypted and
authenticated inside the handshake, cost no extra round trip, and reveal the
initiator's identity to no one the handshake does not. The channel borrows the
signing key only while constructing its local proof and retains no Ed25519
secret.

**Prologue.** The Noise prologue is the transport symbol and the responder's
designator, joined by a separator that cannot occur in either. Both sides
compute it from what they already know, and neither transmits it. A transcript
therefore cannot be replayed onto a different transport or against a different
claimed identity, because the hash chains diverge from the first message.

**Record framing.** After the handshake the channel carries length-prefixed
sealed records: a two-byte big-endian length, then the ciphertext, at most
65535 bytes including the 16-byte tag. A CapTP frame larger than one record's
plaintext capacity spans several records.

The layer is byte-stream in, byte-stream out. Nothing above it changes. The
codec's cap-during-scan, `foundation.Spill`, and `SessionLimits.max_frame_bytes`
all sit above and are untouched, because what they see is the plaintext stream
they see today.

**Failure is refusal.** A handshake that does not complete closes the connection
without a CapTP session ever existing. There is no downgrade to an unsealed
session and no option to permit one. A knob is how the hole reopens, which is
the same reasoning ADR-0105 gave for deriving the demand rather than configuring
it.

## Where the layer lives

- **`foundation.noise`**: the pure state machine. Handshake and transport
  cipherstates over caller buffers, no allocation beyond what the caller
  supplies, no I/O. It belongs in `foundation` for the same reason
  `foundation.Spill` does: two tiers need it and neither imports the other.
- **`foundation.sealed`**: the channel composed over it — handshake framing,
  the prologue, exact identity proofs, record framing, and prefix-consuming
  stream ingestion. Complete units are read from the transport's borrowed
  buffer. Only an incomplete unit enters spill staging. The same
  homing argument as the state machine, and it is the derivation that placed
  it: threading `HostSession` sealing through the loop's peer-centric seams
  would invert the contract the Bridge preserves, and duplicating channel
  state into the loop's `Conn` would split channel authority, so the
  transport-agnostic machine moved down to where both tiers can compose it
  and each tier keeps one thin owner.
- **`driver_core`**: the byte-fed tier's owner, implemented by the internal
  `src/driver/core/host/session.zig` shell/framing owner and its
  `host/session/ingress.zig` dispatch leaf behind the supported Host surface.
  `HostSession` gains one
  nullable boxed channel. `feedBytes` runs the handshake before any CapTP
  byte reaches the engine and decrypts afterwards; `takeOutbound` emits
  handshake messages first and seals afterwards. On completion the Host calls
  `bindVerifiedChannelKey` itself. `driver_core` is `core = true`, and Noise
  is sans-io, so `arch-check` stays satisfied.
- **`net`**: the loop tier's owner, and the only new I/O-side code. For
  `noise-tcp` nothing changes: the resident reuses the `tcp` sockets exactly
  as `keyed-tcp` does, and the byte-fed Host seals. For `noise-relay` the
  sealing completion-backend adapter (`net.noise_completion`) wraps the
  keyed-relay backend: a sealed dial completes the handshake before the
  connect completion is reported — as the relay adapter completes its
  WebSocket upgrade first — then seals submitted sends into records and lends
  opened record plaintext to the recv seat. A coalesced ciphertext suffix stays
  in the inner backend's borrowed receive buffer until another seat consumes
  it, so the adapter does not copy whole records into a second queue. The loop
  and Bridge are untouched and their budget equalities hold; the sealed leg
  pays its own pinned per-connection state instead.

`driver.BlockingSession`, the no-router single-connection tier, does not get
sealed transports, because it does not stand on the core Host. That is a present
boundary rather than a plan.

## Per-session footprint

The 500k-connection budget is a gate
(`host_session_struct_budget_bytes`, 528 today), so the shell pays **one
nullable pointer, eight bytes**, and an unsealed session pays nothing else. The
channel itself is heap-allocated only for a sealed session.

Handshake secrets are transient. The ephemeral secret, chaining key, HKDF
intermediates, and static-secret copy are zeroed at completion. The box then
holds the two transport cipherstates plus fixed public proof/context storage.
Ordinary staging is bounded by one incomplete Noise record. A byte-fed Host may
also retain the unread suffix of one caller-owned read across the CapTP hello
pause, just as its plaintext stream parser retains coalesced frames; no Ed25519
signing secret survives construction. The
completion adapter's whole per-connection state is pinned by
`test/net/noise_relay_test.zig`, so proof growth or new queue state changes a
checked number rather than an estimate in prose.

Sealing writes ciphertext and opened plaintext into separate record-sized
storage because AEAD cannot operate in place across the borrowed boundaries the
engine and completion loop rely on. Complete inbound ciphertext itself is not
copied: the channel consumes borrowed prefixes, and the completion adapter keeps
the underlying receive-buffer borrow across seats. This cost is paid only by
sealed sessions.

## Wire compatibility and interop

Additive. `keyed-tcp` and `keyed-relay` are untouched, and every existing
locator keeps working. A peer that does not know `noise-tcp` cannot dial it,
which is the correct outcome rather than a downgrade.

Upstream Goblins ships no Noise netlayer, so `noise-*` is glowcap to glowcap and
to anyone who implements this record. Goblins interop continues over `tcp` and
over the iroh netlayer this repository wrote for it. No conformance fixture
changes.

The relay needs no change and gains no capability. It routes by the registered
key in the rendezvous bridge rather than by anything in the stream
([ADR-0088](ADR-0088-fully-functioning-browser-peer.md)), so sealing the stream
does not break routing. What changes is that it can no longer read or rewrite
what it forwards.

## Security posture, stated plainly

**What it fixes.** Replay of a captured hello, because the handshake is fresh
per connection and the CapTP hello rides inside it. Confidentiality and
integrity against anyone on the path, including the relay. Peer proof that is a
cryptographic fact rather than a claim. Forward secrecy for both content and for
the initiator's identity.

**What it does not fix.** Traffic analysis: a relay still sees who connects to
it, when, and how much. Relay availability: a relay can still refuse to forward,
and this record does not make it accountable. Compromise of a durable key
remains total for that peer, as it is on every transport. And a peer that
advertises a `noise-*` locator can still be dialed on a cleartext symbol by
anyone who knows its address, because a locator advertises a way to be reached
and does not forbid others.

## Required evidence

Each item names what carries it, or says plainly that nothing does yet.

1. **The state machine matches the pinned external transcript.** One published
   Snow/Cacophony vector for `Noise_XK_25519_ChaChaPoly_BLAKE2s` passes byte for
   byte, both roles and every handshake and transport message, in
   [`test/foundation/noise_test.zig`](../../../test/foundation/noise_test.zig).
   In-tree refusal, nonce, rekey, framing, and key-conversion scenarios cover
   the state transitions that fixed transcript cannot. This is strong evidence
   for the selected suite, not a claim of exhaustive Noise specification
   conformance or independent live interoperability.
2. **A sealed session reports the stronger fact.** Two peers over `noise-tcp`
   both report `authenticated_transport`, and the same pair over `keyed-tcp`
   reports `unauthenticated`. Held by
   [`test/driver/sealed_channel_test.zig`](../../../test/driver/sealed_channel_test.zig)
   and live over loopback by
   [`test/driver/noise_tcp_live_test.zig`](../../../test/driver/noise_tcp_live_test.zig).
   The C driver-loop projection repeats the live proof through only exported
   ABI verbs, including both listener-locator halves and an application fetch,
   in [`test/c_abi/driver_loop/archive_test.zig`](../../../test/c_abi/driver_loop/archive_test.zig).
3. **Replay is refused.** A recorded handshake replayed onto a fresh connection
   fails, and no CapTP session opens. Held by
   [`test/driver/sealed_channel_test.zig`](../../../test/driver/sealed_channel_test.zig).
4. **The exact Ed25519 identity is proved.** A second Ed25519 encoding with the
   opposite Edwards sign bit maps to the same X25519 point but is refused as an
   initiator identity. Held by
   [`test/driver/sealed_channel_test.zig`](../../../test/driver/sealed_channel_test.zig).
5. **A substituted key is refused.** A relay that answers with its own static
   key fails the handshake rather than establishing a session it could read.
   Held by
   [`test/net/noise_relay_test.zig`](../../../test/net/noise_relay_test.zig).
6. **The relay sees ciphertext.** The forwarded bytes contain no CapTP frame
   preamble, asserted against the relay's own view rather than inferred. The
   dial-side mock pipe and the live registered-resident scenario in
   [`test/net/noise_relay_test.zig`](../../../test/net/noise_relay_test.zig)
   both hold this for their plaintext probes. The C driver repeats the live
   registered-provider path in
   [`test/c_abi/driver_loop/archive_test.zig`](../../../test/c_abi/driver_loop/archive_test.zig).
Items 2 and 4 are the load-bearing identity claims: the channel reports a
stronger fact only after proving the exact key it reports.

## Implementation

`foundation.noise` owns the state machine, published vectors, and
Ed25519-to-X25519 conversion. The core Host owns one boxed channel per sealed
session and binds the verified channel key to session provenance. Transport
packages only supply byte pipes and profile metadata: the TCP archive owns
`noise-tcp`, and the relay archive owns `noise-relay`. The generic driver and
bindings therefore select the sealed channel without implementing Noise or
transport policy themselves. Footprint tests pin the per-session and
completion-adapter state, while the evidence above holds the wire and identity
claims.

## Scope (what this does not decide)

- **Plain `tcp` is not addressed.** Its designator is an address, so a dialer
  cannot know the responder's static key and `XK` does not apply. A sealed
  channel with no pre-known key would need a different pattern and would
  authenticate nothing on its own. That is a separate decision.
- **`iroh` and `webrtc` do not change.** They carry their own handshakes, and
  layering a second one under CapTP would cost a round trip to prove what QUIC
  or DTLS already proved.
- **No pre-shared keys, no 0-RTT, and no post-quantum suite.** Each is a wire
  decision with its own tradeoffs, and none is needed to close the gap this
  record names.
- **No relay accountability.** A relay that drops traffic is unchanged by this,
  and making one answerable for what it forwards is a separate design.
- **`driver.BlockingSession` does not get sealed transports**, because it does
  not stand on the core Host.
- **No second identity credential.** A completed `Noise_XK` handshake already
  proves the durable keys at both ends and protects the CapTP hello carrying
  each fresh session key. A second durable-key signature would add no proof.

## Alternatives Considered

- **`Noise_IK`**: one fewer round trip. Rejected because the initiator's static
  is encrypted under the responder's long-term key, so a recorded first message
  plus a later key compromise reveals who connected. The relay this design
  invites into the path is exactly the party positioned to record it.
- **A separate X25519 static published in a signed locator hint**: avoids using
  one key for signing and Diffie-Hellman. Rejected because `XK` needs the
  responder's static before the first message, so the dialer would need the
  hint, and dial-by-key alone would stop working for relay rendezvous and
  sturdyrefs. The key-reuse hazard is instead bounded by the signing-domain
  invariant in step 2.
- **Upgrading `keyed-tcp` in place**: no new symbols. Rejected because a locator
  would stop telling a dialer what it will get, and two peers could disagree
  about whether the channel is protected. It is also the rename ADR-0105's Scope
  argues against, since the Noise prologue, hello signature, locator equality,
  and Goblins withdrawal lookup all bind the exact transport string.
- **Securing only the relay leg, with TLS to the relay**: familiar and cheap.
  Rejected because it proves the relay. The byte channel's far end is still the
  relay, so `partnerDurableProvenance` would correctly decline to call it
  `authenticated_transport`, and the relay would still read everything.
- **TLS 1.3 with raw public keys instead of Noise**: a well-reviewed protocol
  with wide tooling. Rejected because it brings certificate and extension
  machinery for a two-party pinned-key exchange, it is far larger in a wasm
  build, and `std.crypto` gives us the three Noise primitives already.
- **WebTransport so a browser speaks QUIC**: rejected because its server
  authentication is a WebPKI certificate rather than a glowcap durable key, so
  it would prove the wrong thing and still need this layer on top.

## Review lenses

**"The transport symbol decides whether the channel is sealed, which is the
table ADR-0105 deleted."** ADR-0105 deleted a table mapping a symbol to *what
was proved*. This maps a symbol to *what protocol to speak*, which is what a
netlayer symbol is for and why `designatorSchemeForTransport` survived that
record. The proof still comes from the handshake completing, through
`bindVerifiedChannelKey`, and a session whose handshake did not complete has no
session at all.

**"Reusing the Ed25519 key for Diffie-Hellman is a cross-protocol hazard."**
Correct, and it is the weakest joint in this design. It is accepted rather than
dismissed, and bounded by a mechanical invariant instead of a comment. If a
future record needs the durable key to sign anything peer-supplied, this
decision has to be revisited, and step 2's check is what forces that
conversation.

**"A relay can still deny service, so the browser tier still depends on it."**
True. This record makes a relay untrusted for confidentiality and integrity, not
unnecessary for reachability. That is a smaller claim than "the relay problem is
solved" and is the one made here.

**"Two more symbols is the N-by-M growth the archive split exists to avoid."**
It is two, not a family, because only the cleartext key-designator transports
need it. `iroh` and `webrtc` prove their own peers, and plain `tcp` is out of
scope above.

## Consequences

`foundation` gains a crypto module larger than the Ed25519 and SHA-256 leaf it
has today, and that module is on the wasm build's path, so its size shows up in
the browser bundle. `driver_core` gains per-session state that is null for every
unsealed session and eight bytes on the shell for all of them, which is a
withdrawal from the footprint budget that the Host ceiling has to be moved for
deliberately, in the constant and in `docs/ladder.md` together.

The transports table in the architecture rule gains two rows with a production
verdict, and `docs/boundaries.md` loses the claim that a cleartext keyed hello
is replayable on the sealed symbols while keeping it for the unsealed ones.

The relay matrix in `zig build bindings-relay` gains a sealed row per runtime.
The relay implementations themselves need no change, which is the clearest
evidence that the layer sits where it should.

## Notes

Builds on [ADR-0105](ADR-0105-connection-scoped-durable-authentication.md),
whose realizer seam this uses without extending, and on
[ADR-0097](ADR-0097-captp-session-identity-attestation.md) for the per-session
key posture. Sits beside [ADR-0075](ADR-0075-keyed-tcp-designator.md), which
established the key designator these symbols reuse, and
[ADR-0086](ADR-0086-byte-transparent-relay.md) and
[ADR-0088](ADR-0088-fully-functioning-browser-peer.md) for the relay path it
seals. The archive boundaries it must not disturb are
[ADR-0059](ADR-0059-composable-c-abi-archives.md).
