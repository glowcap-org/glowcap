---
id: ADR-0196
status: accepted
date: 2026-10-04
tags: [publication, host, bindings, security]
decision: "A fetch answers from the session's own publications first, then the Host's, then the durable provider, so nothing published outside a session can take over a name inside it. The receiver names the scope: Session.publish and Host.publish, with no third word; the Zig Host spells the session-scoped verb sessionPublish, as the C ABI spells glowcap_host_session_publish."
supersedes: []
superseded_by: []
amends: [ADR-0096]
amended_by: []
---

# ADR-0196 Publication scope and lookup

## Context

Two publication scopes exist on purpose. A Session publication answers only
the partner on that session; Rooms' archive proof, the introduction example and
the CLI rely on that. A Host publication answers every session, so an
introduction can hand it to a third peer.

A fetch consulted the Host table first. Publishing a Host name later therefore
redirected a partner that had been fetching its own session's object under the
same name, without either side seeing a change. The usual scoping rule puts the
inner scope first, and it is the only order in which a session's names cannot
be changed from outside it.

The Host scope was called "giftable", which names a consequence (it can be
handed on) rather than the scope. The C ABI already named both scopes by their
receiver: `glowcap_host_session_publish` and `glowcap_host_publish`.

## Decision

- `engine.bootstrap.resolveForSwissnum` answers from the session's own
  publication table before it asks the composition. The composition sees only
  names the session missed, so `FetchContext` carries no session fallback.
  `publication_lookup.resolveFetch` consults the Host table, where a hidden
  durable reservation still keeps storage from being consulted, then the
  durable provider.
- The receiver names the scope. The bindings have `Session.publish` and
  `Host.publish`, with `unpublish` beside the latter. The Zig `Host` takes a
  session as an argument for session verbs, so its session-scoped verb is
  `sessionPublish`, matching the C name; `Host.publish` is the Host scope.

## Alternatives Considered

- **Keep Host first and document it.** Rejected: the order lets code outside a
  session change what a partner reaches.
- **One table for both scopes.** Rejected: a session-scoped publication is an
  authority boundary Rooms and the CLI depend on.
- **A new adjective such as "Host-wide".** Rejected: the receiver already says
  it.

## Evidence

[`test/driver/core_host/actors/scope_test.zig`](../../../test/driver/core_host/actors/scope_test.zig) publishes one name on a session
and later on the Host, and shows the partner still reaches the session's object
while another session reaches the Host's.
