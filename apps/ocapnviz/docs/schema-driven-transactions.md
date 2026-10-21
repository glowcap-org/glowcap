---
type: static
description: How delete, rename, paste and duplicate find every reference to an entity through one declared reference graph.
sources:
  - resource: /apps/ocapnviz/src/engine/schema/
  - resource: /apps/ocapnviz/src/engine/edit-session.ts
---

# Schema-driven cascades

Delete, rename, paste, and duplicate must find every reference to an entity before they touch it. The reference graph is
declared once in the schema, and every cascade operation consumes it through one set of discovery primitives. A new event
kind, entity field, or id list is then one declaration.

The code is the authority: `src/engine/schema/` holds `refs.ts`, `edges.ts`, `doc-index.ts`, `walk.ts`, `cascade.ts`,
`clipboard.ts`, `extract.ts`, and `paste.ts`. Transactions live on `EditSession` in `src/engine/edit-session.ts`. The
Engine is the public door.

## Invariants this preserves

1. **The document is the source of truth and the world is a projection.** Every transaction commits to the document.
   `seekTo(clock.t)` rebuilds the world from it. The schema layer touches the document only.
2. **A transaction's state before and after are both schema-valid.** Its middle may be inconsistent, which is why
   validation runs at the transaction boundary rather than per intent.
3. **Atomicity covers the document and the id-mint counter**, so a rollback restores both.
4. **`seekTo(t)` is a pure function of the document.** Cascade walkers may not stash state on the engine that would
   change a later replay. Scratch state, such as paste's remap table, rides in the intent payload.
5. **Subscribers observe committed state**, never a half-applied transaction.
6. **Every reference is discoverable from the schema.** The compiler enforces event and entity edges, and a straggler check backs the document-index registry.

## Three classes of reference

**Event to entity.** Event payload fields naming an entity id: `peer-joined`'s `peerId`, `session-opened`'s `sessionId`,
`a`, and `b`, `message-sent`'s `messageId`, `sessionId`, `from`, and `to`, and so on.

**Entity to entity.** A session's `a` and `b` name peers. A message's `sessionId` names a session and its `from` and
`to` name peers.

**Document index to entity.** Arrays of ids living elsewhere in the document: `rowOrder`, `rowHidden`, `rowLabelHidden`,
and `rowBodyHidden`, each per category. Any new id list in the document joins this class, and the walker must purge or
rewrite it like any other reference.

## Branded ids

```ts
type PeerId = string & { readonly __brand: "PeerId" };
type SessionId = string & { readonly __brand: "SessionId" };
type MessageId = string & { readonly __brand: "MessageId" };
```

The edge map says which fields hold references. Brands
make the id types nominal: without them a `SessionId` passed where a `PeerId` belongs compiles fine. Strings are cast to
brands where they enter, at JSON parse, DOM keys, and sprite keys, and internal code is branded throughout.

## Edge maps

The graph is encoded as TypeScript mapped types, so a missing entry is a compile error.

```ts
type EventEdges = {
  [K in TimelineEvent["kind"]]: ReadonlyArray<EdgeSpec<K>>;
};

type EdgeSpec<K extends TimelineEvent["kind"]> = {
  field: RequiredKeys<Extract<TimelineEvent, { kind: K }>>;
  target: EntityKind;
};
```

Mapping over `TimelineEvent["kind"]` forces every event kind to have an entry, so adding a kind without declaring its
references does not compile. Constraining `field` to `RequiredKeys` forces the field to exist on that variant, so a typo
does not compile either. Optional fields are excluded. Every reference is required, so every cascade policy must produce
a real value and none can leave a dangling reference behind.

Entity edges follow the same shape. Document-index edges are a plain registry instead, because a new index is added by
editing the document's top-level shape and TypeScript cannot force a static registry to track that. The backstop is the
straggler check below.

## Cascade behaviors

`cascade.ts` and `paste.ts` implement these behaviors.

| Behavior       | Used by                            | What it does at the edge                                 |
| -------------- | ---------------------------------- | -------------------------------------------------------- |
| drop-dependent | `cascadeDelete`                    | Remove the dependent, and recurse into its own edges.    |
| rewrite        | `cascadeRewrite`                   | Replace the field with a constant new value.             |
| remap          | `cascadePaste`, `engine.duplicate` | Replace via a lookup table. Absent entries pass through. |
| clone-target   | `engine.duplicate`, through paste  | Deep-copy the dependent with fresh ids, and recurse.     |

`cascadePaste` rejects dangling external references before mutation, because that is a validity condition on the whole
incoming payload. Every reference is required, so a valid operation must rewrite its target or remove its dependent.

## Discovery, then per-operation walks

The operations have different control flow, so no single dispatcher serves them. `cascadeDelete` is a worklist: removing
a peer queues its sessions, which queue their messages. `cascadeRewrite` is a single pass. Paste walks an incoming
payload rather than the document.

They share discovery: given a target, find every site that references it. Three pure functions over the edge maps, in
`walk.ts`:

```ts
findEventRefs(events, targetKind, targetId): EventRefSite[]
findEntityRefs(doc, targetKind, targetId): EntityRefSite[]
findDocIndexRefs(doc, targetKind, targetId): DocIndexRefSite[]
```

They mutate nothing and need no engine. Every cascade operation consumes them and owns its own algorithm on top.

`cascadeDelete` carries a visited set. Cycles cannot form in the current schema, but the guard is cheap.
`cascadeRewrite` ends with a straggler check: it re-runs the three discovery functions against its own result and throws
if any reference to the old id survives. That check is the net for a missing entry in the edge maps. <!-- status-allow: runtime state or operation ordering -->

## Transactions

`beginTransaction(label)` and `endTransaction()` bracket a burst of intents. They nest by depth and the outermost label
wins. Everything between them coalesces into one history entry, and a transaction that changed nothing pushes no entry
at all. A bare `engine.dispatch` is the same thing with an implicit bracket.

Synchronous multi-intent commands use `asOneEdit(engine, label, body)` in `builder/as-one-edit.ts`. Its `finally` closes
the transaction even when the body throws. Gestures that begin and end on different browser events use the explicit
bracket and close it from their teardown path.

Validation before an ordinary intent goes through `engine.validate(intent)`, which answers without touching engine
state. It covers rename collisions and an `add-peer` carrying a user-supplied id, so the Inspector and tool options can
show the error inline. Paste validates its payload inside `cascadePaste` before mutation. Duplicate extracts a payload
and reaches the same path.

Whole-document parsing validates content when it enters from JSON. Hot intents do not pay for a redundant full-document
walk after every pointer move.
