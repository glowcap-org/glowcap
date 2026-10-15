---
id: ADR-0223
status: accepted
date: 2026-10-14
tags: [foundation, session, security, performance]
decision: "A table key wider than one word declares the words that identify it, and both identity hashes run their multiplication once per word. Two keys are one key exactly when their words are equal. The outbound resolver link's purpose side, which carries the peer's answer positions, is such a key and hashes under the session secret like every other peer-chosen table."
supersedes: []
superseded_by: []
amends: [ADR-0218]
amended_by: []
---

# ADR-0223 A key of several words hashes word by word

## Context

ADR-0218 gave every session table a provenance and a hash to match: the
identity hash for positions this process mints, a keyed hash for positions
the peer chooses. Its `BiMap` kept one exception. A side whose key was a
union, the resolver purpose that names what an outbound resolver export is
for, fell back to the standard library's general hash, because a union does
not fold to one word. That side holds the peer's answer positions, so the
exception was the gap ADR-0218 closed everywhere else: the general hash runs
under a fixed seed, so a peer can compute positions whose hashes share one
slot offline and turn each lookup on the link into a scan. The same general
hash also cost about 1,700 instructions per call round trip on the caller,
hashing a 48-byte union several times per answer.

## Decision

`foundation.identity_hash` accepts a key that declares `identityWords`, an
array of words that is equal for two keys exactly when they are the same key.
`hash` and `wireHash` fold each word into the running product with the same
multiplication they run once for a one-word key, so a change in any word
changes the hash, and under the secret multiplier two keys that differ in any
word collide only at a value the secret decides. Equality compares the words.
`BiMap` names a provenance per side, since one side may hold positions this
process mints while the other holds the peer's. The outbound resolver link
keeps its export side on the identity hash and keys its purpose side under
the session secret in `Session.keyWireTables`.

## Scope (what this does not decide)

The driver's struct-keyed tables (capability keys, ingress ids, promise ids)
stay on the general hash. They are keyed by values this process mints, so
the gap does not apply to them, and none sits on the call round trip's
profile.

## Alternatives Considered

- **Fold the purpose to one word**: rejected because a purpose carries up
  to three positions, so no fold of it into one word is injective, and the
  identity hash's equality is equality of folds.
- **Hash the words with the general hash under the session secret**:
  rejected because the keyed multiplication already spreads each word and
  costs a few instructions per word where the general hash costs hundreds.
- **Key both sides of the outbound link**: rejected because the export side
  holds positions this process mints, and keying it would spend a second
  secret word per session for no table the peer can reach.

## Consequences

`identity_hash.eql`, `words`, and `Words` are the one definition of key
identity for every identity-keyed table and for the in-place scan of
`foundation.inline_rows.Table`. `session.promises.types.ResolverPurpose`
declares its words. `engine.peer_session_struct_budget_bytes` carries one
more secret word.

## Evidence and gate

`test/foundation/identity_hash_test.zig` proves a composite key is one key
exactly when its words are equal, hashes differently under two multipliers,
and finds its rows in both maps, and that a Node keys the purpose side of
each session's outbound link from its identity. `test/session/resolver_test.zig`
proves that every field of a resolver purpose is a word of its identity, so no
two purposes the link can hold share a key. `zig build test` holds the
per-session budget.

## Notes

ADR-0218 holds the provenance rule this amends.
