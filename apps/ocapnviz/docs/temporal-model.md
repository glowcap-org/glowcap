# Time spans

An entity's placement in time is stored, inherited, and clamped as follows.
This is one part of layer 2 in `data-model.md`, which covers the document as a
whole.

The code is the specification. `src/engine/temporal/time-span.ts` holds the
storage shape and the gesture rewrites, `doc-resolver.ts` holds the table of
which reader reads which layer, and `authoring/moves.ts::moveEvent` pairs an
observation move with its entity patch. This file is kept for the reasoning the
type signatures do not carry.

## Three layers

Every temporal entity has three views of its placement at once.

| Layer         | What it is                                                         | Stored | Read by                                     |
| ------------- | ------------------------------------------------------------------ | ------ | ------------------------------------------- |
| **Stored**    | Per-axis start and duration, each with an explicit flag.           | yes    | Inspector fields, undo, JSON                |
| **Intrinsic** | Stored, with implicit axes resolved through inheritance.           | no     | the clamp indicator, timeline ghost outline |
| **Effective** | Intrinsic, clamped by context. What the system uses. May be empty. | no     | Stage, scrubber, hit-testing                |

The document stores only the first. The other two are pure functions of it plus
ancestor state, computed on read, so a constraint never writes back into the
document.

Two layers cannot tell "the user typed a value that got clamped" apart from "an
inherited bound got clamped." Three can. A message stored with a 2000 ms
duration inside a session that ends 1s after it starts has an intrinsic duration
of 2000 ms, which is the user's intent, and an effective duration of 1000 ms.
The Inspector can then say "stored 2000 ms, clamped to 1000 ms by session end,"
and name which ancestor did the work.

This is why the earlier model, which stored raw `start` and `end` and resolved a
single effective range, could not surface an override or let a value come back
when the constraint relaxed. There was only one coordinate, and the constraint
overwrote it.

## The span

```
TimeSpan
├── start:    Bound
└── duration: Bound

Bound
├── value:    number     // preserved even while implicit
└── explicit: boolean    // when false, this axis inherits
```

End is always derived as `start + duration`. It is never stored and never an
input to an authoring intent.

Start is a placement coordinate and duration is a property of the thing itself,
which is why they are stored rather than `(start, end)`. Rigid move falls out
for free: drag the middle of a bar and start changes while duration stays.
Setting start past end stops being a coordinate problem and becomes a gesture
question, answered at the intent layer. For a message the semantic property
really is flight time, and for peers and sessions the user thinks in end time,
which the Inspector round-trips through duration.

## Inheritance

An implicit axis asks its parent.

| Entity  | Implicit start                          | Implicit duration       |
| ------- | --------------------------------------- | ----------------------- |
| world   | 0, and not editable                     | infinite                |
| peer    | world start                             | the rest of the world   |
| session | max(A.start, B.start) when they overlap | the rest of the overlap |
| message | session start                           | never implicit          |

A message's duration is always explicit. Flight time is a property of the
network hop, not something to inherit, and the engine mints
`{ value: 500, explicit:
true }` when a message is created without one. Peers
and sessions can carry an explicit duration ("Alice lives exactly 30s regardless
of when she joins"), but usually do not.

An implicit axis inherits from its parent's **intrinsic** range, not its
effective one, so a message inside a session that peer overlap has clamped still
tracks the session's pre-clamp end and gets clamped at its own effective layer.
When the overlap relaxes, the message comes back on its own.

While an axis is implicit the stored `value` is the last number the user set.
The resolver ignores it and asks context, but it is preserved so that making the
axis explicit again does not jump.

## Constraints

Three rules produce the gap between intrinsic and effective.

1. **Context end clamps the end.** Effective duration shrinks so the entity ends
   where its context does. It may reach zero.
2. **Context start clamps the start.** Effective start moves forward and
   duration shrinks by the same amount, keeping the end fixed. Rare, but a typed
   value or a moved parent can trigger it.
3. **A session's context is its two ends' overlap.** An end's range covers every
   peer that has occupied it. If the two never overlap, the context is empty,
   the effective duration is zero, and the session goes ghost: selectable in the
   timeline lane, hidden on the stage. An end that nothing has attributed to a
   peer has no occupant, and no occupant is not a zero-length life. The session
   is running with one end unattributed, so that end constrains nothing and the
   attached end decides.

Constraints never mutate the document. When a parent moves, nothing fans out.
Every descendant's effective value recomputes on the next read. So document
mutations stay one entity at a time, undo records the user's authored change
rather than a cascaded clamp, and growing a parent back restores what it had
clamped with no redo. The schema cascade in `engine/schema/cascade.ts` still
walks the edge map for delete and rename, but temporal cascade is a read-time
recompute and needs no policy of its own.

## Intents

Authoring goes through a small set of span operations in `time-span.ts`:
`setStart`, `clearStart`, `setDuration`, `clearDuration`, `setEnd`, `clearEnd`,
and `moveBy`. Clearing an axis leaves its value in place and flips `explicit` to
false.

`setEnd` is the only one with hidden arithmetic. It converts an end time typed
into the Inspector into `duration = typedEnd - intrinsic.start` at dispatch, and
from there the document only sees start and duration. `moveBy` is the rigid-move
primitive drag gestures use: it changes start and leaves duration alone.

Two invariants remain. A duration is never negative, and authoring intents
enforce that rather than letting the document reach one. A zero duration is
allowed, and renders as a tick rather than a bar.

Which gesture does what is a gesture decision, not a data-model one. Dragging a
bar's middle calls `moveBy`, dragging its right edge calls `setDuration`, and
dragging its left edge calls both so that the right edge stays put.

## What the UI shows

The Stage renders effective ranges only, and hides an entity whose effective
duration has reached zero.

A timeline lane draws the effective range as a solid bar. Where intrinsic
reaches past effective, it draws a thin dashed ghost outline of intrinsic, so
the user can see what they typed. An entity whose effective range is empty draws
only that ghost, and stays selectable from the timeline even though the stage
hides it. Hit-testing follows: effective bounds on the stage, intrinsic bounds
in the timeline so ghosts stay clickable.

The Inspector shows peers and sessions as start and end, and messages as start
and flight. It reads stored values, and when a stored value differs from the
effective one it renders an indicator beside the field naming the reason, such
as "stored 10s, effective 8s, session ends at 8s." When they agree it stays
quiet. Clearing a field sets `explicit: false` and shows the inherited value as
a placeholder. Setting it explicit again snapshots the currently inherited value
so nothing jumps.
