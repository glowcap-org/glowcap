/**
 * Session authoring — the trajectory ops and the endpoint editor.
 *
 * A session has three temporal properties (`SESSION_TRAJECTORY`), and
 * one pair of ops writes any of them: `setSessionKeyframe` states a
 * property from a moment onward, `removeSessionKeyframe` takes the
 * moment back. What the session is BORN with is not a moment, so it
 * has its own two ops — `setSessionInitialState` for the state, and
 * `updateSessionEndpoint` for an end.
 *
 * The endpoint cases carry the claim Build mode exists to make: every
 * shape a recording can hold can be authored. A recording can express
 * an end nothing has attributed, an end that attaches partway through,
 * an end whose claim nothing backs, and every word that can back one —
 * so each of those has a test here that authors it and reads it back.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import type { TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import {
  sessionEndpointAt,
  sessionEndpointPlaceAt,
} from "../temporal/doc-resolver.ts";
import {
  attachedEndpoint,
  attachedTo,
  backedBy,
  endpointAttachment,
  EndpointAttribution,
  parseEndpointStageId,
  sessionEndpoint,
  TRANSPORT_OPTIONS,
} from "../../schema/topology.ts";
import { StageLedger } from "../stage-ledger.ts";
import { sessionTrajectoryRows } from "../trajectory.ts";

function engineTest(name: string, fn: () => void | Promise<void>): void {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn,
  });
}

function buildDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "test-traj",
    duration: 10000,
    events: [
      { id: "p1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      { id: "p2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
      {
        id: "so",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "a" },
        b: { peer: "b" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "negotiating",
      },
    ],
  });
}

/** A session with one end attached and one loose — the shape a live
 *  feed reports before anything has backed the far end's claim, and
 *  the shape these tests attach, detach, and edit. */
function looseDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "test-loose",
    duration: 10000,
    events: [
      { id: "p1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      { id: "p2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
      {
        id: "so",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "a", attributedBy: "self-reported" },
        b: { designator: "127.0.0.1:9000" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
    ],
  });
}

function sessionOf(e: Engine, id = "s1") {
  const def = e.doc.entities!.sessions![id];
  assert(def !== undefined, `session ${id} is declared`);
  return def;
}

function observations(e: Engine): readonly TimelineEvent[] {
  return observationsOf(e.doc) as readonly TimelineEvent[];
}

// ── the state property ────────────────────────────────────────────

engineTest("setSessionKeyframe inserts a state keyframe at t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "open" }]);
});

engineTest("setSessionKeyframe replaces the value at the same t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 1000, "draining");
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "draining" }]);
});

engineTest("setSessionKeyframe keeps the track sorted", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 3000, "draining");
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 2000, "open");
  assertEquals(
    sessionOf(e).keyframes?.state?.map((kf) => kf.t),
    [1000, 2000, 3000],
  );
});

engineTest("setSessionKeyframe rejects t before the effective start", () => {
  const e = new Engine(buildDoc());
  e.setSessionStart("s1", 500);
  e.setSessionKeyframe("s1", "state", 100, "open");
  const track = sessionOf(e).keyframes?.state;
  assert(!track || track.length === 0, "out-of-window keyframe was stored");
});

engineTest("removeSessionKeyframe removes the state keyframe at t", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.setSessionKeyframe("s1", "state", 2000, "draining");
  e.removeSessionKeyframe("s1", "state", 1000);
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 2000, value: "draining" }]);
});

engineTest("removeSessionKeyframe is a no-op when no t matches", () => {
  const e = new Engine(buildDoc());
  e.setSessionKeyframe("s1", "state", 1000, "open");
  e.removeSessionKeyframe("s1", "state", 1234);
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 1000, value: "open" }]);
});

engineTest("setSessionInitialState edits row 0 (entity.initialState)", () => {
  const e = new Engine(buildDoc());
  e.setSessionInitialState("s1", "open");
  assertEquals(sessionOf(e).initialState, "open");
});

engineTest(
  "dispatch routes set-session-keyframe through the intent path",
  () => {
    const e = new Engine(buildDoc());
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 1500,
      value: "open",
    });
    assertEquals(sessionOf(e).keyframes?.state, [{ t: 1500, value: "open" }]);
  },
);

engineTest(
  "dispatch no-op guard skips set-session-keyframe when unchanged",
  () => {
    const e = new Engine(buildDoc());
    e.setSessionKeyframe("s1", "state", 1000, "open");
    const v0 = e.version;
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 1000,
      value: "open",
    });
    // No-op guard short-circuits dispatch → no version bump.
    assertEquals(e.version, v0);
  },
);

// ── the endpoint properties ───────────────────────────────────────

engineTest("an end attaches to a peer from a moment onward", () => {
  const e = new Engine(looseDoc());
  e.setSessionKeyframe("s1", "b", 3000, "b");
  assertEquals(sessionOf(e).keyframes?.b, [{ t: 3000, value: { peer: "b" } }]);
  // The end is loose before the moment and attached from it on, which
  // is the whole point of an attribution being temporal.
  assertEquals(sessionEndpointPlaceAt(e.doc, "s1", "b", 2999).peer, undefined);
  assertEquals(sessionEndpointPlaceAt(e.doc, "s1", "b", 3000).peer, "b");
});

engineTest("every attribution a recording can hold can be authored", () => {
  // The claim Build mode makes, held mechanically rather than in prose.
  // A recording says what backed an end in two places — at the session's
  // birth and at the moment something backed it — and a live producer
  // reaches only some of the words: `verified-handoff` arrives partway
  // through a session that opened loose, and nothing else can say it.
  // So both places are authored here, for every word the schema admits,
  // and an attribution added to the schema joins this test by being in
  // the enum.
  for (const attribution of EndpointAttribution.options) {
    const born = new Engine(looseDoc());
    born.updateSessionEndpoint("s1", "b", {
      peer: "b",
      attributedBy: attribution,
    });
    assertEquals(
      sessionEndpointPlaceAt(born.doc, "s1", "b", 0).attributedBy,
      attribution,
      `${attribution}: an end could not be born attributed by it`,
    );

    const later = new Engine(looseDoc());
    later.setSessionKeyframe("s1", "b", 3000, {
      peer: "b",
      attributedBy: attribution,
    });
    // The observation is the authority the track is re-derived from, so
    // the word has to be on it and not only on the definition.
    const stated = observations(later).find(
      (ev) => ev.kind === "session-endpoint-attributed",
    );
    assertEquals(
      stated !== undefined && "attributedBy" in stated
        ? stated.attributedBy
        : undefined,
      attribution,
      `${attribution}: the moment did not say what backed the attachment`,
    );
    later.seekTo(5000);
    later.seekTo(0);
    assertEquals(
      sessionEndpointPlaceAt(later.doc, "s1", "b", 3000).attributedBy,
      attribution,
      `${attribution}: a moment attributed by it did not survive projection`,
    );
    // And it is this end's own fact from this moment on: before it, the
    // end is loose and nothing backed anything.
    assertEquals(
      sessionEndpointPlaceAt(later.doc, "s1", "b", 2999).attributedBy,
      undefined,
    );
  }
});

engineTest(
  "restating an end's peer keeps what the author said backed it",
  () => {
    // The row edits one control at a time, and the pair is one value, so a
    // peer change must not quietly unsay the attribution beside it. The
    // genesis end has behaved this way since it had an attribution at all
    // (`updateSessionEndpoint` patches field by field), and a moment is the
    // same end at a later time — two answers here would be the same
    // question answered twice.
    const e = new Engine(looseDoc());
    e.setSessionKeyframe("s1", "b", 3000, {
      peer: "b",
      attributedBy: "verified-handoff",
    });
    // What the row's peer control does with the value it is holding.
    const held = sessionEndpointAt(e.doc, "s1", "b", 3000);
    const attachment = endpointAttachment(held);
    assert(attachment !== undefined, "the moment left the end loose");
    e.setSessionKeyframe("s1", "b", 3000, attachedTo(attachment, "a"));
    assertEquals(sessionOf(e).keyframes?.b, [{
      t: 3000,
      value: { peer: "a", attributedBy: "verified-handoff" },
    }]);
    // And the attribution control's converse: clearing it keeps the peer
    // and leaves an attachment nothing backed, which the one-way
    // invariant allows and an author may mean.
    e.setSessionKeyframe(
      "s1",
      "b",
      3000,
      backedBy({ peer: "a", attributedBy: "verified-handoff" }, undefined),
    );
    assertEquals(sessionOf(e).keyframes?.b, [{
      t: 3000,
      value: { peer: "a" },
    }]);
  },
);

engineTest("an authored attachment survives the projection", () => {
  // The endpoint tracks are DERIVED from the observation stream on
  // every projection run, so an authored track written without its
  // observation would be erased the next time the engine re-projects.
  // The write mints the observation; this is what proves it.
  const e = new Engine(looseDoc());
  e.setSessionKeyframe("s1", "b", 3000, "b");
  const attribution = observations(e).find(
    (ev) => ev.kind === "session-endpoint-attributed",
  );
  assert(attribution !== undefined, "no attribution observation was minted");
  e.seekTo(5000);
  e.seekTo(0);
  assertEquals(sessionOf(e).keyframes?.b, [{ t: 3000, value: { peer: "b" } }]);
});

engineTest("removing the moment leaves the end loose again", () => {
  const e = new Engine(looseDoc());
  e.setSessionKeyframe("s1", "b", 3000, "b");
  e.removeSessionKeyframe("s1", "b", 3000);
  assertEquals(sessionOf(e).keyframes?.b, undefined);
  assertEquals(sessionEndpointPlaceAt(e.doc, "s1", "b", 5000).peer, undefined);
  assertEquals(
    observations(e).filter((ev) => ev.kind === "session-endpoint-attributed")
      .length,
    0,
    "the attribution observation outlived the moment",
  );
});

engineTest("an end cannot attach to a peer the document lacks", () => {
  const e = new Engine(looseDoc());
  e.setSessionKeyframe("s1", "b", 3000, "nobody");
  assertEquals(
    sessionOf(e).keyframes?.b,
    undefined,
    "a moment attached the end to a peer that is not there",
  );
});

engineTest("an attachment cannot land before the session opens", () => {
  const e = new Engine(looseDoc());
  e.setSessionStart("s1", 500);
  e.setSessionKeyframe("s1", "b", 100, "b");
  assertEquals(sessionOf(e).keyframes?.b, undefined);
});

engineTest("dragging a session carries its attributions with it", () => {
  // Every moment on a session's trajectory keeps its spacing from the
  // open. A state change already did; an attribution is a moment on
  // the same row and must too, or a dragged session drops its ends
  // back where they were.
  const e = new Engine(looseDoc());
  e.setSessionKeyframe("s1", "b", 3000, "b");
  e.dispatch({
    kind: "move-entity-span",
    move: { kind: "translate", ref: { kind: "session", id: "s1" }, newT: 1000 },
  });
  assertEquals(sessionOf(e).keyframes?.b, [{ t: 4000, value: { peer: "b" } }]);
});

// ── the endpoint a session is born with ───────────────────────────

engineTest("open-session can draw an end nothing has attributed", () => {
  const e = new Engine(buildDoc());
  const sid = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint("a"),
    b: sessionEndpoint({ designator: "127.0.0.1:9000" }),
  });
  assert(sid !== undefined, "the session was not drawn");
  const def = sessionOf(e, sid);
  assertEquals(def.a.peer, "a");
  assertEquals(def.b.peer, undefined, "the end came out attached");
  assertEquals(def.b.designator, "127.0.0.1:9000");
});

engineTest("detaching an end takes its attribution with it", () => {
  // Nothing can attribute an end to nobody, so the invariant is held
  // in both directions: a detach clears what attributed the end
  // rather than leaving a claim of proof behind with no peer.
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "a", { peer: null });
  const end = sessionOf(e).a;
  assertEquals(end.peer, undefined);
  assertEquals(end.attributedBy, undefined);
});

engineTest("attaching a loose end names the peer", () => {
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", { peer: "b" });
  assertEquals(sessionOf(e).b.peer, "b");
  // The claim is what the end SAID; attaching it does not rewrite
  // that, because the two are different facts.
  assertEquals(sessionOf(e).b.designator, "127.0.0.1:9000");
});

engineTest("an end cannot be attached to a peer the document lacks", () => {
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", { peer: "nobody" });
  assertEquals(sessionOf(e).b.peer, undefined);
});

engineTest("nothing can attribute an end to nobody", () => {
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", {
    attributedBy: "authenticated-transport",
  });
  assertEquals(
    sessionOf(e).b.attributedBy,
    undefined,
    "a loose end was given something that attributed it",
  );
});

engineTest("attributing an attached end records what backed it", () => {
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", { peer: "b" });
  e.updateSessionEndpoint("s1", "b", {
    attributedBy: "verified-handoff",
  });
  assertEquals(sessionOf(e).b.attributedBy, "verified-handoff");
});

engineTest("an end's claim is editable, and an empty claim is none", () => {
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", { designator: "10.0.0.2:7" });
  assertEquals(sessionOf(e).b.designator, "10.0.0.2:7");
  e.updateSessionEndpoint("s1", "b", { designator: "" });
  assertEquals(sessionOf(e).b.designator, undefined);
});

engineTest("an endpoint edit mirrors onto the opening observation", () => {
  // The definition is the authority, and the recording says what the
  // definition says — the same pairing a peer's identity edit keeps
  // with its join.
  const e = new Engine(looseDoc());
  e.updateSessionEndpoint("s1", "b", { peer: "b" });
  const opened = observations(e).find((ev) => ev.kind === "session-opened");
  assert(opened !== undefined && opened.kind === "session-opened");
  assertEquals(opened.b.peer, "b");
});

engineTest("dispatch routes update-session-endpoint, and guards it", () => {
  const e = new Engine(looseDoc());
  e.dispatch({
    kind: "update-session-endpoint",
    sessionId: "s1",
    side: "b",
    patch: { peer: "b" },
  });
  assertEquals(sessionOf(e).b.peer, "b");
  const v0 = e.version;
  e.dispatch({
    kind: "update-session-endpoint",
    sessionId: "s1",
    side: "b",
    patch: { peer: "b" },
  });
  assertEquals(e.version, v0, "an unchanged endpoint edit still dispatched");
  // Clearing a field that is already absent is equally a no-op.
  e.dispatch({
    kind: "update-session-endpoint",
    sessionId: "s1",
    side: "b",
    patch: { attributedBy: null },
  });
  assertEquals(e.version, v0);
});

// ── the node namespace peers and loose ends share ─────────────────

engineTest("a peer cannot be renamed onto a session end's node", () => {
  const e = new Engine(looseDoc());
  // `s1`'s loose end `b` is drawn as the node `s1::b`. A peer wearing
  // that name would be the same node — one place in the layout for
  // two things the picture holds apart.
  const refused = e.validate({
    kind: "rename-peer",
    oldId: "a",
    newId: "s1::b",
  });
  assert(!refused.ok, "the rename onto an end's node was allowed");
  assertEquals(refused.error.code, "collision");
  // Only that spelling. A name that merely contains the separator is
  // not an end's name, and refusing it would refuse a correct id.
  const allowed = e.validate({
    kind: "rename-peer",
    oldId: "a",
    newId: "s1::c",
  });
  assert(allowed.ok, "a name that is not an end's name was refused");
});

engineTest(
  "a live peer named like an end is disambiguated, not refused",
  () => {
    const ledger = new StageLedger();
    const out: TimelineEvent[] = [];
    // A producer picks the name a peer arrives under, so this one is
    // reachable from the wire and must not be refused. It is extended
    // instead, the way two peers presenting one name are.
    const live = ledger.ensurePeer("wire-1::a", 0, out);
    assert(
      parseEndpointStageId(live.stageId) === undefined,
      `a live peer took an end's node id: ${live.stageId}`,
    );
  },
);

// ── moving a moment along its own track ───────────────────────────

/** The two moments of `s1`'s state track, by the observation each is. */
function stateMoments(e: Engine) {
  return sessionTrajectoryRows(e.doc, "s1").filter((m) =>
    m.property === "state"
  );
}

engineTest("a moment dropped on its own neighbour is refused", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 2000,
    value: "draining",
  });
  const before = stateMoments(e);
  assertEquals(before.length, 2);
  const later = before[1]!;

  // The row's scrub clamps to its predecessor's time, and the floor is
  // reachable. Landing there once meant remove-then-set, and the set
  // REPLACES at its t — so the predecessor was overwritten and the
  // track came back one entry short.
  const errors: string[] = [];
  const off = e.onError((err) => errors.push(err.detail));
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: later.eventId, newT: 1000 },
  });
  off();

  const after = stateMoments(e);
  assertEquals(after.length, 2, "the track lost a moment to the drag");
  assertEquals(after.map((m) => m.t), [1000, 2000]);
  assertEquals(after.map((m) => m.value), ["open", "draining"]);
  assert(errors.length > 0, "the refusal was silent");
});

engineTest("a moment may land where ANOTHER property states one", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "b",
    t: 3000,
    value: "b",
  });
  // The two tracks are read separately and neither shadows the other,
  // so an end's moment is no constraint on the state's.
  const endMoment = sessionTrajectoryRows(e.doc, "s1").find((m) =>
    m.property === "b"
  )!;
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: endMoment.eventId, newT: 1000 },
  });
  const rows = sessionTrajectoryRows(e.doc, "s1");
  assertEquals(rows.length, 2);
  assertEquals(rows.map((m) => m.t), [1000, 1000]);
});

engineTest("a moment moved along its own track keeps its name", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "set-session-keyframe",
    sessionId: "s1",
    property: "state",
    t: 1000,
    value: "open",
  });
  const before = stateMoments(e)[0]!;
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: before.eventId, newT: 4000 },
  });
  const after = stateMoments(e)[0]!;
  assertEquals(after.eventId, before.eventId);
  assertEquals(after.t, 4000);
  // The definition's track went with it — the Inspector reads the
  // moments and the stage reads the track, and they must agree.
  assertEquals(sessionOf(e).keyframes?.state, [{ t: 4000, value: "open" }]);
});

engineTest("a session may have one peer on both of its ends", () => {
  const e = new Engine(buildDoc());
  // A host that dials itself reports exactly this, and
  // `updateSessionEndpoint` writes it after the fact — so the creation
  // door refusing it, in silence, was the one place the answer differed.
  const sessionId = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint("a"),
    b: attachedEndpoint("a"),
  });
  assert(
    typeof sessionId === "string",
    "open-session refused a peer on both ends",
  );
  const def = sessionOf(e, sessionId);
  assertEquals(def.a.peer, "a");
  assertEquals(def.b.peer, "a");
});

// ── the netlayer the session runs over ────────────────────────────

engineTest("a session can be given the netlayer it runs over", () => {
  // Build's claim is that every shape a recording can hold can be
  // authored, and a recording holds the netlayer each session's bytes
  // ride. A session nobody has said this about carries none, which is
  // the other shape and is equally reachable.
  const e = new Engine(buildDoc());
  assertEquals(sessionOf(e).transport, undefined);
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "iroh" },
  });
  assertEquals(sessionOf(e).transport, "iroh");
  // And it survives the document: what Build writes is what a saved
  // scenario carries and a reload reads back.
  const reloaded = TimelineDocument.parse(JSON.parse(JSON.stringify(e.doc)));
  assertEquals(reloaded.entities?.sessions?.s1?.transport, "iroh");
});

engineTest("changing the netlayer is one step, and re-picking is none", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "tcp" },
  });
  assertEquals(sessionOf(e).transport, "tcp", "the pick never landed");
  assert(e.canUndo, "the pick pushed no history entry");
  const v0 = e.version;
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "tcp" },
  });
  assertEquals(e.version, v0, "re-picking the same netlayer still dispatched");
  e.undo();
  assertEquals(
    sessionOf(e).transport,
    undefined,
    "one undo took the whole edit back",
  );
  assert(!e.canUndo, "the repeat dispatch pushed a second history entry");
});

engineTest("saying no netlayer is a write, and saying it twice is not", () => {
  const e = new Engine(buildDoc());
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "tcp" },
  });
  assertEquals(sessionOf(e).transport, "tcp", "the pick never landed");
  const v1 = e.version;
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: null },
  });
  assert(e.version !== v1, "clearing a stated netlayer changed nothing");
  assert(
    !("transport" in sessionOf(e)),
    "clearing left the field behind holding undefined",
  );
  const v0 = e.version;
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: null },
  });
  assertEquals(e.version, v0, "clearing an unstated netlayer still dispatched");
});

engineTest("a netlayer nobody offers is kept, shown, and editable", () => {
  // `TRANSPORT_OPTIONS` is an offer and not a domain: OCapN is
  // netlayer-plural and CapTP never names a transport, so a recording
  // may arrive over one this build has never heard of. The document
  // keeps it, the panel reads it back to hand to a picker that will
  // add it to what it offers, and an edit away from it is an ordinary
  // edit that undo reverses.
  const doc = TimelineDocument.parse({
    id: "unheard-of",
    duration: 10000,
    events: [
      { id: "p1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      { id: "p2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
      {
        id: "so",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "a" },
        b: { peer: "b" },
        transport: "carrier-pigeon",
        codec: "syrup",
        captpVersion: "v1_0",
      },
    ],
  });
  assert(
    !TRANSPORT_OPTIONS.includes("carrier-pigeon"),
    "the picker turned out to offer this one after all",
  );
  const e = new Engine(doc);
  assertEquals(sessionOf(e).transport, "carrier-pigeon");
  // Re-picking what it already runs over changes nothing, offered or not.
  const v0 = e.version;
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "carrier-pigeon" },
  });
  assertEquals(e.version, v0);
  e.dispatch({
    kind: "update-session",
    sessionId: "s1",
    patch: { transport: "tcp" },
  });
  assertEquals(sessionOf(e).transport, "tcp");
  e.undo();
  assertEquals(sessionOf(e).transport, "carrier-pigeon");
});
