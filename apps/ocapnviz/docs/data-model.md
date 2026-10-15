---
type: static
description: The three layers of state in an ocapnviz document and who may edit each one.
sources:
  - resource: /apps/ocapnviz/src/engine/timeline.ts
  - resource: /apps/ocapnviz/src/engine/authoring/
  - resource: /apps/ocapnviz/src/engine/temporal/
  - resource: /apps/ocapnviz/src/schema/
---

# The glowcap document

A glowcap document holds three layers of state: identity, behavior, and
recording. The schema in `src/engine/timeline.ts` is the authority wherever this
page disagrees with it. [`temporal-model.md`](temporal-model.md) covers the time
span, part of behavior, in detail.

## Three layers

| Layer         | What it holds                                                            | Who edits it                  |
| ------------- | ------------------------------------------------------------------------ | ----------------------------- |
| **Identity**  | What an entity is: a peer's profile, a session's ends and codec.         | Authoring.                    |
| **Behavior**  | When an entity exists, and how its properties change while it does.      | Authoring.                    |
| **Recording** | What was observed, in order, with provenance. Appended, never rewritten. | Nothing. Live ingest appends. |

Behavior is the only layer the display reads. While a Live capture is running,
live ingest keeps behavior in sync with arriving observations. Authoring edits
behavior directly. Playback and an active live capture are therefore the same
code path. Replaying a recording is an explicit gesture that rewrites behavior
from the recording. Idle Live (connected, not recording) mounts a blank engine
and draws nothing until Record.

Two layers would not do. Identity plus behavior loses the observed record that
live mode and provenance need. Identity plus events forces the display to walk
events to work out geometry, and forces authoring to edit records whose role is
to say what was observed.

## Identity

Identity is the fixed shape of an entity:

- a peer's profile, label, designator, and position
- a session's two ends, transport, codec, and CapTP version
- a message's session, sender, receiver, and label

A property that changes with time does not belong here. A session's runtime
state is a keyframe track, not an identity field.

A session's ends are **endpoints**, not peer ids. An endpoint carries what the
end claims to be, what backed that claim, and the peer it is attached to as a
result. An end that nothing backed is attached to no peer at all.

## Behavior

Behavior answers two questions about time, and the same idiom answers both. The
span answers whether the entity exists at `t`. A keyframe track answers what one
of its properties is worth at `t`.

A **time span** is `(start, duration)`, each side independently explicit or
implicit. End is derived as `start + duration` and never stored. The document
field is `timing`. The stored, intrinsic, and effective layers, the inheritance
chain, and the primitives live in [`temporal-model.md`](temporal-model.md).

A **keyframe** track is a sparse sequence of `(t, value)` pairs, the After
Effects convention. Session state is the canonical one: negotiating until t=10,
then open until close. Lookup is half-open, so at `t = keyframe.t` the new value
is already in effect. Before the first keyframe the value is the entity's
`initialState`.

Keyframes are authored shape, not observations. If the same fact came off the
wire, the observation lives in the recording layer and the keyframe is what was
projected from it.

## Recording

`doc.recording` is the append-only record of what was observed. It is organized
into named sources, each a chronological stream from one emitter with its own
metadata: kind, version, capture timestamp, and time origin.

```
doc.recording = { sources: RecordingSource[] }

RecordingSource = {
  id: string,                    // "live", "primary", …
  meta: { kind, version?, capturedAt?, timeOrigin?, notes? },
  observations: Observation[],   // chronological within this source
}

Observation = { t, kind, payload, provenance }
```

Emitter identity lives on the source. Provenance on an observation carries the
finer detail, such as which function or agent emitted it. Several sources let
two simulators be compared side by side, and let a proxy that merges feeds say
which one an observation came from.

Two sources naming the same entity id are treated as the same entity unless a
source namespaces its ids. If they disagree, behavior projects the most recently
observed value and the Inspector surfaces the conflict rather than resolving it.

### What an observation can say

Most observation kinds say what the network did: `peer-joined`, `peer-left`,
`session-opened`, `session-closed`, `session-state-changed`, `message-sent`,
`message-delivered`.

Other kinds say what the viewer learned, not what the network did.

**`session-endpoint-attributed`.** A peer that accepts a connection can report
the session before anything says who dialed it, because the name in a hello is a
claim until something backs it. The viewer does not invent a peer to hold that
claim. It records the claim on the session's own end, and that end stays
**loose**, attached to no peer, until something backs it. Attribution attaches
the end, and the session now runs to a peer already on stage. Nothing was born
and nothing died, so reporting it as `session-closed` or `peer-left` would claim
the network did something it never did.

**`peer-updated`.** It restates what a live peer is called while the peer goes
on living, so a chat nickname arriving after the join is this and not a new
identity. It also carries the durable designator a producer states for a peer it
will speak for later. That is identity arriving late, not a rename.

**`peer-unobserved` and `session-unobserved`.** A producer's telemetry socket
dropping, or the whole endpoint restarting, takes rows off the picture without
anyone observing anything about the network. A peer that turned tracing off
looks identical to one that departed, so `peer-left` would be a guess stated as
fact. `session-closed` would claim CapTP tore down a session that may still be
carrying traffic.

The three endings answer different questions: did it leave, was it someone else
all along, or did we just stop being able to look.

### Ids are lifetimes

Learning something about a peer never changes its stage id. Re-minting one
would claim that a row ended and another began.

A loose end's id comes from the session and the side, through
`endpointStageId`. It describes what the loose end is, not the designator it
claims, because a name a partner chose is not one this stage may adopt. Minting
an id from the claim once let a placeholder collide with the very peer it
claimed to be.

A loose end is not an entity. It has no row in the document, no lifetime of its
own, and no keyframes. It is born and dies with the session that owns it, and
what it claims and what attributed it live on that session's endpoint and
endpoint tracks. It is a selectable node with its own inspector panel
(`EndpointPanel`) that reads and writes the session's fields. The selection is a
node's, not an entity's.

### What recording is not

Recording holds no authored spans or keyframes and is not editable. An authored
value and an observed one can describe the same moment: the user knows the
session state changes at t=10, and the simulator observed it at t=10.034. When
they diverge the Inspector surfaces the divergence without resolving it.

A document authored from scratch has no recording. A captured session starts
with only a recording, and identity and behavior are projected from it. A flat
`events` array on input is projected into `recording.sources[0]` at parse, so a
runtime document carries observations only in the recording layer.

## Document shape

```ts
TimelineDocument = {
  id: string,
  metadata?: DescriptiveMetadata,
  provenance?: Provenance,
  duration: number,
  layoutMode?: LayoutMode,

  entities: {
    peers:    Record<PeerId,    PeerDefinition>
    sessions: Record<SessionId, SessionDefinition>
    messages: Record<MessageId, MessageDefinition>
  },

  recording?: { sources: RecordingSource[] },

  // Timeline view overlay, per category.
  rowOrder: { peers?: string[], sessions?: string[], messages?: string[] },
  rowHidden: { … }, rowLabelHidden: { … }, rowBodyHidden: { … },
}

PeerDefinition = {
  profile: PeerProfile, label?: string, designator?: string, position?: Position,
  timing: TimeSpan,
  keyframes?: { label?: Keyframe<string>[], profile?: Keyframe<PeerProfile>[] },
}

SessionDefinition = {
  a: SessionEndpoint, b: SessionEndpoint,
  // The netlayer the bytes ride. Absent means nothing stated one; the known
  // symbols are an offer (`TRANSPORT_OPTIONS`), not a domain.
  transport?: Transport,
  codec: Codec, captpVersion: CaptpVersion, initialState?: SessionState,
  timing: TimeSpan,
  // `a` and `b` above are the ends the session opened with. These are the peers
  // each end attached to, from each keyframe's t onward.
  keyframes?: {
    state?: Keyframe<SessionState>[],
    a?: Keyframe<PeerId>[], b?: Keyframe<PeerId>[],
  },
}

MessageDefinition = {
  sessionId: SessionId, from: PeerId, to: PeerId, label?: string,
  timing: TimeSpan,   // duration is the flight time, always explicit
}
```

One end of a session:

```ts
SessionEndpoint = {
  peer?: PeerId,
  designator?: string,
  attributedBy?: EndpointAttribution,
}
```

`designator` is what the end claims to be, either dialed or read out of the
partner's hello. `attributedBy` is what backed that claim, and `peer` is the
peer the end attached to as a result. The words `attributedBy` can take are the
`EndpointAttribution` enum in `src/schema/session-end.ts`, which is where each one
argues for itself.

An `attributedBy` implies a `peer`, because nothing can attribute an end to
nobody. The converse does not hold. In Build mode the author is the authority,
so `{ peer: "phone" }` with no `attributedBy` is the ordinary authored end. A
parsed document may write the bare string `"phone"` as shorthand for it.

An end with a `designator` and no `attributedBy` is loose. The claim exists,
nothing proved it, and no peer is attached. Read where an end sits at a moment
through `sessionEndpointPlaceAt`, which answers with the peer when there is one
and `endpointStageId(sessionId, side)` when there is not.

The type is branded and built through `sessionEndpoint(parts)`. Every field is
optional, so without the brand `endpoint === peerId` compiles and is never true.

## Where the code lives

- `src/engine/temporal/recording.ts` holds observations grouped by named source.
- `src/engine/temporal/keyframes.ts` holds the `Keyframe<T>` primitives,
  resolved through `doc-resolver.ts` (`sessionStateAt`, `peerLabelAt`).
- `src/engine/temporal/project-from-observations.ts` projects observations into
  identity and behavior.

`message-delivered` is an observation and nothing more. A message renders to the
end of its span, at `timing.start + timing.duration`, so the observation can
carry latency drift from the projected end without anything on screen depending
on it.

Save writes the whole document.
