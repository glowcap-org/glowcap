# pancake: Vision

This file is the destination. [`shipped.md`](shipped.md) says what the code does
today. When the two disagree, the code is the truth about the present, and this
file is where the present is headed. Build toward this.

## The goal

pancake aims to be a fully canonical OCapN implementation and a highly
performant one. Canonical means a native Zig peer, or a peer in any binding, can
hold a complete and correct OCapN conversation with a real
[Spritely Goblins](https://spritely.institute/goblins/) peer, and with each
other, with no asterisks. Performant means every allocation and copy on the wire
path is forbidden, intentional, or measured.

Correctness comes first. A fast wrong answer is worthless. Performance and
ergonomics are co-equal seconds: shipping one without the other misses the goal.
When two right answers conflict, find the design that honors both.

## The number

One node should hold five hundred thousand live CapTP sessions. Treat that as a
budget, not a claim. No surface calls 500k an achievement until a gate proves it
under real socket load.

The portable core is synchronous and does no I/O, so it cannot deliver 500k by
itself. It can make 500k impossible by letting per-session state bloat or by
allocating on the wire path without naming it. The core's job is a small enough
per-session footprint, and a strict enough allocation discipline, that the
adapter never fights its own substrate. The [ladder](ladder.md) owns the gated
numbers. A field added to session state is a withdrawal from that budget.

## Two surfaces, both idiomatic

pancake is consumed two ways, and both must feel native:

- The Zig API should read like what a Zig programmer expects from a modern OCapN
  library. Ownership, allocation, and lifetime stay visible at the call that
  performs them. There is no hidden runtime to learn before you send a message.
- The C ABI should read like what a binding author expects to wrap: opaque
  handles, fixed-width return codes, `ptr + len` views, callbacks, and explicit
  release. A Rust, Python, or Deno author should bind it well without knowing
  Zig.

A binding that feels like a second-class translation of the Zig API is a defect
in the ABI, not in the binding.

## The application surface

pancake also competes on how obvious it is to build with. An application
developer in any binding holds one object, a CapTP `Session`, and a small verb
vocabulary (see the [bindings contract](../bindings/README.md)). They fetch a
capability by name, spawn a local object, and hand a partner a reference. The
partner calls it back. Happy-path application code carries no export-position
bookkeeping, no manual flush, no hand-rolled receive loop, and no protocol
vocabulary.

The surface is composition, not abstraction. The `Session` composes the sans-io
peer, the actor vat, and the I/O adapter. A consumer who outgrows it reaches the
peer at `session.peer`. Delegation is passing a reference. Attenuation and
revocation are one `session.attenuate` or `session.caretaker` call each
(ADR-0064). Cross-language demos prove the shape: `zig build demo-rooms`,
`demo-tasks`, and `demo-tools`.

## Pluggable by contract

Use the netlayers and codecs pancake ships, or bring your own. That holds in Zig
and in every binding. Netlayers and codecs are contracts the core dispatches
against, not privileged built-ins. If swapping one out means reaching into the
core, the boundary is wrong.

## Reachable on modern networks

OCapN lets CapTP ride any netlayer. A locator names a peer by a designator,
usually a self-authenticating public key. Hints carry what the netlayer needs to
reach the peer. The same locator can bootstrap a session in band as Syrup or out
of band as an `ocapn://<designator>.<transport>` URI.

Two peers that cannot open a raw socket still need to talk. pancake should ship
a netlayer that gives reachability on the modern internet: a self-authenticating
node identity, NAT traversal and relays, and an encrypted ordered channel. A
QUIC peer-to-peer netlayer in the [iroh](https://www.iroh.computer/) shape fits:
its node id is the designator, its relays and hole-punching give reachability
without port-forwarding, and its QUIC streams are the channel. It belongs behind
the same netlayer contract as TCP, above the sans-io core and never inside it.

Peer-to-peer is also a capability-graph property. Introducing a third peer is
OCapN's three-party handoff. The handoff substrate is pancake's job; making the
introduced peer reachable is the netlayer's. Both have to be real.

## Interop is the proof

The goal is full, bidirectional conversation:

- a native Zig peer with a real Goblins peer,
- a peer in any binding with a real Goblins peer,
- any pancake or binding peer with any other.

A semantic claim that no scenario or fixture proves is a wish, not part of the
vision yet.

## Drivers above the core

The core stays small: codec-neutral semantics, authoritative session state, a
synchronous no-I/O engine, and explicit frame ownership. Framework-shaped pieces
sit above it as optional drivers the core does not know about.

- The actor layer is a Goblins-style framework so an application on pancake
  feels as intuitive as one on Goblins. The substrate never grows actor
  semantics to serve it.
- `griddle` is a planned deterministic network simulator and fuzzer. It is not
  implemented.

The actor layer is real in every binding and in native Zig, reached through the
application surface above. Three cross-language demos prove the dial half
(`demo-rooms`, `demo-tasks`, `demo-tools`). The accountability host and the
driver loopback test prove the hosting half. Say where each piece stands; do not
narrate unbuilt parts as if they already run.

## What never gets traded

These do not get sacrificed for convenience, a deadline, or one binding's
comfort:

- Performance. Wire-path copies stay forbidden, intentional, or measured.
- The architecture. Authority stays in the session, I/O stays in adapters, the
  core stays sans-io.
- This destination. A shortcut that eases one binding by blocking the others, or
  that passes a test by diverging from Goblins on the wire, is a regression.

## Where we are

For what runs today, read [`shipped.md`](shipped.md). For today's edges, read
[`boundaries.md`](boundaries.md). For the ordered route to 1.0, read
[the ladder](ladder.md). For why specific boundaries sit where they do, read the
ADRs under [decisions/adr/](decisions/adr/). When you close a gap, update
`shipped.md` and the ladder in the same change, and write a superseding ADR
rather than citing a deferral as a reason to leave work undone.
