# Schema-driven cascades

Delete, rename, paste, and duplicate all have to find every reference to an
entity before they touch it. This is how they find them: the reference graph is
declared once in the schema, and every cascade operation consumes it through one
set of discovery primitives.

Before this, each operation walked the graph by hand. `deletePeer`,
`deleteSession`, `deleteMessage`, and `rekeyEntity` each re-encoded the same
knowledge, and `event-helpers.ts` held a second copy of it for events. A new
event kind, entity field, or id list broke every walker that forgot to update,
silently.

The code is the authority: `src/engine/schema/` holds `refs.ts`, `edges.ts`,
`doc-index.ts`, `walk.ts`, `cascade.ts`, `clipboard.ts`, `extract.ts`, and
`paste.ts`. Transactions live on the engine itself, in `src/engine/engine.ts`.

## Invariants this preserves

1. **The document is the source of truth and the world is a projection.** Every
   transaction commits to the document; `seekTo(clock.t)` rebuilds the world
   from it. The schema layer touches the document only.
2. **A transaction's state before and after are both schema-valid.** Its middle
   may be inconsistent, which is why validation runs at the transaction boundary
   rather than per intent.
3. **Atomicity covers the document and the id-mint counter**, so a rollback
   restores both.
4. **`seekTo(t)` is a pure function of the document.** Cascade walkers may not
   stash state on the engine that would change a later replay. Scratch state,
   such as paste's remap table, rides in the intent payload.
5. **Subscribers observe committed state**, never a half-applied transaction.
6. **Every reference is discoverable from the schema**, and the compiler
   enforces it rather than a test.

## Three classes of reference

**Event to entity.** Event payload fields naming an entity id: `peer-joined`'s
`peerId`, `session-opened`'s `sessionId`, `a`, and `b`, `message-sent`'s
`messageId`, `sessionId`, `from`, and `to`, and so on.

**Entity to entity.** A session's `a` and `b` name peers; a message's
`sessionId` names a session and its `from` and `to` name peers.

**Document index to entity.** Arrays of ids living elsewhere in the document:
`rowOrder`, `rowHidden`, `rowLabelHidden`, and `rowBodyHidden`, each per
category. Future indexes such as bookmarks or named groups join this class, and
the walker must purge or rewrite them like any other reference.

## Branded ids

```ts
type PeerId = string & { readonly __brand: "PeerId" };
type SessionId = string & { readonly __brand: "SessionId" };
type MessageId = string & { readonly __brand: "MessageId" };
```

Brands and the edge map solve different halves of the same problem. The edge map
makes references discoverable; without brands every walker call site is
stringly-typed and a `SessionId` passed where a `PeerId` belongs compiles fine.
Brands make the types nominal; without the edge map nothing can tell you which
fields hold one. The cost is roughly thirty casts at the boundary where strings
enter, at JSON parse, DOM keys, and sprite keys. Internal code is branded
throughout.

## Edge maps

The graph is encoded as TypeScript mapped types, so coverage is a compile error
rather than a test failure.

```ts
type EventEdges = {
  [K in TimelineEvent["kind"]]: ReadonlyArray<EdgeSpec<K>>;
};

type EdgeSpec<K extends TimelineEvent["kind"]> = {
  field: RequiredKeys<Extract<TimelineEvent, { kind: K }>>;
  target: EntityKind;
};
```

Mapping over `TimelineEvent["kind"]` forces every event kind to have an entry,
so adding a kind without declaring its references does not compile. Constraining
`field` to `RequiredKeys` forces the field to exist on that variant, so a typo
does not compile either. Excluding optional fields is deliberate: with invariant
2 in force, every reference is required, so every cascade policy must produce a
real value and none can leave a dangling reference behind.

Entity edges follow the same shape. Document-index edges are a plain registry
instead, because a new index is added by editing the document's top-level shape
and TypeScript cannot force a static registry to track that. The backstop is the
straggler check below.

## Cascade behaviors

This vocabulary names the design space so that a new operation can be described
as "which of these does it need?" It is not a union the walker dispatches on.
The functions in `cascade.ts` and `paste.ts` implement these directly, each with
the control flow that fits.

| Behavior       | Used by                            | What it does at the edge                                 |
| -------------- | ---------------------------------- | -------------------------------------------------------- |
| drop-dependent | `cascadeDelete`                    | Remove the dependent, and recurse into its own edges.    |
| rewrite        | `cascadeRewrite`                   | Replace the field with a constant new value.             |
| remap          | `cascadePaste`, `engine.duplicate` | Replace via a lookup table; absent entries pass through. |
| clone-target   | `engine.duplicate`, through paste  | Deep-copy the dependent with fresh ids, and recurse.     |
| block          | not yet used                       | Refuse the operation and return a validation error.      |
| merge          | not yet used                       | Merge fields into an existing target, or insert.         |

There is no `nullify`, because invariant 2 forbids dangling references and no
current reference is optional. If an optional reference is ever added, `nullify`
joins the list then.

`block` and `merge` are named but unbuilt. The dangling-reference rejection in
`cascadePaste` today is a per-call validation gate rather than an edge policy,
and importing another document is paste with an outside payload, which remaps
rather than merges. A real merge with field-level conflict resolution waits for
a use case.

## Discovery, then per-operation walks

An earlier plan had one `cascade(ctx, target, policies)` dispatcher. Building it
showed the operations have genuinely different control flow. `cascadeDelete` is
a worklist: removing a peer queues its sessions, which queue their messages.
`cascadeRewrite` is a single pass. Paste walks an incoming payload rather than
the document. One dispatcher over all of them hides more than it shares.

What they do share is discovery. Given a target, find every site that references
it. Three pure functions over the edge maps, in `walk.ts`:

```ts
findEventRefs(events, targetKind, targetId): EventRefSite[]
findEntityRefs(doc, targetKind, targetId): EntityRefSite[]
findDocIndexRefs(doc, targetKind, targetId): DocIndexRefSite[]
```

No mutation, no engine dependency. Every cascade operation consumes them and
owns its own algorithm on top.

`cascadeDelete` carries a visited set. Cycles cannot form in the current schema,
but the guard is cheap. `cascadeRewrite` ends with a straggler check: it re-runs
the three discovery functions against its own result and throws if any reference
to the old id survives. That check is the net for a missing entry in the edge
maps.

## Transactions

`beginTransaction(label)` and `endTransaction()` bracket a burst of intents.
They nest by depth and the outermost label wins. Everything between them
coalesces into one history entry, and a transaction that changed nothing pushes
no entry at all. A bare `engine.dispatch` is the same thing with an implicit
bracket.

A closure form, `engine.transaction(fn)`, is about six lines and has not been
written, because paste is single-step and nothing else composes multiple intents
yet.

Validation before a mutation goes through `engine.validate(intent)`, which
answers whether an intent is safe to dispatch without touching engine state. It
covers rename collisions and an `add-peer` carrying a user-supplied id today, so
the Inspector field and the tool options bar can show the error inline before
the gesture commits. Paste and duplicate validation are not written.

The straggler check at the end of `cascadeRewrite` is what catches a missing
edge declaration at runtime. A post-commit schema check over the whole document,
which would also catch an unregistered document-index field, is the natural
second net and has not been built. Running one on every dispatch is too
expensive for hot intents like `reposition-peer`, so it is worth revisiting when
importing outside documents lands and foreign content becomes the realistic
threat.
