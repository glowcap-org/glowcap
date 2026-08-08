/**
 * Recording layer — the append-only observed history of a
 * pancake document. See `docs/data-model.md` for the three-layer
 * architecture (identity / behavior / recording).
 *
 * A recording is organized into named **sources**. Each source is
 * a chronological stream of observations from a single emitter
 * (a network simulator, an enterprise simulator, a proxy, an
 * annotation tool).
 * Source-level metadata (kind, version, capture timestamp, time
 * origin) lives once per source, not duplicated on every
 * observation.
 *
 * This module owns that shape. `timeline.ts` names the same union
 * `TimelineEvent` for the authoring side, so an event and an
 * observation are one declaration, not two kept in step. The
 * parser accepts either a top-level `events: [...]` array (fixture-
 * friendly flat input) or a fully-populated `recording`; both
 * normalize to `recording.sources[*].observations` post-parse.
 * Readers go through `observationsOf(doc)` / `sourcesOf(doc)` and
 * never touch a top-level observation array.
 */

import { z } from "zod";
import { Provenance } from "../../schema/provenance.ts";
import {
  CaptpVersion,
  Codec,
  EndpointAttribution,
  PeerProfile,
  SessionEndpoint,
  SessionSide,
  SessionState,
  Transport,
} from "../../schema/topology.ts";

/** Common envelope on every observation. */
const observationBase = {
  /** Observation id, unique within its source. */
  id: z.string().min(1),
  /** Simulated time the emitter recorded for this observation,
   *  in simulated milliseconds since the source's `timeOrigin`
   *  (which defaults to 0). */
  t: z.number().nonnegative().finite(),
  /** Optional sub-source detail (function, agent id, etc). The
   *  emitter identity itself lives at the source level. */
  provenance: Provenance.optional(),
};

/** Render-space coords (same units as the canvas viewport, screen
 *  Y direction). Lives here beside the observation that carries it,
 *  and `timeline.ts` re-exports it for the authoring side. */
export const Position = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
});
export type Position = z.infer<typeof Position>;

const PeerJoinedObs = z.object({
  ...observationBase,
  kind: z.literal("peer-joined"),
  peerId: z.string().min(1),
  label: z.string().optional(),
  profile: PeerProfile,
  designator: z.string().optional(),
  /** Authored render-space position. Under `layoutMode: "authored"`
   *  it IS the peer's position; under the force modes it pins the
   *  peer there while neighbors settle around it. */
  position: Position.optional(),
});

const PeerLeftObs = z.object({
  ...observationBase,
  kind: z.literal("peer-left"),
  peerId: z.string().min(1),
});

/** The viewer stopped being able to see this peer. Its row ends
 *  here, and the protocol said nothing.
 *
 *  A telemetry producer going away is a fact about the FEED. The peer
 *  it was reporting may have departed, or may be running happily with
 *  nobody watching it — from here the two are indistinguishable, and
 *  `peer-left` would pick the first and state it as fact. This says
 *  only what is known: the picture ends here because the viewer lost
 *  sight, not because anything on the network moved. */
const PeerUnobservedObs = z.object({
  ...observationBase,
  kind: z.literal("peer-unobserved"),
  peerId: z.string().min(1),
});

const SessionOpenedObs = z.object({
  ...observationBase,
  kind: z.literal("session-opened"),
  sessionId: z.string().min(1),
  /** The session's two ends. Either may be loose — a claim nothing
   *  proved, attached to no peer — which is why these are endpoints and
   *  not the bare peer ids they used to be. An authored scenario writes a
   *  peer id and means `{ peer }`. */
  a: SessionEndpoint,
  b: SessionEndpoint,
  /** The OCapN Transport this session runs over. One session, one
   *  netlayer, so it sits here rather than on either end. */
  transport: Transport.optional(),
  codec: Codec,
  captpVersion: CaptpVersion,
  initialState: SessionState.optional(),
});

const SessionStateChangedObs = z.object({
  ...observationBase,
  kind: z.literal("session-state-changed"),
  sessionId: z.string().min(1),
  state: SessionState,
});

const SessionClosedObs = z.object({
  ...observationBase,
  kind: z.literal("session-closed"),
  sessionId: z.string().min(1),
});

/** The viewer stopped being able to see this session. Its row ends
 *  here, and the protocol said nothing.
 *
 *  The session-level sibling of `peer-unobserved`, and it exists for
 *  the same reason: a producer's telemetry socket dropping is a fact
 *  about the feed, and the conversation it was reporting may well
 *  still be running. `session-closed` would claim CapTP tore the
 *  session down, which is a claim about the wire that nothing here
 *  observed. */
const SessionUnobservedObs = z.object({
  ...observationBase,
  kind: z.literal("session-unobserved"),
  sessionId: z.string().min(1),
});

/** Something backed the claim on one end of a session already drawn,
 *  so that end attaches to a peer from this moment on.
 *
 *  A session's identity is the wire both its ends derive, and that is
 *  known from the first observation of it. Whether anything backed
 *  each end's claim is not: a peer accepting a connection can report
 *  the session before anything proves who dialed, because a cleartext
 *  netlayer binds nothing about the far side of the socket to the
 *  address in its hello. So an endpoint's attachment is a property
 *  that changes over the session's life, the way a peer's name is,
 *  and this observation is a keyframe on it
 *  (`SessionDefinition.keyframes.a` / `.b`).
 *
 *  Nothing on the wire moved. The session did not close and reopen;
 *  the claim on one of its ends stopped being only a claim. */
const SessionEndpointAttributedObs = z.object({
  ...observationBase,
  kind: z.literal("session-endpoint-attributed"),
  sessionId: z.string().min(1),
  /** Which end — the same two names `session-opened` gives them. */
  side: SessionSide,
  peerId: z.string().min(1),
  /** What backed the claim, when anything did.
   *
   *  The pair it states with `peerId` is what the keyframe track carries
   *  (`EndpointAttachment`), so an end attributed partway through says as
   *  much as one the session was born with — which is the whole reason this
   *  field exists.
   *
   *  Optional for the reason the genesis endpoint's own `attributedBy` is:
   *  the invariant runs one way. Something that attributed an end names the
   *  peer, and an end may be attached with nothing recorded about what put
   *  it there — a live producer that stated no verdict, and an author, both
   *  land there. Requiring a word here would make those two writes invent
   *  one. Loose is the absence of `peerId`'s attachment altogether, which is
   *  the absence of this observation. */
  attributedBy: EndpointAttribution.optional(),
});

/**
 * `message-sent` spawns a transient message-in-flight that travels
 * from sender to receiver along the named session. `arrivalT` lets
 * the renderer interpolate progress without knowing the future; the
 * paired `message-delivered` observation terminates the entity.
 */
const MessageSentObs = z.object({
  ...observationBase,
  kind: z.literal("message-sent"),
  messageId: z.string().min(1),
  sessionId: z.string().min(1),
  from: z.string().min(1),
  to: z.string().min(1),
  arrivalT: z.number().nonnegative().finite(),
  label: z.string().optional(),
  /** The message's wire frame (or its head, when the producer
   *  capped it), base64. The Inspector's payload viewer reads this.
   *  An observation carrying one names the file or capture the bytes
   *  came from in `provenance["prov:wasDerivedFrom"]`, and the viewer
   *  shows it. */
  bytesB64: z.string().optional(),
  /** The frame's true byte length. Equal to the decoded `bytesB64`
   *  length unless the producer truncated to its cap. */
  byteLen: z.number().nonnegative().optional(),
  /** The codec that produced `bytesB64`, when it is known to differ
   *  from the carrying session's. Every `op:start-session` is Syrup
   *  whatever codec the session goes on to speak (ADR-0103), so a
   *  Cap'n Proto session's handshake frames set this and the payload
   *  viewer spaces them as the bytes they are. Absent means the
   *  session's codec, which is the answer for every other
   *  message. */
  bytesCodec: Codec.optional(),
});

/** Identity metadata about a live peer, arriving after its join: a
 *  live feed's application annotation (a chat nick) lands here. The
 *  name a peer answers to is a temporal fact, so the projection
 *  writes each update as a keyframe at its own `t`
 *  (`PeerDefinition.keyframes.label`). The peer keeps the name it
 *  joined under until the update, and takes the new one from there
 *  on. A claim about naming, never identity. */
const PeerUpdatedObs = z.object({
  ...observationBase,
  kind: z.literal("peer-updated"),
  peerId: z.string().min(1),
  label: z.string().optional(),
  /** The implementation the peer is known by from here on.
   *
   *  An author states one directly. A live feed states one when it
   *  learns something it could not know at the join — a peer drawn as
   *  somebody else's partner, later reporting a session of its own —
   *  so a peer's implementation arrives the way its name does, at the
   *  moment somebody could say it. `StageLedger` holds what counts as
   *  knowing. */
  profile: PeerProfile.optional(),
  // No `designator` here, deliberately. A peer only ever reaches the stage
  // under a name somebody stated (`StageLedger.ensurePeer`), so its join
  // carries the durable name it answers to and nothing arrives later with a
  // first one. An author edits that name on the definition and the join
  // beside it (`authoring/peer.ts`). A second place to state it would be a
  // second authority for one fact.
});

const MessageDeliveredObs = z.object({
  ...observationBase,
  kind: z.literal("message-delivered"),
  messageId: z.string().min(1),
});

export const Observation = z.discriminatedUnion("kind", [
  PeerJoinedObs,
  PeerUpdatedObs,
  PeerUnobservedObs,
  PeerLeftObs,
  SessionOpenedObs,
  SessionStateChangedObs,
  SessionEndpointAttributedObs,
  SessionUnobservedObs,
  SessionClosedObs,
  MessageSentObs,
  MessageDeliveredObs,
]);
export type Observation = z.infer<typeof Observation>;
export type ObservationKind = Observation["kind"];

export const RecordingSourceMeta = z.object({
  /** Emitter family / kind — "pancake-host" (a live host tap), "griddle"
   * (the deterministic simulator), etc. */
  kind: z.string().min(1),
  version: z.string().optional(),
  /** ISO timestamp when capture started, if known. */
  capturedAt: z.string().optional(),
  /** Optional time-base offset. Observation `t` values within
   *  this source are relative to `timeOrigin`. Defaults to 0. */
  timeOrigin: z.number().finite().optional(),
  notes: z.string().optional(),
});
export type RecordingSourceMeta = z.infer<typeof RecordingSourceMeta>;

export const RecordingSource = z.object({
  /** Stable identifier for this source within the doc. */
  id: z.string().min(1),
  meta: RecordingSourceMeta,
  /** Chronological within this source. */
  observations: z.array(Observation),
});
export type RecordingSource = z.infer<typeof RecordingSource>;

export const Recording = z.object({
  sources: z.array(RecordingSource),
});
export type Recording = z.infer<typeof Recording>;
