# pancake: Vision

This file is the destination. The shipped inventory in
[`shipped.md`](shipped.md) tells you where the code is right now; this tells you
where it is going. When the two disagree, the code is the truth about the
present and this file is the truth about where the present is headed. If you are
deciding what to build next, build toward this.

## The goal

pancake aims to be the most performant OCapN implementation there is, and a
fully canonical one. The two goals pull in the same direction. Canonical means a
native Zig peer, or a peer written against any binding, can hold a complete and
correct OCapN conversation with a real Spritely Goblins peer, and with each
other, with no asterisks. Performant means it does all of that while treating
every allocation and copy on the wire path as a design event: forbidden,
intentional, or measured.

These goals have an order of authority, and it is never traded away. Correctness
comes first, always: a fast wrong answer is worthless, and a delightful wrong
answer is dangerous. Performance and ergonomics are co-equal seconds, never
traded against each other, because shipping one without the other misses the
goal. When two right answers conflict, this order breaks the tie, and the design
worth finding is the one that honors both instead of sacrificing either.

## The Number

The destination has a number: one node holds five hundred thousand live CapTP
sessions. Hold it as a budget, never as a claim. No surface in this repository
calls 500k an achievement until a gate proves it under real socket load. Until
then it is a design constraint that every struct on the session path answers to.

The portable core is synchronous and does no I/O, so the core alone cannot
deliver 500k. What it can do is make 500k impossible, by letting per-session
state bloat or by allocating on the wire path without naming it. The core's
obligation, then, is a per-session footprint small enough, and an allocation
discipline strict enough, that the adapter never has to fight its own substrate.
The gates defend that obligation, and the [ladder](ladder.md) owns its numbers:
the per-session inline and warmed footprint ceilings, and the wire path's
steady-state floor of one heap allocation per inbound delivery, which is the
owned-frame copy the event model requires and no more. A field added to session
state is a withdrawal from that budget, and it is justified like one. When the
adapter's day comes, its job is to turn the budget into a measurement against a
real socket.

## Two Surfaces, Both Idiomatic

pancake is consumed two ways, and both have to feel native to the person using
them.

- The Zig API should read like what a Zig programmer expects a modern OCapN
  library to be. Ownership, allocation, and lifetime are visible at the call
  that performs them, and there is no hidden runtime to learn before you can
  send a message.
- The C ABI should read like what a binding author expects to wrap. Opaque
  handles, fixed-width return codes, `ptr + len` views, callbacks, and explicit
  release. A Rust, Python, or Deno author should be able to bind it well without
  knowing any Zig.

A binding that feels like a second-class translation of the Zig API is a defect
in the ABI, not in the binding.

## The Application Surface Is The Library's Face

Performance and canonicality are necessary but not sufficient. The third thing
pancake competes on is how obvious it is to build with. An application developer
in any binding holds one object, a CapTP `Session`, and uses one small verb
vocabulary, the application surface the [bindings contract](../bindings/README.md)
enumerates. They fetch a capability by name, spawn a local object, and hand a
partner a reference to it, and the partner calls it back. Application code
carries no export-position bookkeeping, no manual flush, no hand-rolled receive
loop, and no protocol vocabulary on the happy path.

This surface is composition, not abstraction. Every layer underneath stays
present and visible: the `Session` composes the sans-io peer, the actor vat,
and the I/O adapter, and a consumer who outgrows it finds the peer one property
access away, at `session.peer`, for handoff, pipelining, and session control. The
capability patterns that make object-capability networking worth choosing are
ordinary code here. Delegation is passing a reference. Attenuation, a view that
forwards only the allow-listed verbs, and revocation, a forwarder you can sever,
are one `session.attenuate` or `session.caretaker` call each (ADR-0064). Those
patterns are why pancake fits services, real-time apps, and AI agent harnesses
equally, and a runnable cross-language example proves each one: `zig build
demo-rooms`, `demo-tasks`, and `demo-tools`. The bar is that a developer reads
thirty lines and builds, and what they build is least-authority by construction.

## Pluggable By Contract

Use the netlayers pancake ships, or bring your own. Use the codecs pancake
ships, or bring your own. This holds in Zig and in every binding, not only in
the core. Netlayers and codecs are contracts the core dispatches against, not
privileged built-ins. If swapping one out means reaching into the core, the
boundary is in the wrong place.

## Reachable On Modern Networks

OCapN is built so CapTP rides any netlayer, and the netlayer is where
reachability lives. A locator names a peer by a designator, conventionally a
self-authenticating public key. A transport picks the netlayer, and hints carry
whatever that netlayer needs to reach the peer. The same
locator bootstraps a session in band as Syrup or out of band as an
`ocapn://<designator>.<transport>` URI. pancake takes that literally: a peer is
named by a key, addresses are hints, and one locator form opens a session over
whichever netlayer the peer speaks.

Two peers that cannot open a raw socket to each other still have to talk. OCapN
makes "reachability without further configuration" a desired property of a
netlayer, and the canonical one, Tor onion, provides it. pancake should ship a
netlayer that gives that reachability on the modern internet: a
self-authenticating node identity as the designator, NAT traversal and relays so
a peer behind a home router is reachable without port-forwarding, and an
encrypted ordered channel underneath. A QUIC-based peer-to-peer netlayer in the
iroh shape is the obvious fit: its node id is OCapN's self-authenticating
designator, its relays and hole-punching give "reachable without further
configuration," and its QUIC streams are the secure, ordered, bidirectional
channel a netlayer must provide. It belongs behind the same netlayer contract
the TCP adapter uses, above the sans-io core and never inside it, so the core
never learns it exists. That is the answer to "is iroh in scope": yes, as a
netlayer, never as a core dependency.

Peer-to-peer is also a capability-graph property, not only a transport one. A
peer handing another peer a live reference to a third peer it has never met is
OCapN's three-party handoff, and that introduction is what turns a set of
connections into a mesh. The handoff substrate is pancake's responsibility;
making the introduced peer reachable is the netlayer's. Both have to be real for
"peer-to-peer" to be more than a word.

## Interop Is The Proof

The goal is not an OCapN library that passes its own tests. It is full,
bidirectional conversation:

- a native Zig peer with a real Goblins peer,
- a peer in any binding with a real Goblins peer,
- any pancake or binding peer with any other.

Conformance is load-bearing because of this. A semantic claim that no scenario
or fixture proves is not part of the vision yet; it is a wish.

## Drivers Above The Core, Never In It

The core stays small and sharp: codec-neutral semantics, authoritative session
state, a synchronous no-I/O engine, explicit frame ownership. The
framework-shaped pieces sit above it as optional drivers the core knows nothing
about.

- `pancake-actors` is a Goblins-style actor framework, so an application built
  on pancake feels as intuitive as one built on Goblins. It is a layer on top of
  the substrate. The substrate never grows actor semantics to serve it.
- `griddle` is a deterministic network simulator and fuzzer, so everything a
  pancake or Goblins peer can do can be exercised, replayed, and attacked under
  test.

"Library first" applies to the core: actors and griddle live above the library
line, so the core never pays for them. The actor layer is real in every binding
and in native Zig, reached through the one application surface described above.
Three runnable cross-language applications prove the dial half on one wire
(`demo-rooms`, `demo-tasks`, `demo-tools`), each joining clients in Zig, Rust,
Python, Racket, and Deno. The accountability application's Zig host and the
driver loopback test prove the hosting half. `griddle` is not implemented. Say
where each piece actually stands when asked, and do not narrate the unbuilt parts
as if they already run.

## What Never Gets Traded

Three things do not get sacrificed for convenience, for a deadline, or for one
binding's comfort.

- Performance. The wire path's copies stay forbidden, intentional, or measured.
- The architecture. Authority stays in the session, I/O stays in adapters, the
  core stays sans-io. Code that moves authority down into a codec or an adapter
  is wrong even when it works.
- This destination. A shortcut that makes one binding easier by making the
  others impossible, or that passes a test by diverging from Goblins on the
  wire, is not a shortcut. It is a regression against where pancake is going.

## Where We Are

For what actually runs today, read the shipped inventory in
[`shipped.md`](shipped.md); for where today's edges sit, read
[`boundaries.md`](boundaries.md). For the ordered route from here to 1.0 and
where each rung stands, read [the ladder](ladder.md). For why specific
boundaries sit where they do, read the ADRs under
[decisions/adr/](decisions/adr/). When you close a gap between here and there,
update the shipped inventory in `shipped.md` and the ladder's rung standing in
the same change, and write a superseding ADR rather than citing the one that
deferred the item as a reason to leave it undone.
