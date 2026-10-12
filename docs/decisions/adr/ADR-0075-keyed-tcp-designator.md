---
id: ADR-0075
status: accepted
date: 2026-07-11
tags: [net, driver, engine, identity]
decision: "TCP gains a `keyed-tcp` netlayer whose designator is the listener's Ed25519 key in canonical hex, with the socket address riding the `direct-addresses` hint, verified fail-closed at the handshake by one shared dial-side pin (`engine.Peer.expectPartnerKey`) that iroh inherits."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0097]
---

# ADR-0075 Keyed TCP Designator

## Context

A plain `tcp` locator's designator is a `host:port`: it names where to dial and
dies with the process that bound it, so a partner holding yesterday's locator
holds nothing after a restart. iroh has the durable alternative: the designator
is the endpoint's Ed25519 public key, dial addresses ride the `direct-addresses`
hint, and one key is transport identity, locator designator, and session signing
key (ADR-0055). The check that ties them together (dialed designator equals the
session key the partner proves) belongs in the library, and TCP needs a
key-designator posture. For cleartext TCP that check is the entire security
story: the channel authenticates nothing, so only the `op:start-session`
signature says who answered. The conformance evidence is the keyed-handshake
scenarios in `test/engine/pairing/` and the live `iroh-interop` capstones.

## Decision

The restart-stable TCP listening identity is one netlayer plus one shared
verification seam:

- **One encoding.** `foundation.crypto.PeerKey.toDesignator` /
  `fromDesignator` own the canonical key-designator form: exactly 64 lowercase
  hex digits, strict on parse. iroh's shape check delegates to it.
- **A declared scheme.** `net.netlayer.DesignatorScheme` (`address` | `key`)
  sits on the netlayer and listener vtables, defaulted `address`. `tcp` and
  `inproc` are `address`, iroh and the keyed resident are `key`. The
  transport-neutral `hint_direct_addresses` vocabulary and its hint scanner
  live in `net.netlayer` (iroh re-exports them).
- **The engine pin.** `engine.Peer.expectPartnerKey` records the one key an
  inbound `op:start-session` may carry. The check runs at the inbound dispatch
  chokepoint beside the signature verification, before the session opens,
  because a byte-fed `feed` can carry the start-session and later frames in one
  chunk: a post-open check would be a time-of-check gap. A mismatch is the
  engine error `PartnerKeyMismatch`, projected into the same non-closing
  handshake abort domain as `InvalidStartSessionSignature`.
- **Dial-side wiring.** `driver.connectVia` pins the peer to the dialed
  designator whenever the resolved netlayer's scheme is `key`, which makes
  iroh's key unification a library invariant on the native dial path. The
  byte-fed `driver_core.Host.openDialedLocator` mirrors the same fact through
  `vocab.designatorSchemeForTransport`, a string table, since the sans-io core
  holds transport strings, never vtables. The netlayer vtable is authoritative
  on I/O paths. The string table is its byte-fed mirror, and a transport added
  to one is added to the other.
- **The resident.** `net.tcp.keyed` (one instantiation of the shared
  `Profile` in `src/net/transport/tcp/profile.zig`, beside `net.tcp.plain` and
  `net.tcp.noise`) reuses the plain TCP resident's sockets, streams, and pinned
  wrapper and owns only the grammar. A dial requires a canonical key
  designator and a `direct-addresses` hint (TCP has no discovery, so a hint-less
  dial refuses before any I/O). A listener binds an ordinary `host:port`,
  reports the key as `localDesignator`, and exposes the bound address through
  `Listener.localHint`.
- **The accept half.** `driver.acceptVia` dispatches on the listener's scheme.
  `address` listeners sign the address designator. On a `key` listener the
  signed designator derives from the signing secret itself (its public key's
  hex, so designator and session key cannot disagree by construction), the
  listener's hint rides the signed location as one `direct-addresses` entry,
  and an `.ephemeral` identity is refused with the typed
  `Error.EphemeralIdentityOnKeyedTransport`: a throwaway key cannot produce a
  durable designator. The Syrup encoder's start-session locator path
  (`writePeerLocatorRecord`) renders hint entries canonically, and the signing
  domain (`canonicalLocationSignedBytes`) embeds the same bytes.
- **iroh alignment.** Bridged iroh scale serves under `driver.core.Host`
  seeded with the endpoint's own key, and the in-tree iroh responders (the
  interop, loop, reachability, and bench harnesses, and the rooms demo servers)
  seed the endpoint and the signing identity from one seed.

## What the pin proves

The `keyed-tcp` channel is as cleartext as `tcp`: anyone on the path reads every
frame. The start-session signature covers static location bytes, so an active
middlebox can relay the genuine listener's signed hello and then read or alter
ordinary session traffic. The pin guarantees that the advertisement is authentic
(a squatter on the hinted address cannot claim the key, pinned by the negative
arm in `test/driver/keyed_tcp_restart_test.zig`), and that operations demanding
a fresh signature under the session key, minting and redeeming three-party
handoff certificates, can be performed only by the key holder. Channel
confidentiality and integrity are iroh's job. Keyed TCP is the durable identity
posture for deployments that accept a cleartext wire.

## Scope (what this does not decide)

- Cap'n Proto and Syrup both project non-empty locator hints on
  `op:start-session` and sturdyrefs through `view.BorrowedHints` (and
  `toOwned`). Syrup start-session also keeps `acceptable_location_raw` for the
  signing domain. Session authority does not store partner structured hints for
  dial-from-hello: see
  [Known limitations § Transports and peer identity](../../boundaries.md#transports-and-peer-identity)
  and [community-review.md](../../community-review.md).
- Each binding has `keyed-tcp` dial and host surfaces and a restart check. Each
  TCP package constructs a typed keyed locator, and the `connect(locator)` front
  door dials it (`zig build bindings-keyed-tcp-restart`). The C ABI peer-level
  partner-key pin is `glowcap_peer_expect_partner_key`.
- `designatorSchemeForTransport` maps both `keyed-tcp` and `iroh` to `.key`.
  Binding-hosted iroh servers mint one seed for the endpoint and the `Node`,
  so designator, session key, and netlayer identity stay one value. A byte-fed
  dial by node id pins the handshake the same way keyed TCP does, and a
  squatter key is refused with `PartnerKeyMismatch` (proven in
  `test/driver/core_host/`).

## Alternatives Considered

- **Sniff key-shaped designators on the `tcp` symbol**: rejected. Two identity
  postures under one dispatch symbol let a plain-tcp locator's grammar and signed
  bytes change by accident, and Goblins keys its netlayer on `tcp`.
- **Check the key after the session opens**: rejected. On the byte-fed path one
  chunk can carry the handshake plus later frames, which would apply traffic
  under the wrong identity before the check ran.
- **TLS over TCP for identity**: out of scope and separately rejected until the
  transport story calls for it (ADR-0055). The key designator solves identity
  durability, not confidentiality.

## Consequences

- `engine.Peer` has the `expected_partner_key` field (inside the ADR-0045
  struct budget) and the `PartnerKeyMismatch` arm in the abort taxonomy.
- `net.netlayer` carries the scheme and hint vocabulary, and every vtable
  compiles through defaults.
- Grammar units live in `test/net/keyed_tcp_test.zig`. The loopback proof
  (happy path, key-squatter refusal, and the same-seed-fresh-port restart)
  lives in `test/driver/keyed_tcp_restart_test.zig`. The engine pin's units sit
  beside the other handshake scenarios in `test/engine/pairing/`.
- The iroh harnesses and rooms demo servers sign with their endpoint keys, so
  every in-tree iroh responder satisfies the invariant the dial pin enforces.
