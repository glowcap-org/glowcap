# Schema-driven cascades

Delete, rename, paste, and duplicate all have to find every reference to an entity before they touch it. This is how
they find them: the reference graph is declared once in the schema, and every cascade operation consumes it through one
set of discovery primitives.

Before this, each operation walked the graph by hand. `deletePeer`, `deleteSession`, `deleteMessage`, and `rekeyEntity`
each re-encoded the same knowledge, and `event-helpers.ts` held a second copy of it for events. A new event kind, entity
field, or id list broke every walker that forgot to update, silently.

The code is the authority: `src/engine/schema/` holds `refs.ts`, `edges.ts`, `doc-index.ts`, `walk.ts`, `cascade.ts`,
`clipboard.ts`, `extract.ts`, and `paste.ts`. Transactions live on `EditSession` in `src/engine/edit-session.ts`; the
Engine is the public door.

## Invariants this preserves

1. **The document is the source of truth and the world is a projection.** Every transaction commits to the document;
   `seekTo(clock.t)` rebuilds the world from it. The schema layer touches the document only.
2. **A transaction's state before and after are both schema-valid.** Its middle may be inconsistent, which is why
   validation runs at the transaction boundary rather than per intent.
3. **Atomicity covers the document and the id-mint counter**, so a rollback restores both.
4. **`seekTo(t)` is a pure function of the document.** Cascade walkers may not stash state on the engine that would
   change a later replay. Scratch state, such as paste's remap table, rides in the intent payload.
5. **Subscribers observe committed state**, never a half-applied transaction.
6. **Every reference is discoverable from the schema**, and the compiler enforces it rather than a test.

## Three classes of reference

**Event to entity.** Event payload fields naming an entity id: `peer-joined`'s `peerId`, `session-opened`'s `sessionId`,
`a`, and `b`, `message-sent`'s `messageId`, `sessionId`, `from`, and `to`, and so on.

**Entity to entity.** A session's `a` and `b` name peers; a message's `sessionId` names a session and its `from` and
`to` name peers.

**Document index to entity.** Arrays of ids living elsewhere in the document: `rowOrder`, `rowHidden`, `rowLabelHidden`,
and `rowBodyHidden`, each per category. Future indexes such as bookmarks or named groups join this class, and the walker
must purge or rewrite them like any other reference.

## Branded ids

```ts
type PeerId = string & { readonly __brand: "PeerId" };
type SessionId = string & { readonly __brand: "SessionId" };
type MessageId = string & { readonly __brand: "MessageId" };
```

Brands and the edge map solve different halves of the same problem. The edge map makes references discoverable; without
brands every walker call site is stringly-typed and a `SessionId` passed where a `PeerId` belongs compiles fine. Brands
make the types nominal; without the edge map nothing can tell you which fields hold one. The cost is roughly thirty
casts at the boundary where strings enter, at JSON parse, DOM keys, and sprite keys. Internal code is branded
throughout.

## Edge maps

The graph is encoded as TypeScript mapped types, so coverage is a compile error rather than a test failure.

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
does not compile either. Excluding optional fields is deliberate: with invariant 2 in force, every reference is
required, so every cascade policy must produce a real value and none can leave a dangling reference behind.

Entity edges follow the same shape. Document-index edges are a plain registry instead, because a new index is added by
editing the document's top-level shape and TypeScript cannot force a static registry to track that. The backstop is the
straggler check below.

## Cascade behaviors

The functions in `cascade.ts` and `paste.ts` implement the operations directly, each with the control flow that fits.

| Behavior       | Used by                            | What it does at the edge                                 |
| -------------- | ---------------------------------- | -------------------------------------------------------- |
| drop-dependent | `cascadeDelete`                    | Remove the dependent, and recurse into its own edges.    |
| rewrite        | `cascadeRewrite`                   | Replace the field with a constant new value.             |
| remap          | `cascadePaste`, `engine.duplicate` | Replace via a lookup table; absent entries pass through. |
| clone-target   | `engine.duplicate`, through paste  | Deep-copy the dependent with fresh ids, and recurse.     |

There is no generic policy union. Dangling external references are rejected by `cascadePaste` before mutation, because
that is a validity condition on the whole incoming payload rather than behavior for one edge. There is no `nullify`:
every current reference is required, so a valid operation must rewrite its target or remove its dependent.

## Discovery, then per-operation walks

An earlier plan had one `cascade(ctx, target, policies)` dispatcher. Building it showed the operations have genuinely
different control flow. `cascadeDelete` is a worklist: removing a peer queues its sessions, which queue their messages.
`cascadeRewrite` is a single pass. Paste walks an incoming payload rather than the document. One dispatcher over all of
them hides more than it shares.

What they do share is discovery. Given a target, find every site that references it. Three pure functions over the edge
maps, in `walk.ts`:

```ts
findEventRefs(events, targetKind, targetId): EventRefSite[]
findEntityRefs(doc, targetKind, targetId): EntityRefSite[]
findDocIndexRefs(doc, targetKind, targetId): DocIndexRefSite[]
```

No mutation, no engine dependency. Every cascade operation consumes them and owns its own algorithm on top.

`cascadeDelete` carries a visited set. Cycles cannot form in the current schema, but the guard is cheap.
`cascadeRewrite` ends with a straggler check: it re-runs the three discovery functions against its own result and throws
if any reference to the old id survives. That check is the net for a missing entry in the edge maps.

## Transactions

`beginTransaction(label)` and `endTransaction()` bracket a burst of intents. They nest by depth and the outermost label
wins. Everything between them coalesces into one history entry, and a transaction that changed nothing pushes no entry
at all. A bare `engine.dispatch` is the same thing with an implicit bracket.

Synchronous multi-intent commands use `asOneEdit(engine, label, body)` in `builder/as-one-edit.ts`. Its `finally` closes
the transaction even when the body throws. Gestures that begin and end on different browser events use the explicit
bracket and close it from their teardown path.

Validation before an ordinary intent goes through `engine.validate(intent)`, which answers without touching engine
state. It covers rename collisions and an `add-peer` carrying a user-supplied id, so the Inspector and tool options can
show the error inline. Paste validates its payload inside `cascadePaste` before mutation; duplicate extracts a payload
and reaches the same path.

The straggler checks at the end of rewrite and paste catch a missing edge declaration at the operation boundary.
Whole-document parsing validates content when it enters from JSON; hot intents do not pay for a redundant full-document
walk after every pointer move.
