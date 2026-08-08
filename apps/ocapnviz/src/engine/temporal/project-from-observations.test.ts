import { assertEquals } from "@std/assert";
import { attachedEndpoint, sessionEndpoint } from "../../schema/topology.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { projectFromObservations } from "./project-from-observations.ts";
import {
  peerLabelAt,
  sessionEffective,
  sessionEndpointPlaceAt,
} from "./doc-resolver.ts";

const emptyDoc = (): TimelineDocument => ({
  id: "test",
  duration: 100,
  rowOrder: {},
  rowHidden: {},
  rowLabelHidden: {},
  rowBodyHidden: {},
  entities: {},
});

/** Synthesize a recording source on `doc` carrying `events`.
 *  Observation streams live under `recording.sources` post-parse;
 *  these tests construct docs by hand so they wrap events here. */
function withEvents(
  doc: TimelineDocument,
  events: TimelineEvent[],
): TimelineDocument {
  return {
    ...doc,
    recording: {
      sources: [{
        id: "fixture",
        meta: { kind: "fixture" },
        observations: events,
      }],
    },
  };
}

Deno.test("migrate: doc without entities is untouched", () => {
  const doc: TimelineDocument = { ...emptyDoc(), entities: undefined };
  assertEquals(projectFromObservations(doc), doc);
});

Deno.test("migrate: peer with no events → both implicit", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      peers: {
        alice: { profile: "pancake" },
      },
    },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 0, explicit: false },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("migrate: peer with joined event → explicit start", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      peers: { alice: { profile: "pancake" } },
    },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("migrate: peer with joined + left → explicit start, explicit duration", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 25, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: message without flightMs → default 500ms duration", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      messages: {
        m1: { sessionId: "s1", from: "alice", to: "bob" },
      },
    },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 0, explicit: false },
    duration: { value: 500, explicit: true },
    derived: true,
  });
});

Deno.test("project: message-sent observation arrivalT-t → duration", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      messages: {
        m1: { sessionId: "s1", from: "alice", to: "bob" },
      },
    },
  }, [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 210,
  }]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 10, explicit: true },
    duration: { value: 200, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: message with sent event → explicit start", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      messages: { m1: { sessionId: "s1", from: "alice", to: "bob" } },
    },
  }, [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 11,
  }]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 10, explicit: true },
    // arrivalT − t = 1 ms flight; observation supersedes the default.
    duration: { value: 1, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: session with open + close → explicit start + duration", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "session-opened",
      t: 2,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
    { id: "e2", kind: "session-closed", t: 20, sessionId: "s1" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.sessions?.s1?.timing, {
    start: { value: 2, explicit: true },
    duration: { value: 18, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: existing timing is preserved (idempotent)", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      peers: {
        alice: {
          profile: "pancake",
          timing: {
            start: { value: 99, explicit: true },
            duration: { value: 11, explicit: true },
          },
        },
      },
    },
  };
  const out = projectFromObservations(doc);
  // identity-equal reference because nothing was touched
  assertEquals(out, doc);
});

Deno.test("migrate: re-running over a migrated doc is a no-op", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  };
  const once = projectFromObservations(doc);
  const twice = projectFromObservations(once);
  assertEquals(twice, once);
});

Deno.test("project: session-state-changed observations → keyframes.state track", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "session-state-changed",
      t: 10,
      sessionId: "s1",
      state: "open",
    },
    {
      id: "e2",
      kind: "session-state-changed",
      t: 15,
      sessionId: "s1",
      state: "draining",
    },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.sessions?.s1?.keyframes?.state, [
    { t: 10, value: "open" },
    { t: 15, value: "draining" },
  ]);
});

Deno.test("project: reads from recording.sources", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    recording: {
      sources: [{
        id: "live",
        meta: { kind: "pancake-host" },
        observations: [{
          id: "n1",
          kind: "peer-joined",
          t: 5,
          peerId: "alice",
          profile: "pancake",
        }],
      }],
    },
    entities: { peers: { alice: { profile: "pancake" } } },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("project: keyframes projection is idempotent", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [{
    id: "e1",
    kind: "session-state-changed",
    t: 10,
    sessionId: "s1",
    state: "open",
  }]);
  const once = projectFromObservations(doc);
  const twice = projectFromObservations(once);
  assertEquals(twice, once);
});

// ── Timing provenance: derived spans re-derive, authored spans win ──

Deno.test("live: a late-arriving peer-left re-derives the derived span", () => {
  // Live-mode shape: the join projects first (open-ended span), the
  // leave arrives on a LATER run. The derived span must pick it up —
  // this is the projection defect that made live peers immortal.
  const base = withEvents({
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
  ]);
  const once = projectFromObservations(base);
  assertEquals(once.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 0, explicit: false },
    derived: true,
  });
  // The live appender pushes into the same observations array.
  once.recording?.sources[0]?.observations.push(
    { id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
  );
  const twice = projectFromObservations(once);
  assertEquals(twice.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 25, explicit: true },
    derived: true,
  });
});

Deno.test("live: a late-arriving session-closed re-derives the derived span", () => {
  const base = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "session-opened",
      t: 2,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
  ]);
  const once = projectFromObservations(base);
  once.recording?.sources[0]?.observations.push(
    { id: "e2", kind: "session-closed", t: 20, sessionId: "s1" },
  );
  const twice = projectFromObservations(once);
  assertEquals(twice.entities?.sessions?.s1?.timing, {
    start: { value: 2, explicit: true },
    duration: { value: 18, explicit: true },
    derived: true,
  });
});

Deno.test("authored timing outranks observation growth", () => {
  // A user-authored span (no derived marker) is never touched, even
  // when a closure observation arrives for the same entity.
  const doc = withEvents({
    ...emptyDoc(),
    entities: {
      peers: {
        alice: {
          profile: "pancake",
          timing: {
            start: { value: 99, explicit: true },
            duration: { value: 11, explicit: true },
          },
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 99, explicit: true },
    duration: { value: 11, explicit: true },
  });
});

Deno.test("quiet re-projection keeps doc object identity", () => {
  // The engine keys layout rebinds on doc identity; a run over an
  // unchanged observation set must return the SAME object even
  // though derived spans are re-derived each run.
  const doc = withEvents({
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
  ]);
  const once = projectFromObservations(doc);
  const twice = projectFromObservations(once);
  if (twice !== once) {
    throw new Error("expected identical doc object on quiet re-projection");
  }
});

Deno.test("live sentinel: arrivalT === t takes the default flight", () => {
  // The live converter has no departure timestamp, so it stamps
  // arrivalT equal to t ("flight unobserved"). A zero flight is
  // invisible; the projection must substitute the default so the
  // message actually draws.
  const doc = withEvents({
    ...emptyDoc(),
    entities: {
      messages: { m1: { sessionId: "s1", from: "alice", to: "bob" } },
    },
  }, [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 10,
  }]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 10, explicit: true },
    duration: { value: 500, explicit: true },
    derived: true,
  });
});

Deno.test("a message observation's payload stays off the synthesized def", () => {
  // The def carries identity; the frame is the observation itself,
  // and copying it would double every payload's retention in a
  // live doc. The Inspector reads the observation.
  const doc = withEvents(emptyDoc(), [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 10,
    bytesB64: "U3lydXAh",
    byteLen: 6,
  }]);
  const out = projectFromObservations(doc);
  const def = out.entities?.messages?.m1 as Record<string, unknown>;
  assertEquals(def.bytesB64, undefined);
  assertEquals(def.byteLen, undefined);
});

/** A doc holding one peer that joined at t=5 under its locator. */
function joinedPeerDoc(): TimelineDocument {
  return withEvents({ ...emptyDoc(), entities: {} }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "127.0.0.1:0",
      profile: "pancake",
      label: "127.0.0.1:0",
    },
  ]);
}

Deno.test("live: a late-arriving peer-updated keyframes the new name", () => {
  // The annotation arrives after the join by construction (the app
  // learns the nick at registration), so the name is a temporal
  // fact: the peer answers to its locator until t=50 and to "carol"
  // from there on. Folding the last label into the def instead would
  // rewrite the whole timeline, and a replay would never show the
  // locator the live viewer saw.
  const once = projectFromObservations(joinedPeerDoc());
  assertEquals(once.entities?.peers?.["127.0.0.1:0"]?.label, "127.0.0.1:0");
  once.recording?.sources[0]?.observations.push({
    id: "e2",
    kind: "peer-updated",
    t: 50,
    peerId: "127.0.0.1:0",
    label: "carol",
  });
  const twice = projectFromObservations(once);
  const def = twice.entities?.peers?.["127.0.0.1:0"];
  assertEquals(def?.label, "127.0.0.1:0");
  assertEquals(def?.keyframes?.label, [{ t: 50, value: "carol" }]);
  assertEquals(peerLabelAt(twice, "127.0.0.1:0", 49), "127.0.0.1:0");
  assertEquals(peerLabelAt(twice, "127.0.0.1:0", 50), "carol");
});

Deno.test("live: every peer-updated lands, in time order", () => {
  const doc = joinedPeerDoc();
  doc.recording?.sources[0]?.observations.push(
    {
      id: "e2",
      kind: "peer-updated",
      t: 50,
      peerId: "127.0.0.1:0",
      label: "carol",
    },
    {
      id: "e3",
      kind: "peer-updated",
      t: 70,
      peerId: "127.0.0.1:0",
      label: "carol-away",
    },
  );
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label, [
    { t: 50, value: "carol" },
    { t: 70, value: "carol-away" },
  ]);
  assertEquals(peerLabelAt(out, "127.0.0.1:0", 60), "carol");
  assertEquals(peerLabelAt(out, "127.0.0.1:0", 80), "carol-away");
});

Deno.test("live: dropping the renaming observation drops its keyframe", () => {
  // The observation stream is the authority in both directions —
  // a track that outlived the observation behind it would keep
  // renaming the peer with nothing left to point at.
  const doc = joinedPeerDoc();
  const observations = doc.recording?.sources[0]?.observations;
  observations?.push({
    id: "e2",
    kind: "peer-updated",
    t: 50,
    peerId: "127.0.0.1:0",
    label: "carol",
  });
  const named = projectFromObservations(doc);
  assertEquals(peerLabelAt(named, "127.0.0.1:0", 60), "carol");

  observations?.pop();
  const unnamed = projectFromObservations(named);
  assertEquals(unnamed.entities?.peers?.["127.0.0.1:0"]?.keyframes, undefined);
  assertEquals(peerLabelAt(unnamed, "127.0.0.1:0", 60), "127.0.0.1:0");
});

Deno.test("live: re-projecting an unchanged label track keeps the doc", () => {
  // The projection runs every engine tick; a quiet run must return
  // the same doc object, because the engine rebinds layout on
  // identity change.
  const doc = joinedPeerDoc();
  doc.recording?.sources[0]?.observations.push({
    id: "e2",
    kind: "peer-updated",
    t: 50,
    peerId: "127.0.0.1:0",
    label: "carol",
  });
  const once = projectFromObservations(doc);
  assertEquals(projectFromObservations(once), once);
});

Deno.test("attributing an end attaches it, and keeps the session's span", () => {
  // The live shape this vocabulary exists for. A peer accepts a connection it
  // cannot attribute, so the session is drawn with that end attached to
  // nobody, carrying only what the far side claimed. When something finally
  // backs the claim, the end attaches to the peer it named. What must NOT
  // happen is the session ending — nothing on the wire closed.
  const doc = withEvents(emptyDoc(), [
    {
      id: "e1",
      t: 0,
      kind: "peer-joined",
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", t: 0, kind: "peer-joined", peerId: "bob", profile: "pancake" },
    {
      id: "e4",
      t: 10,
      kind: "session-opened",
      sessionId: "w1",
      a: attachedEndpoint("bob"),
      b: sessionEndpoint({ designator: "alice" }),
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "open",
    },
    {
      id: "e5",
      t: 20,
      kind: "session-endpoint-attributed",
      sessionId: "w1",
      side: "b",
      peerId: "alice",
      attributedBy: "verified-handoff",
    },
  ]);
  const out = projectFromObservations(doc);

  // The end is a track on the session, and the session opened with that end
  // attached to nobody.
  assertEquals(out.entities?.sessions?.w1?.b?.peer, undefined);
  assertEquals(out.entities?.sessions?.w1?.keyframes?.b, [{
    t: 20,
    value: { peer: "alice", attributedBy: "verified-handoff" },
  }]);
  assertEquals(sessionEndpointPlaceAt(out, "w1", "b", 15).peer, undefined);
  assertEquals(sessionEndpointPlaceAt(out, "w1", "b", 20).peer, "alice");
  assertEquals(sessionEndpointPlaceAt(out, "w1", "a", 20).peer, "bob");

  // No peer was born or died to carry the claim, which is the whole point:
  // the only thing that changed is which peer the session's end names.
  // Alice's row is open-ended — an implicit duration, the shape a peer
  // with no ending observation gets.
  assertEquals(out.entities?.peers?.["alice"]?.timing?.duration, {
    value: 0,
    explicit: false,
  });

  // And the session is still open past that moment.
  const eff = sessionEffective(out, "w1");
  assertEquals(eff.start, 10);
  assertEquals(eff.end, Infinity);
});

Deno.test("a peer that departs AND goes unobserved ends at the first of the two", () => {
  // Both dispositions on one row is not a shape the ledger produces, but the
  // projection reads whatever the recording holds, and a row has one end.
  const doc = withEvents(emptyDoc(), [
    {
      id: "e1",
      t: 0,
      kind: "peer-joined",
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", t: 30, kind: "peer-left", peerId: "alice" },
    { id: "e3", t: 20, kind: "peer-unobserved", peerId: "alice" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.["alice"]?.timing?.duration, {
    value: 20,
    explicit: true,
  });
});

Deno.test("a peer's identifier comes from the join that drew it", () => {
  // The join is the only observation that states one, because a peer only
  // ever reaches the stage under a name somebody stated
  // (`StageLedger.ensurePeer`). A peer drawn without one has none, and
  // nothing arrives later to supply a first: an author edits the durable
  // name on the definition and the join beside it (`authoring/peer.ts`), so
  // the fact keeps one home.
  const doc = withEvents(emptyDoc(), [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
      designator: "joined-as",
    },
    {
      id: "e2",
      kind: "peer-joined",
      t: 5,
      peerId: "nobody",
      profile: "pancake",
    },
  ] as TimelineEvent[]);
  const peers = projectFromObservations(doc).entities?.peers;
  assertEquals(peers?.alice?.designator, "joined-as");
  assertEquals(peers?.nobody?.designator, undefined);
});

Deno.test("a session's netlayer comes from the open that reported it", () => {
  // One session runs over one netlayer, and the opening observation is
  // where a producer says which. The definition is what every reader
  // and the Build picker consult, so the fact has to arrive there; a
  // session whose open reported no transport carries none, which is a
  // real recording and not a missing value.
  const doc = withEvents(emptyDoc(), [
    {
      id: "e1",
      kind: "session-opened",
      t: 2,
      sessionId: "over-iroh",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      transport: "iroh",
      codec: "capnp",
      captpVersion: "v1_0",
    },
    {
      id: "e2",
      kind: "session-opened",
      t: 2,
      sessionId: "unstated",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
  ] as TimelineEvent[]);
  const sessions = projectFromObservations(doc).entities?.sessions;
  assertEquals(sessions?.["over-iroh"]?.transport, "iroh");
  assertEquals(sessions?.["unstated"]?.transport, undefined);
});

Deno.test("an authored netlayer outranks the one the open reported", () => {
  // The cascade the codec and the CapTP version already take: a
  // declared entity entry wins, and the observation only fills a
  // session the document has not declared. Without it an author's
  // edit would be undone by the next projection run.
  const doc = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          transport: "webrtc",
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "session-opened",
      t: 2,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      transport: "tcp",
      codec: "capnp",
      captpVersion: "v1_0",
    },
  ] as TimelineEvent[]);
  assertEquals(
    projectFromObservations(doc).entities?.sessions?.s1?.transport,
    "webrtc",
  );
});
