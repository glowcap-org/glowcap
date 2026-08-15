/**
 * A peer's trajectory — the properties of a peer that change while
 * it is alive, and everything the app needs to know about each one.
 *
 * A peer arrives with values (the name it joined under) and can
 * restate them later: the rooms server names a member once it knows
 * the nick. Each restatement is a moment on the peer's timeline row,
 * exactly as a session's state change is a moment on its own.
 *
 * The table below is the ONE place a property is named. The
 * projection derives its track from it, the timeline paints its
 * diamonds and bands its pills from it, the Inspector renders its
 * rows from it, and the authoring ops write through it. Adding a
 * property costs three declarations and nothing else: a row here,
 * an optional field on `PeerUpdatedObs` (`temporal/recording.ts`),
 * and a track on `PeerDefinition.keyframes` (`timeline.ts`). The
 * second property, `profile`, landed exactly that way: no consumer
 * learned a new name. A property that wants its own mark on the
 * stage pays for that separately, as `profile` pays for its color.
 *
 * A row whose editor is marked `closed` accepts the values it lists
 * and no others: `write` refuses anything else rather than storing
 * it, because a stored undeclared value would not fail here — it
 * would fail later, as a document whose keyframe track will not
 * parse. An open picker, and a free-text row, take any string.
 *
 * What this deliberately does NOT do is make the stored shape
 * generic. A `{ type, value }` row on the wire would cost every
 * reader a runtime narrowing and would put the meaning of `value` in
 * prose instead of in the type. The observation keeps typed optional
 * fields (`label?`, `profile?`), the definition keeps typed tracks
 * (`keyframes.label`, `keyframes.profile`), and this table is the
 * seam that lets generic code drive them.
 *
 * Sessions have the same shape one level over, in a second table at
 * the foot of this file: a genesis value, a keyframe track, an
 * observation that states a change, and a numbered Inspector row.
 * Three properties live there — the lifecycle the session moves
 * through, and which peer is on each of its two ends. The two tables
 * stay separate because a peer restates several properties in ONE
 * observation while a session's moment is one observation stating one
 * thing; that difference is the whole of their storage halves.
 */

import type { PeerDefinition, SessionDefinition, TimelineDocument, TimelineEvent } from "./timeline.ts";
import { observationsOf } from "./temporal/recording-access.ts";
import type { KeyframeTrack } from "./temporal/keyframes.ts";
import {
  type EndpointAttachment,
  endpointAttachment,
  EndpointAttribution,
  PROFILE_OPTIONS,
  type SessionSide,
  SessionState,
  UNNAMED_PROFILE,
} from "../schema/topology.ts";

/** The lanes whose entities can carry single-moment observations,
 *  named as `doc.entities` names its categories. */
export type MomentLane = "peers" | "sessions";

/** One `peer-updated` observation — the wire form of a moment on a
 *  peer's trajectory. */
export type PeerUpdate = Extract<TimelineEvent, { kind: "peer-updated" }>;

/** The peer properties that change over time. Each is a field on
 *  `peer-updated` and a track on `PeerDefinition.keyframes`. */
export type PeerProperty = "label" | "profile";

/** How a trajectory row edits its value: a name is typed, a profile
 *  or a session state picks from the options named here, and a session's
 *  end picks the pair it attaches by.
 *
 *  `closed` is about the WRITE, not the control. When it is true the
 *  options are the whole domain and `write` refuses anything else, because a
 *  stored undeclared value would not fail here — it would fail later, as a
 *  document whose keyframe track will not parse. When it is false the
 *  options are the well-known values and any other string is legal: an OCapN
 *  peer can run an implementation this build has never heard of, and calling
 *  that invalid would be the viewer overreaching.
 *
 *  Both render through one picker. `offeredWith` adds whatever value the row
 *  is holding to whatever the list offers, so a closed domain is unaffected
 *  (its value is always already there) and an open one goes on showing an
 *  implementation nobody named. Reading `closed` to choose a CONTROL is what
 *  put a bare text field beside every other picker's select. */
export type TrajectoryEditor =
  | { readonly kind: "text" }
  | {
    readonly kind: "enum";
    readonly options: readonly string[];
    readonly closed: boolean;
  }
  | {
    /** Attach an end: pick the peer it attaches to, and what backed that.
     *
     *  Two controls for one value, because an end's value IS the pair
     *  (`EndpointAttachment`). Who is there and what put them there arrive
     *  together, so a row that edited only the peer could not state the
     *  second half at all: a recording carrying a moment a signed handoff
     *  attributed was a document Build could not author, and touching that
     *  row rewrote it as an attachment nothing backed.
     *
     *  `peers` is empty in the table because the offer is the document's own
     *  peers, which a static table cannot know and which change as an author
     *  adds and removes them; `sessionRowDisplay` fills it as a row paints.
     *  `attributions` is the whole domain and rides here the way `enum`
     *  carries its options, so the control reads both lists from one place. */
    readonly kind: "attachment";
    readonly peers: readonly string[];
    readonly attributions: readonly EndpointAttribution[];
  };

/** What a trajectory row needs to SHOW a property: what to call it
 *  and how to edit its value. Both lanes have this much, and each
 *  adds the storage half its own moments are kept in. The shared row
 *  and insert controls take this and nothing more, so they serve
 *  both lanes without knowing either. */
export type TrajectoryDisplay = {
  /** The lane whose entities carry this property. */
  readonly lane: MomentLane;
  /** What a row calls the thing that changed. Speech, not a field
   *  name: "name", not "label". */
  readonly noun: string;
  readonly editor: TrajectoryEditor;
};

export type TrajectoryProperty = TrajectoryDisplay & {
  /** The value this observation states, or null when it states
   *  nothing about this property. */
  readonly read: (ev: PeerUpdate) => string | null;
  /** A copy of `ev` stating `value`. */
  readonly write: (ev: PeerUpdate, value: string) => PeerUpdate;
  /** A copy of `ev` stating nothing about this property. */
  readonly clear: (ev: PeerUpdate) => PeerUpdate;
  /** The derived keyframe track on a peer's definition. */
  readonly track: (def: PeerDefinition) => KeyframeTrack<string> | undefined;
  /** A `keyframes` object carrying `track` for this property;
   *  `undefined` drops it. Returns undefined when nothing is left. */
  readonly withTrack: (
    def: PeerDefinition,
    track: KeyframeTrack<string> | undefined,
  ) => PeerDefinition["keyframes"];
  /** The value the peer arrives with, before any moment — a
   *  session's `initialState` in peer form. */
  readonly genesis: (def: PeerDefinition) => string | undefined;
  /** What the property carries when neither a keyframe nor the
   *  peer's arrival states one.
   *
   *  Every peer property is total: a peer has a name and a profile
   *  at every moment it exists, even when the document says nothing
   *  about them. Declaring that here rather than at
   *  each reader is what lets a caller ask for a property it does
   *  not know the name of and still get a real value back — which is
   *  the whole job of `peerPropertyAt`, and the reason the insert
   *  control can offer a starting value a closed enum will accept.
   *  A property whose fallback needs the peer itself (a name falls
   *  back to the id) gets it. */
  readonly fallback: (peerId: string) => string;
};

export const PEER_TRAJECTORY: Readonly<
  Record<PeerProperty, TrajectoryProperty>
> = {
  label: {
    lane: "peers",
    noun: "name",
    editor: { kind: "text" },
    read: (ev) => ev.label ?? null,
    write: (ev, value) => ({ ...ev, label: value }),
    clear: ({ label: _dropped, ...rest }) => rest,
    track: (def) => def.keyframes?.label,
    withTrack: (def, track) => {
      const next = { ...def.keyframes };
      if (track === undefined) delete next.label;
      else next.label = [...track];
      return Object.keys(next).length === 0 ? undefined : next;
    },
    genesis: (def) => def.label,
    // A peer with no stated name answers to its id, so every
    // surface has something to show.
    fallback: (peerId) => peerId,
  },
  profile: {
    lane: "peers",
    noun: "profile",
    // The flavor a peer is known by is as temporal as its name: a peer
    // drawn before anyone could say what it runs changes at the moment
    // somebody can, rather than rewriting its whole life. A live feed
    // reaches that verdict too — `StageLedger.#learnProfile` states one
    // when a producer speaks for an end it had been holding a place on.
    // The offer is `PROFILE_OPTIONS`, the same list the Details picker
    // reads, because "what a profile picker offers" is one fact and a
    // peer's profile is one property whether it is stated at birth or at a
    // moment. One property, one control: this row used to render a text
    // field with a suggestion list beside every other picker's select,
    // which read as a foreign control, filtered its own suggestions down to
    // whatever was already typed, and only committed on blur.
    editor: { kind: "enum", options: PROFILE_OPTIONS, closed: false },
    read: (ev) => ev.profile ?? null,
    write: (ev, value) => ({ ...ev, profile: value }),
    clear: ({ profile: _dropped, ...rest }) => rest,
    track: (def) => def.keyframes?.profile,
    withTrack: (def, track) => {
      const next = { ...def.keyframes };
      if (track === undefined) delete next.profile;
      else next.profile = [...track];
      return Object.keys(next).length === 0 ? undefined : next;
    },
    genesis: (def) => def.profile,
    // An implementation nobody has named is not a missing profile,
    // it is the one `UNNAMED_PROFILE` names.
    fallback: () => UNNAMED_PROFILE,
  },
};

/** Every peer property, in the order rows and glyphs list them. */
export const PEER_PROPERTIES: readonly PeerProperty[] = [
  "label",
  "profile",
];

/** A session's temporal properties: the lifecycle it moves through,
 *  and which peer is on each of its two ends. The side names are the
 *  ones the observations use, so a property IS a side wherever one is
 *  meant. */
export type SessionProperty = "state" | SessionSide;

/** What a session property's track carries at a moment.
 *
 *  The lifecycle is one word. An end is a PAIR — the peer and what backed
 *  the end attaching to it — because attribution and identity arrive
 *  together and a value that named only the peer would drop half of what
 *  happened (`EndpointAttachment` in `schema/topology.ts` argues it).
 *
 *  Both spellings live in one union rather than making this table generic,
 *  because the generic readers here take a property they cannot name and a
 *  union of specs cannot be called. What keeps a string out of an endpoint
 *  track is that nothing generic writes one: an endpoint has no `withTrack`,
 *  so its track is only ever built by the projection, which is typed, and
 *  the one door from a row's string is `parse` below. */
export type SessionValue = string | EndpointAttachment;

/** What a session property needs beyond its description: how a moment
 *  of it is stored, and how a reader resolves one.
 *
 *  A session's moment is one observation stating one property — a
 *  state change, or an end being attributed to a peer — so it is
 *  minted and removed whole. That is why this half mints an
 *  observation where the peer table's edits fields on one: a peer
 *  restates several properties at a single instant and each has to be
 *  cleared out of the shared observation separately.
 *
 *  Two channels, and the split is what lets a row edit a pair. The VALUE
 *  channel (`read`, `observation`, `track`, `genesis`) speaks whatever the
 *  property's track carries. The STATED channel (`stated`, `parse`) is the
 *  one string a row shows and a picker produces, so the Inspector drives
 *  every property through one control without learning what any of them
 *  carries.
 *
 *  `authoring/session.ts` drives every member: one op inserts a
 *  moment and one removes it, for any property, and neither learns a
 *  property's name. */
export type SessionTrajectoryProperty = TrajectoryDisplay & {
  /** What this observation states about `sessionId`'s property, or
   *  null when it states something else — another session, another
   *  end, or another property entirely. */
  readonly read: (ev: TimelineEvent, sessionId: string) => SessionValue | null;
  /** The observation stating `value` at `t`. Refuses a value the
   *  property cannot carry rather than storing it, as the peer
   *  table's `write` does. */
  readonly observation: (
    id: string,
    sessionId: string,
    t: number,
    value: SessionValue,
  ) => TimelineEvent;
  /** The keyframe track those moments become. */
  readonly track: (
    def: SessionDefinition,
  ) => KeyframeTrack<SessionValue> | undefined;
  /** A `keyframes` object carrying `track`, for the property whose
   *  authored track is durable on the definition.
   *
   *  Absent means the projection re-derives this property's track
   *  from the observation stream on every run
   *  (`project-from-observations.ts`), so the observation IS the
   *  write and a track stored beside it would be a second copy of a
   *  derived fact. */
  readonly withTrack?: (
    def: SessionDefinition,
    track: KeyframeTrack<SessionValue>,
  ) => SessionDefinition["keyframes"];
  /** The value the session is born with, before any moment. */
  readonly genesis: (def: SessionDefinition) => SessionValue | undefined;
  /** The one string that NAMES this value — what a lane paints, what a
   *  reference check reads, and what a caller asking "which peer" wants.
   *  For an end that is the peer it names; what backed the attachment is
   *  the pair's other half and does not fit in one word. */
  readonly stated: (value: SessionValue) => string;
  /** Reads what a write carried into the value this property stores.
   *
   *  A write may carry the value itself, which is how a row states an end's
   *  pair, or the string that names it, which is how a picker offering one
   *  word (a lifecycle) states its choice. Both arrive here, so there is one
   *  door into the track and the caller does not narrow per property. */
  readonly parse: (stated: SessionValue) => SessionValue;
  /** Whether two of this property's values are the same value. The pair
   *  needs both halves compared, so a write that keeps the peer and drops
   *  the backing is the document change it is. */
  readonly same: (a: SessionValue, b: SessionValue) => boolean;
  /** The entity kind this property's value names, when it names one.
   *  An end's value is a peer id, so a write refuses one the document
   *  does not declare rather than leaving a reference pointing at
   *  nothing. A state names nothing and omits this. */
  readonly names?: MomentLane;
};

/** The attachment arm of `SessionValue`, for the endpoint rows' own
 *  members. A string can only reach one through `parse`, which builds it. */
function asAttachment(value: SessionValue): EndpointAttachment {
  return typeof value === "string" ? { peer: value } : value;
}

/** One end's row. Both ends are the same property twice, differing
 *  only in which side they read and write, so they are built rather
 *  than written out — the second spelling is where the two would
 *  drift apart. */
function endpointProperty(side: SessionSide): SessionTrajectoryProperty {
  return {
    lane: "sessions",
    noun: `end ${side}`,
    // Pick a peer, and what attributed it. A moment ATTACHES an end:
    // the observation behind this track names a peer, so there is no
    // "attaches to nobody here". An end comes loose by losing the
    // moment, or by being born that way — which is what the genesis
    // endpoint on the session definition says, and where "no peer" is
    // a choice. What backed the attachment is the other half of the
    // same value, and it may be nothing.
    editor: {
      kind: "attachment",
      peers: [],
      attributions: EndpointAttribution.options,
    },
    read: (ev, sessionId) =>
      ev.kind === "session-endpoint-attributed" && ev.sessionId === sessionId &&
        ev.side === side
        ? {
          peer: ev.peerId,
          ...(ev.attributedBy !== undefined &&
            { attributedBy: ev.attributedBy }),
        }
        : null,
    observation: (id, sessionId, t, value) => {
      const at = asAttachment(value);
      return {
        id,
        kind: "session-endpoint-attributed",
        t,
        sessionId,
        side,
        peerId: at.peer,
        ...(at.attributedBy !== undefined &&
          { attributedBy: at.attributedBy }),
      };
    },
    track: (def) => def.keyframes?.[side],
    // No `withTrack`: the endpoint tracks re-derive from the
    // observations on every projection run, because an attribution IS
    // a live arrival.
    genesis: (def) => endpointAttachment(def[side]),
    stated: (value) => asAttachment(value).peer,
    parse: (stated) => asAttachment(stated),
    same: (a, b) => {
      const x = asAttachment(a);
      const y = asAttachment(b);
      return x.peer === y.peer && x.attributedBy === y.attributedBy;
    },
    names: "peers",
  };
}

export const SESSION_TRAJECTORY: Readonly<
  Record<SessionProperty, SessionTrajectoryProperty>
> = {
  state: {
    lane: "sessions",
    noun: "state",
    // The schema is the one authority for which states exist; the
    // picker offers exactly those, and there is no other.
    editor: { kind: "enum", options: SessionState.options, closed: true },
    read: (ev, sessionId) => ev.kind === "session-state-changed" && ev.sessionId === sessionId ? ev.state : null,
    observation: (id, sessionId, t, value) => ({
      id,
      kind: "session-state-changed",
      t,
      sessionId,
      state: SessionState.parse(value),
    }),
    track: (def) => def.keyframes?.state,
    // The state track IS the authored value: the projection derives
    // it only for a session that carries none, and keeps it after
    // that, because no live producer emits `session-state-changed`.
    withTrack: (def, track) => ({
      ...def.keyframes,
      state: track.map((kf) => ({
        t: kf.t,
        value: SessionState.parse(kf.value),
      })),
    }),
    genesis: (def) => def.initialState,
    // A lifecycle is one word, so the two channels are the same channel.
    stated: (value) => String(value),
    parse: (stated) => SessionState.parse(stated),
    same: (a, b) => a === b,
  },
  a: endpointProperty("a"),
  b: endpointProperty("b"),
};

export const SESSION_PROPERTIES: readonly SessionProperty[] = [
  "state",
  "a",
  "b",
];

/** A session row's descriptor with the peer picker's options filled in
 *  from the document.
 *
 *  The table says an end attaches to a peer without saying which
 *  peers, because those are the document's own. A row resolves that
 *  as it paints, so the shared row control keeps taking a
 *  `TrajectoryDisplay` and learns nothing about peers. The offer is
 *  the whole of what a write accepts: a moment attaches an end to a
 *  peer that exists, and the authoring op refuses anything else. */
export function sessionRowDisplay(
  property: SessionProperty,
  peerIds: readonly string[],
): TrajectoryDisplay {
  const spec = SESSION_TRAJECTORY[property];
  if (spec.editor.kind !== "attachment") return spec;
  return { ...spec, editor: { ...spec.editor, peers: peerIds } };
}

/** One moment on a session's trajectory: a property, the time it took a
 *  value, and the value.
 *
 *  `eventId` is the moment's identity — the id of the observation that
 *  states it. That is what a row is keyed on, what a drag addresses, and
 *  what the focus halo lights, and it is the same identity a peer's
 *  trajectory row already carries (`peerTrajectoryRows` hands back the
 *  observation itself). It has to be something that survives the edit
 *  being made: keyed on `t`, the row unmounts under the drag that is
 *  changing it, which takes the pointer capture with it and ends the
 *  gesture after one step;
 *  `scripts/playwright-trajectory-scrub-probe.ts` measures that (30px of
 *  drag moved the time 37.5ms instead of 300). Keyed on the keyframe's
 *  index within its track — which is what this carried before — the row
 *  survives a drag but is stolen by any insert or removal earlier in the
 *  same track, because every later index shifts by one and React hands a
 *  mounted row's fiber to a different keyframe.
 *
 *  An observation id does neither. `upsertObservation` keeps the id of
 *  the moment it replaces, and a move rewrites `t` in place, so the id
 *  outlives every edit the Inspector can make to the moment. */
export type SessionMoment = {
  property: SessionProperty;
  eventId: string;
  t: number;
  /** What this moment states, in the property's own value channel: a
   *  lifecycle word, or the pair an end attached by (the peer, and what
   *  backed it). A row shows and edits this, and it is the whole value
   *  rather than the `stated` string because a row that could only show
   *  the name could only write the name — restating a peer would drop the
   *  word a signed handoff put there. A caller that wants the one name
   *  asks the property's `stated`. */
  value: SessionValue;
};

/** Every moment on a session's trajectory, in the order the Inspector
 *  and the timeline list them: by time, then by the property order
 *  declared above. A row is "this property took this value here",
 *  which is what the reader is looking at — the session sibling of
 *  `peerTrajectoryRows`.
 *
 *  A moment IS an observation. `setSessionKeyframe` mints one for every
 *  property, the endpoint tracks are the projection's product of them,
 *  and the state track is written beside its own — so reading the stream
 *  here is reading the one authority, and it is what gives each row a
 *  name that outlives the edits made to it. A track entry with no
 *  observation stating it is not a moment this list can address, and
 *  nothing in this app produces one. */
export function sessionTrajectoryRows(
  doc: TimelineDocument,
  sessionId: string,
): SessionMoment[] {
  const out: SessionMoment[] = [];
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    const moment = sessionMomentOf(ev);
    if (moment === null || moment.sessionId !== sessionId) continue;
    const spec = SESSION_TRAJECTORY[moment.property];
    const value = spec.read(ev, sessionId);
    if (value === null) continue;
    out.push({
      property: moment.property,
      eventId: ev.id,
      t: ev.t,
      value,
    });
  }
  // Stable, so moments at one instant keep the property order above.
  return out.sort((x, y) => x.t - y.t);
}

/** Every moment of ONE of a session's properties, in time order.
 *
 *  What bounds a moment's move is its own property's neighbours and
 *  nothing else: a state change may pass an endpoint attribution freely,
 *  because the two tracks are read separately and neither can shadow the
 *  other. Bounding a row by the whole list instead both over-constrained
 *  it — an unrelated end's moment held a state change in place — and
 *  under-constrained it, because the moment right beside it in its own
 *  track was not the neighbour the row was measuring against. */
export function sessionPropertyMoments(
  doc: TimelineDocument,
  sessionId: string,
  property: SessionProperty,
): SessionMoment[] {
  return sessionTrajectoryRows(doc, sessionId)
    .filter((m) => m.property === property);
}

/** Which of a session's properties an observation states, and for which
 *  session — null when it states none of them.
 *
 *  The table above already knows, property by property, which observation
 *  carries it; asking every property is how a caller finds out without
 *  learning any of their names. A second list of "these kinds are session
 *  moments" kept beside it would be the same fact twice, and adding a
 *  fourth property would then mean remembering both. */
export function sessionMomentOf(
  ev: TimelineEvent,
): { sessionId: string; property: SessionProperty } | null {
  const sessionId = "sessionId" in ev ? ev.sessionId : undefined;
  if (sessionId === undefined) return null;
  for (const property of SESSION_PROPERTIES) {
    if (SESSION_TRAJECTORY[property].read(ev, sessionId) !== null) {
      return { sessionId, property };
    }
  }
  return null;
}

/** What one observation states, property by property. Empty when it
 *  states nothing — that observation changes nothing about the peer
 *  and is not a moment. */
export function peerUpdateStates(
  ev: PeerUpdate,
): { property: PeerProperty; value: string }[] {
  const out: { property: PeerProperty; value: string }[] = [];
  for (const property of PEER_PROPERTIES) {
    const value = PEER_TRAJECTORY[property].read(ev);
    if (value !== null) out.push({ property, value });
  }
  return out;
}
