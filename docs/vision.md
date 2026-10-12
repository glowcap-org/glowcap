# Vision

glowcap should be a dependable foundation for capability applications from Zig
or another systems boundary. OCapN networking, actors, and persistence should
compose through explicit ownership and usable application APIs.

## The goal

A glowcap peer should hold a complete, correct conversation with any conforming
OCapN peer, including [Spritely Goblins](https://spritely.institute/goblins/).
That conversation should work whether the application uses Zig, the C ABI,
or a language binding.

Correctness comes first. Once the protocol is correct, performance and
ergonomics are both requirements: the library should make its costs visible
without making ordinary applications manage protocol machinery.

An independent implementation also tests whether the specification can be
implemented from its own words. Differences between the draft, Goblins, and
glowcap stay visible in [community review](community-review.md). Project
provenance and upstream-contact policy live in
[`PROVENANCE.md`](../PROVENANCE.md).

## Design commitments

- **A small portable core.** Session semantics remain synchronous and free of
  I/O, threads, schedulers, and platform policy.
- **Visible ownership.** Allocation, copying, borrowing, and release are
  explicit at the boundary where they happen.
- **One source of authority.** Session state decides what a reference means.
  Codecs parse and render. Transports move bytes.
- **Application-shaped APIs.** Fetching, publishing, calling, hosting,
  delegation, attenuation, revocation, and handoff should read as ordinary
  operations rather than wire-protocol bookkeeping.
- **Replaceable edges.** Codecs, transports, and runtime adapters meet the core
  through narrow contracts that every supported surface can use, including
  language bindings.

## Scale

The destination is 500,000 live CapTP sessions on one node, for every way an
application can run glowcap.

Per-session footprint checks and allocation budgets hold the design to that
target. [The route to 1.0](ladder.md) records the measured runs and their
scope.

The connection loop and operating system do the serving. The core's job is to
keep the target reachable by avoiding oversized session state, hidden
allocation, and unnecessary copies.

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
use it, replace it, or work directly with the session API. The protocol core
should not grow framework policy to serve one runtime.

## Durable capability applications

Loam is the persistence foundation within glowcap. Applications should
be able to store objects containing capabilities, retain their exact authority,
and restore them after restart without building their own reference database.
Bounded residency lets a durable graph grow beyond memory. Sleepy actors run
on the existing Vat and Host, and their state leaves memory between calls.

Loam's managed access is for applications that share resources with people.
It records grants over a resource and what sits below it, lets a holder share
onward but never more widely, can pause or revoke a grant, and shows who holds
access. Applications define their domain operations and content. Ordinary
objects require no resource-management state, and both kinds can participate
in the same persistence transaction.

The [Loam design](loam/architecture.md) owns that destination. Database I/O stays
optional, local persistence needs no network, and plain networking allocates no
store or grant state. Durable graph size, resident actor count, and live
session count have separate budgets.

## Reachability

OCapN does not require one transport. A peer is reached by an address string
called a locator. Encrypted transports prove who answered. A cleartext test
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

- glowcap and Goblins can dial, host, call, and hand off to each other
- every language binding can act as both client and host with outside peers
- glowcap peers using different bindings, codecs, and transports preserve the
  same capability semantics

## Read the current state

- [What ships](shipped.md) is the implemented surface.
- [Known limitations](boundaries.md) lists constraints that affect users.
- [Stability](stability.md) says what recurring evidence supports each claim.
- [The route to 1.0](ladder.md) records milestone standings and measured
  budgets.
- [The roadmap](roadmap.md) lists the remaining work in order.
- [Architecture](architecture.md) explains the boundaries that protect this
  destination.
