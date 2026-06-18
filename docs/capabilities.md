# Capabilities, CapTP, and OCapN, from zero

This page is the on-ramp. It assumes you are a competent programmer who has
never met object-capability security, and it explains the ideas pancake
implements before any Zig appears. If you already know what a vat and a
sturdyref are, skip straight back to the [README](../README.md) quickstart.

## What a capability is

A capability is a reference that _is_ the permission. If you hold a reference to
an object, you can call it; if you do not hold it, you cannot — and you cannot
forge one, guess one, or escalate your way to one. That single rule replaces the
machinery most systems use to answer "is this caller allowed to do that?": there
are no access-control lists to consult, no role checks, no string-typed
permission names to match. The question never comes up, because an unauthorized
caller has nothing to make the call _with_.

The contrast is what security people call ambient authority. In most systems a
program runs with a pool of permissions attached to its identity — its user
account, its API key, its service role — and every library it links shares that
whole pool. A capability system has no pool. Authority arrives one reference at
a time, from whoever chose to hand it over, and a function can use exactly what
it was passed and nothing else.

Three patterns fall out of that rule, and they are the reason the model is worth
the trouble:

- **Delegation.** Handing someone a capability _is_ granting the permission. No
  registration step, no admin console — passing the reference is the grant.
- **Attenuation.** To grant less than you hold, wrap your capability in an
  object that exposes only the narrower surface, and hand out the wrapper. The
  wrapped original never leaves your hands.
- **Revocation.** Hand out a forwarder you control instead of the real thing.
  When you cut the forwarder, every copy of the grant dies with it, no matter
  how far it was re-delegated.

In ordinary memory-safe programming you already live by this rule without naming
it: an object reference in Zig, Rust, or JavaScript can only be used by code it
was given to. Capability security is that discipline taken seriously — and CapTP
is what lets it cross a network.

## What CapTP adds

CapTP — the Capability Transport Protocol, an idea inherited from the
[E language](http://erights.org/elib/distrib/captp/) — extends those references
over a connection. Two programs open a session, and each can hand the other
references to its local objects. A reference that crosses the wire arrives as
unforgeable on the far side as it was at home: the protocol's tables, not the
application's diligence, make it impossible to name an object you were never
given.

Beyond carrying references, CapTP carries _promises_. Calling a remote object
returns immediately with a promise for the answer, and you may call methods on
that promise before it resolves — the call is forwarded to wherever the answer
turns out to live. This is promise pipelining, and it collapses what would be
ping-pong round trips into a single flight. The protocol also keeps distributed
garbage-collection accounts, so when neither side can reach an exported object
anymore, its slot is reclaimed.

When three parties are involved — Alice holds a capability to Carol's object and
wants to give it to Bob — CapTP defines the _handoff_: a signed, verifiable
introduction that lets Bob present his grant to Carol directly, without Alice
having to proxy every later call.

## What OCapN is, and where Goblins fits

[OCapN](https://github.com/ocapn/ocapn) — the Object Capability Network — is the
standards effort, stewarded by the
[Spritely Institute](https://spritely.institute/) and a community group, that
turns CapTP from a family of implementations into one interoperable protocol: an
abstract message model, concrete wire encodings, and netlayers (the transports
sessions run over). The draft specifications live in the OCapN repository, and
this repository vendors a copy under
[`conformance/ocapn-spec/`](../conformance/ocapn-spec/).

[Spritely Goblins](https://spritely.institute/goblins/) is the reference
implementation in practice: a Racket (and Guile) library whose wire behavior
defines what interoperating actually means today. pancake treats Goblins as its
conformance authority — `zig build goblins-interop` holds a live conversation
with a real Goblins vat in both directions — and the
[protocol diagrams](protocol-diagrams/README.md) flag the few places where
pancake speaks a Goblins convention that the draft spec does not yet pin down.

pancake is the systems-language entry to that ecosystem: the protocol core in
Zig, a C ABI above it, and bindings so the same capability discipline is
reachable from Rust, Python, Deno, and Racket. What that costs in memory and
allocations is part of the contract — the [architecture](architecture.md) doc is
the place where those budgets are named.

## Glossary

Each term in one breath. These are the words the rest of the documentation uses
without stopping to re-introduce them.

| Term               | Meaning                                                                                                                           |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| capability         | A reference that is itself the permission to use what it names.                                                                   |
| ambient authority  | Permission drawn from identity or environment rather than from a held reference; the thing capability systems remove.             |
| CapTP              | The session protocol that carries capabilities, calls, and promises between two programs.                                         |
| OCapN              | The standardization of CapTP: one message model, several codecs and netlayers, many implementations.                              |
| vat                | One single-threaded container of objects; all calls into a vat run one turn at a time.                                            |
| turn               | One message delivery processed to completion inside a vat.                                                                        |
| reference          | A name for an object; _near_ if it lives in your vat, _far_ if it lives across a session.                                         |
| export / import    | The session-table positions a shared object occupies: an export on the side that owns it, an import on the side that received it. |
| promise            | A reference to an answer that has not arrived yet; it later resolves to a value or breaks with a reason.                          |
| promise pipelining | Calling through a promise before it resolves, so dependent calls travel in one flight instead of round trips.                     |
| swiss number       | An unguessable name a host registers an object under, so a partner can fetch it through the bootstrap object.                     |
| bootstrap object   | The one well-known capability a fresh session starts with; everything else is fetched or passed from there.                       |
| sturdyref          | A durable, out-of-band token — peer plus swiss number — that can be turned back into a live reference later.                      |
| locator            | The `ocapn://` URI form that names a peer (and optionally a sturdyref) so a netlayer can dial it.                                 |
| handoff            | The signed three-party introduction that moves a capability from one session to another without proxying.                         |
| netlayer           | The transport a session runs over; pancake ships TCP, an in-process (`inproc`) pair, and an encrypted iroh/QUIC resident.         |
| codec              | The wire encoding of the message model; pancake ships Syrup and Cap'n Proto behind one dispatch boundary.                         |
| Syrup              | The S-expression-flavored binary encoding Goblins speaks; the default OCapN wire format.                                          |
