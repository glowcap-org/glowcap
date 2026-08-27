---
id: ADR-0138
status: accepted
date: 2026-08-26
tags: [rooms, browser, react, sessions, state, performance]
decision: "The Rooms browser injects browser-owned behavior and the established session controller through separate stable React contexts, while one non-persistent Zustand store projects revisioned session and browser view facts through selector subscriptions."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: []
---

# ADR-0138 Rooms browser controller and projection

## Context

The browser exposed one `Peer` context containing presentation actions, session establishment, local and attached
workspace commands, file custody, directory queries, and operator administration. That value was stable, but its name
conflicted with pancake's CapTP vocabulary and its shape hid ownership. The attached adapter copied browser-only actions
out of the local implementation before replacing the session-dependent actions.

The page projection used a correct immutable external store, but React subscribed to its complete snapshot at the
application root. A composer keystroke therefore re-rendered the root before memoized descendants could reject it.
Adding contexts for changing state would move the cost rather than establish a clearer authority.

## Decision

The browser has two injected controllers:

- `RoomsBrowserController` exists before session establishment. It owns presentation, modal and rail state, browser data
  deletion, and selection of a local or attached session.
- `RoomsSessionController` exists only after establishment. Its local and attached implementations own directory,
  conversation, room, archive, operations, and workspace commands.

The establishment screen receives only the browser controller. The Rooms router is nested inside both providers, so a
Rooms component cannot render before a session exists. An attached session receives the three browser actions needed by
its slash-command adapter directly; it never borrows an action table from the local session implementation.

Both contexts hold stable imperative controllers. They do not carry changing snapshots, capability references, or
promises intended to drive rendering. A controller may retain one in-flight promise to serialize or coalesce work in the
current process. Durable idempotence remains the session's operation ID and effect ledger, not promise identity.

One vanilla Zustand store owns the browser's non-authoritative projection. Network and session adapters write immutable
snapshot fields through the store's domain modules. React components subscribe through `useRoomsState` selectors.
Aggregate selectors use shallow identity comparison; leaf selectors return retained maps, rows, or primitives. The store
has no persistence middleware and never stores live capability authority. Browser workspace persistence and the durable
session checkpoint remain the authorities established by ADR-0133 through ADR-0135.

React Suspense is reserved for cached render-time reads whose owner can supply one stable resource. Command progress,
refusal, and retry remain explicit domain phases. `useActionState` may own a form's local result, but it cannot replace
a session operation phase that must survive the form unmounting.

## Performance boundary

Draft edits subscribe the active `Stream`, not `App`. The root selector excludes drafts and last-sent recall state, so a
keystroke does not rebuild directory, rail, operations, settings, and modal derivations. Operations, routes, session
settings, grants, and establishment subscribe only to the fields they render.

Zustand is a browser projection dependency, not a domain dependency. It stays out of Rooms schemas, session hosts,
network adapters, and the browser runtime binding. Replacing the projection mechanism cannot change checkpoint,
capability, command, or OCapN semantics.

The landing's browser bundle measurement compares the same `deno bundle` command with its parent tree. The readable
development bundle changes from 2,833,154 to 2,818,474 bytes and its gzip form from 561,174 to 561,562 bytes. The
minified bundle changes from 992,509 to 994,036 bytes and its gzip form from 301,265 to 301,913 bytes. The selector
dependency therefore costs 648 gzip bytes in the production-shaped bundle while deleting more unminified application
source than it adds.

## Consequences

The local and attached session adapters must satisfy the same grouped controller contract, while browser-only behavior
has one implementation. New state is classified by authority and lifetime before it receives a context or store field. A
feature context is warranted only for browser-local state that must outlive its controls and does not belong in the page
projection.

The focused store and attached-session suites cover immutable updates, attachment behavior, command serialization, state
import and clearing, attachment establishment, and shared-session semantics. The page type check proves every consumer
is under the provider matching the actions it uses.
