---
id: ADR-0042
status: accepted
date: 2026-10-19
tags: ["net", "netlayer", "onion", "tor", "transport", "identity", "goblins", "interop"]
decision: "The Zig onion provider speaks SOCKS5 and the Tor control protocol to an explicitly configured daemon."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0042 Onion interoperability

## Context

The OCapN onion transport must communicate with a real Goblins vat. A deployment often already operates Tor, and a second embedded implementation would add runtime and identity ownership.

## Decision

The Zig onion provider speaks SOCKS5 and the Tor control protocol to an explicitly configured daemon. It starts no daemon and adds no Rust sidecar. Control connection lifetime owns the undetached service, with explicit restoration state where configured.

The onion service id identifies the address. It is not a durable CapTP session signer or authenticated-channel proof. The transport and hello retain those separate meanings.

Profile hints are used only when the participant knows its partner is glowcap. A hinted dial can advertise its preference, and an acceptor can defer its hello until it knows whether to mirror that form. Gives preserve or strip profile hints for their recipient's known compatibility. Hinted onion sturdyrefs are not minted for arbitrary Goblins consumers.

## Alternatives and consequences

Embedding a second Tor implementation would add an optional runtime and compete with an existing daemon. Advertising glowcap hints indiscriminately would break the pinned Goblins locator behavior. Treating an onion address as a session key would blur the authentication boundary.

Fake-daemon tests establish protocol and cleanup behavior without a network. Live Tor evidence still requires the daemon and outbound access, and does not establish scale or universal reachability.

## Evidence

Onion lifecycle, pending setup and failure tests run under `zig build test`. [Community review](../../community-review.md) lists live Goblins, upstream-suite and restart checks over Tor.
