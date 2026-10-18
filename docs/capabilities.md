---
type: static
description: A short glossary of object capabilities, CapTP and OCapN for readers new to them.
sources:
  - resource: https://github.com/ocapn/ocapn
  - resource: /examples/zig/02_introduce_and_redeem.zig
---

# Capabilities, CapTP, and OCapN

Start here if object-capability security is new to you and you want a short
glossary. For the guided explanation with diagrams, read [Why
OCapN](https://jimisaacs.github.io/glowcap/why/). If the terms already feel
familiar, go to the [quick start](../README.md#quick-start).

## A capability is a reference with authority

If you hold a capability to an object, you may call it. If you do not, you
cannot forge or guess one. Passing the reference passes that permission.

Capability systems can still use roles or policy where an application needs
them, but at the object boundary permission arrives as a reference.

This avoids *ambient authority*, where a program and every library it loads can
draw from one shared pool of permissions. In a capability design, permission
arrives one reference at a time from someone who chose to grant it.

Three common patterns follow:

- **Delegation:** pass a capability to someone else.
- **Attenuation:** wrap it with an object that exposes fewer operations.
- **Revocation:** pass a forwarder that you can later switch off.

These are ordinary object-reference patterns. CapTP carries them across a
network.

A capability decides what its holder may do, not who the holder is.
[What about identity?](https://jimisaacs.github.io/glowcap/identity/) covers how a service tells people
from bots and hands each one its own key.

## CapTP carries references between programs

[CapTP](https://web.archive.org/web/20250114141521/http://erights.org/elib/distrib/captp/) is the Capability Transport
Protocol. Two programs open a session, export local objects, and pass references
to each other.

The session assigns wire positions to those references and rejects positions
the other peer was never given. A new session begins with one bootstrap
capability. Any directory or lookup service is reached through that object, not
through a global object namespace.

Remote calls return promises. A caller may send the next operation to a promise
before its answer arrives. CapTP forwards that operation when the promise
settles (is fulfilled or broken). This is *promise pipelining*, and it can
turn a chain of dependent calls into one network flight.

CapTP also supports three-party handoff. If Alice holds a capability to Carol's
object and wants Bob to have it, Alice introduces them. Bob redeems that
introduction with Carol and receives a direct capability. Alice does not remain
as a proxy.

glowcap handles this under its session API. The call awaiting the introduced
object settles to the live capability after redemption. Run
[`examples/zig/02_introduce_and_redeem.zig`](../examples/zig/02_introduce_and_redeem.zig)
to see the whole exchange.

CapTP does not choose encryption or network reachability. Those belong to the
netlayer carrying its byte stream.

## OCapN makes CapTP interoperable

[OCapN](https://github.com/ocapn/ocapn), the Object Capability Network, defines
an interoperable message model, wire encodings, and netlayers for CapTP. The
work is stewarded by the [Spritely Institute](https://spritely.institute/) and
the OCapN community.

[Spritely Goblins](https://spritely.institute/goblins/) is the main reference
implementation in practice and glowcap's live interop peer.

glowcap provides the protocol core in Zig, a C ABI, and bindings for Rust,
TypeScript, Python, and Racket. It speaks
[Syrup](https://github.com/ocapn/syrup), the canonical OCapN encoding, and can
also use Cap'n Proto between glowcap peers.

For the implementation, read [Architecture](architecture.md). For exact
outside-peer coverage, read [Community review](community-review.md). The
[protocol diagrams](protocol-diagrams/README.md) show the conversations on the
wire.

## Glossary

| Term | Meaning |
| --- | --- |
| capability | A reference that conveys permission to use what it names. |
| ambient authority | Permission drawn from identity or environment rather than a held reference. |
| CapTP | The session protocol carrying capabilities, calls, and promises between programs. |
| OCapN | The interoperable CapTP message model, codecs, and netlayers. |
| vat | A container of objects that processes one message at a time. |
| turn | One message delivery processed to completion inside a vat. |
| reference | A name for an object: *near* in your vat, *far* across a session. |
| export / import | The session-table positions for an object on its owning and receiving sides. |
| promise | An OCapN passable reference representing an eventual fulfillment or break. |
| vow | In Goblins, a promise you can pass to another object. In glowcap, `Vow` is a local handle for watching the result of a send. It never crosses the wire. |
| answer position | The sender-chosen CapTP session slot (`desc:answer`) used to pipeline sends against a promise. |
| promise pipelining | Calling through a promise before it settles so dependent calls share a flight. |
| bootstrap object | The one well-known capability available when a session opens. |
| swiss number | A long random secret name registered under the bootstrap object, so the object can be fetched later. |
| sturdyref | Durable data containing a peer locator and swiss number. Redemption still depends on that peer continuing to answer at the locator and honor the registration. |
| locator | An `ocapn://` URI identifying an OCapN peer, and optionally one of its objects, for the selected netlayer to reach. |
| designator | The part of a locator that names the peer: a public key, an onion service id, an iroh node id, or a cleartext TCP `host:port`. Most designators prove who answers, but a TCP `host:port` does not. Hints help reach the peer and are never identity. |
| handoff | A signed three-party introduction that moves a capability without keeping the introducer as proxy. |
| give | The signed introduction presented to the exporting peer during handoff. |
| netlayer | OCapN's word for a transport: how a locator's bytes reach the peer. [Known limitations](boundaries.md) says what each one proves. |
| codec | A wire encoding for the message model. glowcap ships Syrup and Cap'n Proto. |
| Syrup | The S-expression-shaped binary encoding used by OCapN and Goblins. |
