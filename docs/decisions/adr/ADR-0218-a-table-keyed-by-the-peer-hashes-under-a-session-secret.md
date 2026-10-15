---
id: ADR-0218
status: accepted
date: 2026-10-13
tags: [foundation, session, engine, security, performance]
decision: "Every session table names who chooses its keys. A table keyed by positions this process allocates hashes them by identity. A table keyed by positions the peer chooses hashes them under a secret odd multiplier followed by a public finisher. The Node derives one multiplier per session from its identity seed and the peer handle, and hands it to the session at registration beside its export range."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0223]
---

# ADR-0218 A table keyed by the peer hashes under a session secret

## Context

A pinned `tcp` round trip spent about a thousand instructions hashing
positions with the standard library's general hash. Positions are small
integers this process or its peer allocated in order, and an identity hash
(one multiplication) places them perfectly. Moving every table to it would
have handed a peer the slot function: an import position is the peer's
export position, an inbound answer position is whatever unused position the
peer names, and a peer that knows the slot function can pick positions that
all share one slot and turn each lookup into a scan of its table. The
general hash the tables had was not safe either, only harder: it runs under
a fixed seed, so the colliding set can be computed offline once and used
against every glowcap process.

## Decision

`foundation.identity_hash` holds both hashes and a `Provenance` every table
states at its declaration. `MapOf(.local, K, V)` is the identity hash.
`MapOf(.wire, K, V)` is `WireMap`, the keyed hash: the key is multiplied by
a secret odd multiplier, a bijection, so the peer cannot tell which product
its position becomes, and a public finisher (a shift, a multiplication, a
shift) spreads that product across every bit, so the sequential positions an
honest peer allocates land as if at random. A `WireMap` carries its
multiplier as one word and is built only with `keyed`, so no table hashes
under a multiplier its owner did not name.

The secret is one per session. `engine.Node` derives a root from its
identity seed under its own key-derivation domain, mixes the peer handle
into it for each session, and hands the result to the session through
`keyWireTables` at registration, on the owned and the adopted path alike,
beside the export range it hands out the same way. A handle repeats across
restarts of one durable identity, so the Host mixes a fresh salt into that
multiplier when it postures the peer (`NegotiatingOptions.wire_hash_salt`,
derived from the session's seed under its own domain), and no two sessions
of one process, nor of two processes under one identity, hash under one
secret. The session copies the result into each wire-keyed table, because
the table's verbs run without the session in hand. A session built outside
a Node keeps the public golden-ratio constant from `Session.Options`, which
keeps a bare core deterministic and reaches no peer.

The bare-key namespace check reads every identity map form, so a table
without a provenance, or with a bare key type, still fails `source-check`.

## Scope (what this does not decide)

- The cold-path maps that never see a peer-chosen key on a call path (node
  handoffs, proxies, webrtc, loam, the C ABI) keep the standard map. Each
  moves when it is read for the provenance call, not in a sweep. Two have
  been read and stay: the handoff waiters' gift tags
  (`handoffs/waiters.zig`), bounded by `max_pending_withdraws` on a path
  that runs once per handoff, and the Host's maps keyed by a partner's
  public key, where each entry costs the partner a key generation and
  admission bounds the count.
- Any table keyed by bytes, which keeps the standard string map.

## Alternatives Considered

- One multiplier per process, latched in a module variable by the first
  Node. Rejected by evidence: the enliven test that drives a session from
  an independently compiled archive failed, because each archive links its
  own copy of the variable and the two halves hashed one table under two
  secrets. A process secret in a library that composes from archives is
  two authorities for one fact.
- A multiply-shift hash alone, reading the slot from the product's top bits.
  It is a universal hash family, but under a multiplier that sits near a
  small fraction of the word (one in eight random multipliers in the
  evidence run) sequential keys fold onto fewer than half the slots. The
  public finisher costs four instructions and removes that.
- The multiplier as a `NegotiatingOptions` knob. Rejected for the reason
  the export range is not one: a posture the embedder builds must not be
  able to carry or overwrite a secret the Node owns.

## Consequences

- One `tcp` round trip spends about a thousand fewer instructions on hashing
  on the server, and the slot hash is seven arithmetic instructions.
- `engine.Peer` grows by 48 bytes: the session's word and one in each of
  its five wire-keyed tables. The per-session struct budget names them.
- A peer that precomputes colliding positions against the public finisher
  collides in one slot under the default multiplier and spreads under any
  seeded one. What a peer could learn about its own session's secret says
  nothing about another session's.
- Every session table declaration reads as `MapOf(.local, ...)` or
  `MapOf(.wire, ...)`, so a reader sees who chooses the keys at the
  declaration. A `WireMap` has no default construction. A session table
  built by default starts under the public constant and is keyed before it
  holds a row.

## Evidence and gate

- `test/foundation/identity_hash_test.zig`: identity keys fold to themselves,
  crafted colliding keys spread under a secret multiplier, sequential keys
  spread under a multiplier near a small fraction, a wire map finds its rows
  under its multiplier, and a Node keys each session differently.
- `test/driver/core_host/enliven_test.zig`, "owned observations cancel
  across independently compiled archives": the canary for any process-wide
  state in a library that composes from archives.
- `zig build source-check` holds the bare-key namespace list against the
  identity map forms.
