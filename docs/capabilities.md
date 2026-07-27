# Capabilities, CapTP, and OCapN, from zero

This page is the on-ramp. It assumes you are a competent programmer who has
never met object-capability security. If you already know what a vat and a
sturdyref are, skip back to the [README](../README.md) quickstart. The site's
Why OCapN page makes the same argument from the protocols you already run,
with a step-through picture (`zig build docs-serve`, then Explore).

## What a capability is

A capability is a reference that _is_ the permission. If you hold a reference to
an object, you can call it. If you do not hold it, you cannot, and you cannot
forge one, guess one, or escalate your way to one. There are no access-control
lists, role checks, or string-typed permission names to consult. An unauthorized
caller has nothing to make the call with.

Most systems use ambient authority: a program runs with a pool of permissions
attached to its identity, and every library it links shares that pool. A
capability system has no pool. Authority arrives one reference at a time, from
whoever chose to hand it over.

Three patterns fall out of that rule:

- **Delegation.** Handing someone a capability grants the permission. Passing
  the reference is the grant.
- **Attenuation.** To grant less than you hold, wrap the capability in an object
  that exposes only the narrower surface, and hand out the wrapper.
- **Revocation.** Hand out a forwarder you control. When you cut the forwarder,
  every copy of the grant dies with it.

In ordinary memory-safe programming you already live by this rule: an object
reference can only be used by code it was given to. Capability security is that
discipline taken seriously. CapTP is what lets it cross a network.

## What CapTP adds

[CapTP](http://erights.org/elib/distrib/captp/) (the Capability Transport
Protocol, from the E language) extends those references over a connection. Two
programs open a session and hand each other references to local objects. A
peer can name only the references it was handed, because the session tables
mint every one of them and there is no directory to guess at. Confidentiality
on the wire is the netlayer's job, not the protocol's.

The trust boundary sits at the wire and its session tables. A vat is one
program's container of objects, running one message at a time. Within a single
vat, code that holds the vat handle can reach any object the vat hosts.
Capability discipline begins where two mutually suspicious parties meet.

CapTP also carries promises. Calling a remote object returns immediately with a
promise for the answer. You may call methods on that promise before it resolves;
the call is forwarded to wherever the answer turns out to live. That is promise
pipelining, and it collapses round trips into a single flight. The protocol also
keeps distributed garbage-collection accounts so unused exports are reclaimed.

When three parties are involved (Alice holds a capability to Carol's object and
wants to give it to Bob), CapTP defines the handoff: a signed introduction that
lets Bob present his grant to Carol directly, without Alice proxying every later
call. In pancake's application surface that introduction usually settles as the
live capability itself (a Host redeems the give inside the wait). Human
teaching plus runnable chapters: the site Concepts page
(`zig build docs-serve`) and `examples/zig/02_introduce_and_redeem.zig`.

## What OCapN is, and where Goblins fits

[OCapN](https://github.com/ocapn/ocapn) (the Object Capability Network) is the
standards effort, stewarded by the
[Spritely Institute](https://spritely.institute/) and a community group. It
turns CapTP into one interoperable protocol: an abstract message model, concrete
wire encodings, and netlayers. The draft specifications live in the OCapN
repository; this repository vendors a copy under
[`conformance/ocapn-spec/`](../conformance/ocapn-spec/).

[Spritely Goblins](https://spritely.institute/goblins/) is the reference
implementation in practice. Its wire behavior defines what interoperating means
today. pancake treats Goblins as the authority on what correct looks like.
`zig build goblins-interop` holds a live conversation with a real Goblins vat
in both directions, over Syrup and TCP. The per-binding steps cover the client
direction only; [`community-review.md`](community-review.md) says what each one
does and does not prove. The
[protocol diagrams](protocol-diagrams/README.md) flag the few places where
pancake speaks a Goblins convention the draft spec does not yet pin down.

pancake is the systems-language entry to that ecosystem: the protocol core in
Zig, a C ABI above it, and bindings so the same capability discipline is
reachable from Rust, Python, Deno, and Racket. Memory and allocation cost are
part of the contract. The [architecture](architecture.md) doc names those
budgets.

## Glossary

| Term               | Meaning                                                                                                                           |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| capability         | A reference that is itself the permission to use what it names.                                                                   |
| ambient authority  | Permission drawn from identity or environment rather than from a held reference.                                                  |
| CapTP              | The session protocol that carries capabilities, calls, and promises between two programs.                                         |
| OCapN              | The standardization of CapTP: one message model, several codecs and netlayers, many implementations.                              |
| vat                | One single-threaded container of objects; all calls into a vat run one turn at a time.                                            |
| turn               | One message delivery processed to completion inside a vat.                                                                        |
| reference          | A name for an object; _near_ if it lives in your vat, _far_ if it lives across a session.                                         |
| export / import    | Session-table positions for a shared object: export on the side that owns it, import on the side that received it.                |
| promise            | A reference to an answer that has not arrived yet; it later resolves to a value or breaks with a reason.                          |
| promise pipelining | Calling through a promise before it resolves, so dependent calls travel in one flight.                                            |
| swiss number       | A high-entropy name the host registers an object under, so a partner can fetch it through the bootstrap object.                   |
| bootstrap object   | The one well-known capability a fresh session starts with; everything else is fetched or passed from there.                       |
| sturdyref          | A durable, out-of-band token (peer plus swiss number) that can be turned back into a live reference later.                        |
| locator            | The `ocapn://` URI form that names a peer (and optionally a sturdyref) so a netlayer can dial it.                                 |
| handoff            | The signed three-party introduction that moves a capability from one session to another without proxying.                         |
| designator         | The part of a locator that names _which_ peer, usually a public key; the hints beside it say how to reach it.                     |
| give               | The signed introduction a handoff produces. The recipient presents it to the exporter to withdraw the capability it names.        |
| vow                | A promise for a value that has not settled yet; you may call through it before it does.                                           |
| netlayer           | The transport a locator names, bound to a byte stream. CapTP itself names no transport; pancake ships `tcp`, `keyed-tcp`, `inproc`, iroh, and webrtc. |
| codec              | The wire encoding of the message model; pancake ships Syrup and Cap'n Proto behind one dispatch boundary.                         |
| Syrup              | The S-expression-flavored binary encoding Goblins speaks; the default OCapN wire format.                                          |
