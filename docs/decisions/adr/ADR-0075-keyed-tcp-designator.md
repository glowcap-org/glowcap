---
id: ADR-0075
status: accepted
date: 2026-07-11
tags: [net, driver, engine, identity]
decision: "TCP gains a `keyed-tcp` netlayer whose designator is the listener's Ed25519 key in canonical hex, with the socket address riding the `direct-addresses` hint, verified fail-closed at the handshake by one shared dial-side pin (`engine.Peer.expectPartnerKey`) that iroh inherits."
supersedes: []
superseded_by: []
---

# ADR-0075 Keyed TCP Designator

## Context

A plain `tcp` locator's designator is a `host:port`: it names where to dial and
dies with the process that bound it, so a partner holding yesterday's locator
holds nothing after a restart. iroh already ships the durable alternative — the
designator is the endpoint's Ed25519 public key, dial addresses ride the
`direct-addresses` hint, and one key is at once transport identity, locator
designator, and session signing key (ADR-0055). But the check that ties the
knot — dialed designator equals the session key the partner proves — lived only
in the `iroh-interop` harness, not in the library, and TCP had no key-designator
posture at all. For cleartext TCP that check is the entire security story: the
channel authenticates nothing, so only the `op:start-session` signature says who
answered. This engages the first principles "production APIs make the correct
path the easy path" and "session state is authoritative"; the conformance
evidence is the keyed-handshake scenarios in `test/engine/pairing_test.zig` and
the live `iroh-interop` capstones.

## Decision

Ship the restart-stable TCP listening identity as one new netlayer plus one
shared verification seam:

- **One spelling.** `foundation.crypto.PeerKey.toDesignator` /
  `fromDesignator` own the canonical key-designator form: exactly 64 lowercase
  hex digits, strict on parse. iroh's private shape check now delegates to it.
- **A declared scheme.** `net.netlayer.DesignatorScheme` (`address` | `key`)
  sits on the netlayer and listener vtables, defaulted `address`; `tcp` and
  `inproc` stay `address`, iroh and the new resident declare `key`. The
  transport-neutral `hint_direct_addresses` vocabulary and its hint scanner
  moved from the iroh resident into `net.netlayer` (iroh re-exports them).
- **The engine pin.** `engine.Peer.expectPartnerKey` records the one key an
  inbound `op:start-session` may carry; the check runs at the inbound dispatch
  chokepoint beside the signature verification, before the session opens,
  because a byte-fed `feed` can carry the start-session and later frames in one
  chunk — a post-open check would be a time-of-check gap. A mismatch is the new
  engine error `PartnerKeyMismatch`, projected into the same non-closing
  handshake abort domain as `InvalidStartSessionSignature`.
- **Dial-side wiring.** `driver.connectVia` pins the peer to the dialed
  designator whenever the resolved netlayer's scheme is `key` — which upgrades
  iroh's key unification from a harness assertion to a library invariant on the
  native dial path — and the byte-fed `driver_core.Host.openDialedLocator`
  mirrors the same fact through `vocab.designatorSchemeForTransport`, a string
  table, because the sans-io core holds transport strings, never vtables. The
  netlayer vtable is authoritative on I/O paths; the string table is its
  byte-fed mirror, and a transport added to one is added to the other.
- **The resident.** `net.tcp_keyed` (`src/net/transport/tcp_keyed.zig`, symbol
  `keyed-tcp`) reuses the plain TCP resident's sockets, streams, and pinned
  wrapper wholesale; it owns only the grammar. A dial requires a canonical key
  designator and a `direct-addresses` hint (TCP has no discovery, so a hint-less
  dial refuses before any I/O). A listener binds an ordinary `host:port`,
  reports the key as `localDesignator`, and exposes the bound address through
  the new `Listener.localHint`.
- **The accept half.** `driver.acceptVia` dispatches on the listener's scheme.
  `address` listeners are byte-identical to before. On a `key` listener the
  signed designator derives from the signing secret itself (its public key's
  hex, so designator and session key cannot disagree by construction), the
  listener's hint rides the signed location as one `direct-addresses` entry,
  and an `.ephemeral` identity is refused with the typed
  `Error.EphemeralIdentityOnKeyedTransport` — a throwaway key cannot produce a
  durable designator. The Syrup encoder's start-session locator path
  (`writePeerLocatorRecord`) now renders hint entries canonically, and the
  signing domain (`canonicalLocationSignedBytes`) embeds the identical bytes.
- **iroh alignment.** Bridged iroh scale serves under `driver.core.Host`
  seeded with the endpoint's own key, and the in-tree iroh responders (the
  interop, loop, reachability, and bench harnesses, and the rooms demo servers)
  seed the endpoint and the signing identity from one seed.

## What the pin does and does not prove

The `keyed-tcp` channel is exactly as cleartext as `tcp`: anyone on the path
reads every frame. The start-session signature covers static location bytes, so
an active middlebox can relay the genuine listener's signed hello and then read
or alter ordinary session traffic. What the pin guarantees is narrower and
still worth having: the advertisement is authentic (a squatter on the hinted
address cannot claim the key, pinned by the negative arm in
`test/driver/keyed_tcp_restart_test.zig`), and operations that demand a fresh
signature under the session key — minting and redeeming three-party handoff
certificates — cannot be performed by anyone but the key holder. Channel
confidentiality and integrity remain iroh's job; keyed TCP is the durable
*identity* posture for deployments that accept a cleartext wire.

## Scope (what this does not decide)

- The Cap'n Proto codec refuses non-empty locator hints on encode, so a hinted
  keyed location is a Syrup-session feature today — the same boundary hinted
  iroh locators already live with.
- Binding-level `keyed-tcp` dial/host surfaces and per-binding restart gates
  are shipped (`listen_keyed_tcp` / `keyed_tcp_locator` / `connect` on a
  `keyed-tcp` URI; `zig build bindings-keyed-tcp-restart`). The C ABI
  peer-level partner-key pin is `pancake_peer_expect_partner_key`.
- `designatorSchemeForTransport` maps both `keyed-tcp` and `iroh` to `.key`.
  Binding-hosted iroh servers mint one seed for the endpoint and the `Node`,
  so designator, session key, and netlayer identity stay one value; a byte-fed
  dial by node id pins the handshake the same way keyed TCP does, and a
  squatter key is refused with `PartnerKeyMismatch` (proven in
  `test/driver/core_host_test.zig`).

## Alternatives Considered

- **Sniff key-shaped designators on the `tcp` symbol**: rejected; two identity
  postures under one dispatch symbol means a plain-tcp locator's grammar and
  signed bytes can change by accident, and Goblins keys its netlayer on `tcp`.
- **Check the key after the session opens**: rejected; on the byte-fed path one
  chunk can carry the handshake plus later frames, which would apply traffic
  under the wrong identity before the check ran.
- **TLS over TCP for identity**: out of scope and separately rejected until the
  transport story calls for it (ADR-0055); the key designator solves identity
  durability, not confidentiality.

## Consequences

- `engine.Peer` grows the `expected_partner_key` field (inside the ADR-0045
  struct budget) and the `PartnerKeyMismatch` arm in the abort taxonomy.
- `net.netlayer` carries the scheme and hint vocabulary; every vtable keeps
  compiling through defaults.
- Grammar units live in `test/net/keyed_tcp_test.zig`; the loopback proof —
  happy path, key-squatter refusal, and the same-seed-fresh-port restart —
  lives in `test/driver/keyed_tcp_restart_test.zig`; the engine pin's units sit
  beside the other handshake scenarios in `test/engine/pairing_test.zig`.
- The iroh harnesses and rooms demo servers sign with their endpoint keys, so
  every in-tree iroh responder satisfies the invariant the dial pin enforces.
