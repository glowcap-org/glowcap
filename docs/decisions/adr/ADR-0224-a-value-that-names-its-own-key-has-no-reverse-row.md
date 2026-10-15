---
id: ADR-0224
status: accepted
date: 2026-10-14
tags: [session, performance]
decision: "A two-way link's value may name its own key. Such a value is held in its forward row alone, a lookup by that value reads the row its key names, and a transition into or out of it touches one row. The reverse side is keyed by the value's identity words, computed once per operation. A node-settling or retired resolver names the export it holds, so the outbound resolver link indexes only the purposes that serve an answer or a promise."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0224 A value that names its own key has no reverse row

## Context

The outbound resolver link pairs each resolver export with the purpose it
serves. Both sides were hash tables kept in lockstep, so every transition of
a purpose removed and re-inserted its reverse row and every retired
tombstone held one. A retired resolver serves no answer or promise: it waits
for the partner to release its mention. Its only name is the export it
retired, and nothing ever asks the link which export a retired purpose
belongs to. Still, one call round trip hashed the four-word purpose eight
times on the caller, for about a thousand instructions, five of them to
maintain reverse rows no lookup read.

## Decision

`BiMap` accepts a value type that declares `namedKey`: for a value that is
its own name it returns the key, and for every other value it returns null.
A self-named value takes no reverse row. `put`, `putAssumeNoClobber`, and
`replaceValueForKey` assert it is paired with the key it names, and
`getByValue` on it reads the forward row that key names and answers the key
exactly when the row holds that value. The bijection is unchanged: a value
still pairs with at most one key, and both sides still leave together.
`replaceValueForKey` writes the forward row in place.

The reverse side is keyed by `identity_hash.Words(V)`, the array of words
that identifies a value, and an array of words is itself an identity key with
the same hash as the key it came from. An operation reduces its value to
words once, and the table hashes and compares those words instead of calling
back into the union for every probe. A one-word value's words are the one
word it folds to, so the inbound link is unchanged in cost.

`bindFreshResolverExport` reserves the link, allocates the export, and
installs the pair with `putAssumeNoClobber`. Every caller binds an answer no
export serves yet, so the eviction lookups of `installOutboundResolver` are
left to the fetch path that may re-install.

`ResolverPurpose.namedKey` names the export for `node_settling` and
`retired`. The four purposes that serve an answer or a promise stay indexed,
because the session asks which export serves a given answer, local promise,
or shortening source.

`Session.releaseRetiredResolverIfUnmentioned` keeps its lookup form for the
GC path, and the four transitions that write a retired purpose pass it along
instead of reading it back. One export count answers both whether the export
row still exists and whether the partner still holds a mention.

## Scope (what this does not decide)

The inbound resolver link keeps both sides: an answer name and an import
position are each the other's name and nothing else.

## Alternatives Considered

- **A field on the answer cell for its resolver export**: rejected because
  the purpose on the forward side already names the answer, so the cell's
  field would be a second home for one fact.
- **Dropping `resolver_export` from the self-named purposes**: rejected
  because the field is what lets the link assert that a self-named value sits
  under the key it names.

## Consequences

A session holds a reverse row per purpose that serves something, and none
per tombstone, each row 32 bytes of words rather than a 48-byte union. A
transition into a retired purpose is one forward write. One call round trip
on the caller hashes a purpose's words three times instead of eight.
`test/session/bimap_test.zig` proves a self-named value holds no reverse row,
is found from either side, and that transitions into and out of it keep the
link whole.

## Evidence and gate

`zig build test`, with the resolver and BiMap tests under
`-Dtest-layer=session`. The callgrind recipe on the benchmarks page measures
the caller's share.

## Notes

ADR-0223 keys the purpose side under the session secret, which still applies
to every purpose that holds a reverse row.
