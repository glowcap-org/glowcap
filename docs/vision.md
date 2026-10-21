---
type: static
description: What glowcap is for and the shape it is growing toward.
sources: []
---

# Vision

glowcap should be the library programs use to share access across a network.
One program hands another a reference. The other can call it, pass it on, and
keep using it after either program restarts. That works in Zig, C, or any
language with a binding.

## The goal

A glowcap peer should hold a complete, correct conversation with any conforming
OCapN peer, including [Spritely Goblins](https://spritely.institute/goblins/).
That holds whether the application uses Zig, the C ABI, or a language binding.

Correctness comes first. Once the protocol is correct, performance and
ease of use are both requirements: the library should show what its work costs
without making ordinary applications manage protocol details.

An independent implementation also tests whether the specification can be
built from its own words. Differences between the draft, Goblins, and glowcap
stay visible in [community review](community-review.md). Anything sent to
OCapN is written by the maintainer, as [`PROVENANCE.md`](../PROVENANCE.md)
explains.

## Design commitments

- **A small portable core.** Session logic is synchronous and free of I/O,
  threads, schedulers, and platform policy.
- **Visible ownership.** Allocation, copying, borrowing, and release are
  explicit where they happen.
- **One source of truth.** Session state decides what a reference means.
  Codecs parse and render. Transports move bytes.
- **APIs shaped like applications.** Fetching, publishing, calling, hosting,
  delegation, attenuation, revocation, and handoff should read as ordinary
  operations, not wire-protocol bookkeeping. The [glossary](capabilities.md)
  explains each one.
- **Replaceable edges.** Codecs, transports, and runtime adapters meet the core
  through narrow contracts that every supported language can use.

## Scale

The goal is 500,000 live CapTP sessions on one node, however an application
runs glowcap.

Per-session memory checks and allocation budgets hold the design to that
target, and the [performance report](https://glowcap.org/performance/#live-sessions) records
measured runs and their scope. Serving that many connections is the job of
the event loop and the operating system. The core's job is to stay small: no oversized session state,
hidden allocation, or unnecessary copies.

## What applications see

An application should hold a session, fetch or publish an object, and call it.
It should be able to pass a reference to another peer and receive calls back
without tracking protocol tables, flushing by hand, or naming CapTP
messages.

The Zig API should keep allocation and lifetimes clear to a Zig programmer.
The C ABI should give binding authors opaque handles, fixed-width results,
`ptr + len` views, callbacks, and explicit release. A binding that feels
awkward in its host language is a reason to improve the shared C interface.

Higher-level actor support belongs above the protocol engine. Applications may
use it, replace it, or work directly with the session API. The protocol core
should not take on framework policy to serve one runtime.

## Durable capability applications

Loam is the persistence layer inside glowcap. Applications should be able to
store objects that hold capabilities, keep exactly the access those
capabilities gave, and restore them after a restart without building their own
reference database. A stored graph can grow larger than memory, because only a
bounded number of its objects are loaded at once. An actor's state can leave
memory between calls and load again when a message arrives.

Loam's managed access is for applications that share resources with people.
It records grants over a resource and what sits below it, lets a holder share
onward but never more widely, can pause or revoke a grant, and shows who has
access. Applications define their own operations and content. Ordinary
objects need no resource-management state, and both kinds can take part in the
same persistence transaction.

The [Loam design](loam/architecture.md) describes it in full. Database I/O is
optional, local persistence needs no network, and plain networking allocates no
store or grant state. Stored graph size, loaded actor count, and live
session count have separate budgets.

## Reachability

OCapN does not require one transport. A peer is reached by an address string
called a locator. Encrypted transports prove who answered. A cleartext test
socket does not. The CapTP session on top stays the same, whether the bytes
travel over encrypted discovery, a sealed TCP stream, a local process, or a
development socket.

The goal includes reaching peers across the internet: authenticated peer
identity, encryption, NAT traversal, and relays, without folding those concerns
into CapTP. When Alice passes Bob a reference to Carol's object, Bob should end up
talking to Carol directly, not through Alice forever, and the transport has
to make that connection possible.

Browsers are peers too. Once they have a channel, they should be able to host
objects, answer calls, pass capabilities, and take part in handoff without
giving the relay any control over what they share.

## Interoperability

Interoperability means:

- glowcap and Goblins can dial, host, call, and hand off to each other
- every language binding can act as both client and host with outside peers
- glowcap peers using different bindings, codecs, and transports keep the
  same capability behavior

## Where things stand

- [What ships](shipped.md) lists what is implemented.
- [Known limitations](boundaries.md) lists constraints that affect users.
- [Stability](stability.md) says which checks back each claim.
- [The route to 1.0](ladder.md) records milestone standings and measured
  budgets.
- [The roadmap](roadmap.md) lists the remaining work in order.
- [Architecture](architecture.md) explains the boundaries that protect this
  goal.
