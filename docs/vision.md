# Vision

pancake should be a dependable OCapN implementation for people who need
capability networking from Zig or another systems boundary.

[What ships](shipped.md) describes the code today; [the roadmap](roadmap.md)
names the work between here and that destination.

## The goal

A pancake peer should hold a complete, correct conversation with any conforming
OCapN peer, including [Spritely Goblins](https://spritely.institute/goblins/).
That conversation should work whether the application uses native Zig, the C
ABI, or a language binding.

Correctness comes first. Once the protocol is correct, performance and
ergonomics are both requirements: the library should make its costs visible
without making ordinary applications manage protocol machinery.

An independent implementation also tests whether the specification can be
implemented from its own words. Differences between the draft, Goblins, and
pancake stay visible in [community review](community-review.md). Project
provenance and upstream-contact policy live in
[`PROVENANCE.md`](../PROVENANCE.md).

## Design commitments

- **A small portable core.** Session semantics remain synchronous and free of
  I/O, threads, schedulers, and platform policy.
- **Visible ownership.** Allocation, copying, borrowing, and release are
  explicit at the boundary where they happen.
- **One source of authority.** Session state decides what a reference means.
  Codecs parse and render; transports move bytes.
- **Application-shaped APIs.** Fetching, publishing, calling, hosting,
  delegation, attenuation, revocation, and handoff should read as ordinary
  operations rather than wire-protocol bookkeeping.
- **Replaceable edges.** Codecs, transports, and runtime adapters meet the core
  through narrow contracts. The long-term goal is to make those contracts
  usable from every supported surface, not only native Zig.

## Scale

The destination is 500,000 live CapTP sessions on one node.

That is a target. A recorded run has to hold that many real socket sessions
with acceptable memory and scheduling cost. Until then, per-session footprint
checks and allocation budgets keep the design moving in the right direction.
[The route to 1.0](ladder.md) records the measured numbers.

The core cannot create scale by itself; the connection loop and operating
system do the serving. Its responsibility is to avoid making the target
impossible through oversized session state, hidden allocation, or unnecessary
copies.

## A useful application surface

An application should hold a session, fetch or publish an object, and call it.
It should be able to pass a reference to another peer and receive calls back
without learning export positions, driving a manual flush loop, or naming CapTP
messages.

The Zig API should keep allocation and lifetimes legible to a Zig programmer.
The C ABI should give binding authors opaque handles, fixed-width results,
`ptr + len` views, callbacks, and explicit release. A binding that feels
awkward in its host language is a reason to improve the shared boundary.

Higher-level actor support belongs above the protocol engine. Applications may
use it, replace it, or work directly with the session API; the protocol core
should not grow framework policy to serve one runtime.

## Reachability

OCapN does not require one transport. A peer is reached by an address string
called a locator. Encrypted transports prove who answered; a cleartext test
socket does not. The CapTP session above them stays the same, whether the
bytes travel over encrypted discovery, a sealed TCP stream, a local process,
or a development socket.

The destination includes real internet reachability: authenticated peer
identity, encryption, NAT traversal, and relays without folding those concerns
into CapTP. Passing a third party a live reference must end in a direct session
between those two, not a permanent proxy, and the transport has to make that
session reachable.

Browsers are peers too. After obtaining a channel, they should be able to host
objects, answer calls, pass capabilities, and take part in handoff without
turning a relay into an application-level authority.

## Interoperability

Interoperability means:

- native pancake and Goblins can dial, host, call, and hand off to each other;
- every language binding can act as both client and host with outside peers;
- pancake peers using different bindings, codecs, and transports preserve the
  same capability semantics.

## Read the current state

- [What ships](shipped.md) is the implemented surface.
- [Known limitations](boundaries.md) lists constraints that affect users.
- [Stability](stability.md) says what recurring evidence supports each claim.
- [The route to 1.0](ladder.md) records milestone standings and measured
  budgets.
- [The roadmap](roadmap.md) lists the remaining work in order.
- [Architecture](architecture.md) explains the boundaries that protect this
  destination.
