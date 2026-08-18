import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { findEndpoint, findPeer } from "../world.ts";
import { attachedEndpoint, unattributedEndpoint } from "../../schema/session-end.ts";
import { observationsOf, primaryObservations } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc, emptyAuthoredDoc } from "./fixtures.ts";

const messageDoc = (openT: number) =>
  TimelineDocument.parse({
    id: "message-doc",
    duration: 60_000,
    events: [
      { id: "j1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      { id: "j2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
      {
        id: "s1o",
        t: openT,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "a" },
        b: { peer: "b" },
        codec: "syrup",
        captpVersion: "v1_0",
      },
      {
        id: "m1s",
        t: 1_000,
        kind: "message-sent",
        messageId: "m1",
        sessionId: "s1",
        from: "a",
        to: "b",
        arrivalT: 1_500,
      },
      { id: "m1d", t: 1_500, kind: "message-delivered", messageId: "m1" },
    ],
  });

engineTest("set-message-end lands the arrival at the painted time", () => {
  const e = new Engine(messageDoc(1_000));
  // Implicit start inherits the session's painted start; move the
  // session so the retained stored start (1000) and the painted
  // start (2000) diverge.
  e.dispatch({ kind: "clear-message-start", messageId: "m1" });
  e.dispatch({ kind: "set-session-start", sessionId: "s1", t: 2_000 });
  assertEquals(e.effectiveStart("messages", "m1"), 2_000);
  e.dispatch({ kind: "set-message-end", messageId: "m1", t: 2_600 });
  assertEquals(
    e.effectiveEnd("messages", "m1"),
    2_600,
    "the arrival must land at the requested painted time",
  );
});

engineTest(
  "resize-end drag reaches a message whose flight was edited in the Inspector",
  () => {
    const e = new Engine(messageDoc(0));
    // Inspector flight edit retimes the painted span only; the
    // message-sent observation keeps its recorded arrivalT.
    e.dispatch({
      kind: "set-message-duration",
      messageId: "m1",
      duration: 800,
    });
    assertEquals(e.effectiveEnd("messages", "m1"), 1_800);
    // Dragging the right edge back to the recorded arrival is a
    // real edit of the painted span — not a no-op.
    e.dispatch({
      kind: "move-event",
      move: { kind: "resize-end", eventId: "m1s", newArrivalT: 1_500 },
    });
    assertEquals(e.effectiveEnd("messages", "m1"), 1_500);
  },
);

engineTest(
  "translate lands the pill where the gesture dropped it after an Inspector start edit",
  () => {
    const e = new Engine(messageDoc(0));
    // Inspector start edit retimes the painted span only; the
    // message-sent observation stays at its recorded t=1000.
    e.dispatch({ kind: "set-message-start", messageId: "m1", t: 2_000 });
    assertEquals(e.effectiveStart("messages", "m1"), 2_000);
    e.dispatch({
      kind: "move-event",
      move: { kind: "translate", eventId: "m1s", newT: 2_200 },
    });
    assertEquals(
      e.effectiveStart("messages", "m1"),
      2_200,
      "the painted span anchors at the drop point, not at obs-anchored dt",
    );
    const sent = primaryObservations(e.doc).find((ev) => ev.id === "m1s")!;
    assertEquals(sent.t, 2_200, "the observation moved to agree");
  },
);

engineTest(
  "translate on peer-left reaches an end edited in the Inspector",
  () => {
    const e = new Engine(TimelineDocument.parse({
      id: "edited-end-peer",
      duration: 60_000,
      events: [
        {
          id: "j1",
          t: 0,
          kind: "peer-joined",
          peerId: "p",
          profile: "pancake",
        },
        { id: "l1", t: 1_000, kind: "peer-left", peerId: "p" },
      ],
    }));
    e.dispatch({ kind: "set-peer-duration", peerId: "p", duration: 2_000 });
    assertEquals(e.effectiveEnd("peers", "p"), 2_000);
    // Dragging the leave marker back to its recorded t pins the
    // painted end there — a real edit, not a no-op.
    e.dispatch({
      kind: "move-event",
      move: { kind: "translate", eventId: "l1", newT: 1_000 },
    });
    assertEquals(e.effectiveEnd("peers", "p"), 1_000);
  },
);

engineTest("undo restores a duration the edit extended", () => {
  const e = new Engine(emptyAuthoredDoc());
  const peerId = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  e.dispatch({ kind: "set-peer-end", peerId, t: 90_000 });
  assertEquals(e.doc.duration, 90_000, "the edit grew the doc");
  assertEquals(e.clock.duration, 90_000, "the clock bound followed");
  e.undo();
  assertEquals(e.doc.duration, 60_000, "undo restores the doc duration");
  assertEquals(e.clock.duration, 60_000, "and the clock bound follows");
  e.redo();
  assertEquals(e.doc.duration, 90_000, "redo re-extends");
  assertEquals(e.clock.duration, 90_000);
});

engineTest(
  "clearing a pin reaches the layout after projection replaced the doc",
  () => {
    // The parsed doc's entities carry no timing, so the engine's
    // construction-time projection returns a FRESH doc object. The
    // layout must follow the engine's doc, not the constructor
    // argument — otherwise every later entities edit (here: the
    // unpin) recomputes against the abandoned object.
    const e = new Engine(TimelineDocument.parse({
      id: "stale-layout-doc",
      duration: 1_000,
      entities: {
        peers: {
          alice: { profile: "pancake", position: { x: 500, y: 500 } },
        },
      },
      events: [
        {
          id: "j1",
          t: 0,
          kind: "peer-joined",
          peerId: "alice",
          profile: "pancake",
        },
      ],
    }));
    const pinned = e.layout.keyframes[0]?.layout.get("alice");
    assertEquals(pinned, { x: 500, y: 500 }, "the pin holds before the unpin");
    e.dispatch({ kind: "clear-peer-position", peerId: "alice" });
    const freed = e.layout.keyframes[0]?.layout.get("alice");
    assert(freed, "alice still has a layout entry");
    const d = Math.hypot(freed.x - 500, freed.y - 500);
    assert(
      d > 100,
      `an unpinned peer re-derives cold, away from the dead pin; got ${JSON.stringify(freed)}`,
    );
  },
);

engineTest(
  "restating a derived timing value is a real change (authored promotion)",
  () => {
    // The shared fixture doc's peers carry timing DERIVED from
    // their observations (peer-joined at t=0). Setting the start
    // to that same value changes the span's authority — the user
    // pins it, so observation growth stops moving it — which is
    // the pin-here rule applied to time. The no-op guard must not
    // swallow it.
    const e = new Engine(structuredClone(doc));
    assertEquals(
      e.doc.entities?.peers?.a?.timing?.derived,
      true,
      "fixture peer timing should be projection-derived",
    );
    assert(!e.canUndo);
    e.dispatch({ kind: "set-peer-start", peerId: "a", t: 0 });
    assert(e.canUndo, "promotion to authored must land in history");
    assertEquals(
      e.doc.entities?.peers?.a?.timing?.derived,
      undefined,
      "the authored span carries no derived marker",
    );
    // A second identical set IS a no-op — the span is authored now.
    e.dispatch({ kind: "set-peer-start", peerId: "a", t: 0 });
    e.undo();
    assert(!e.canUndo, "exactly one history entry from the two dispatches");
  },
);

engineTest(
  "live churn end to end: a session close retires the session and peer",
  () => {
    // The whole live pipeline below the websocket: converter events
    // appended after the entities were first projected still close
    // them — the projection re-derives derived spans, so the world
    // drops the session and the departed peer.
    const liveDoc: TimelineDocument = {
      id: "live",
      duration: 60_000,
      recording: {
        sources: [{
          id: "live",
          meta: { kind: "pancake-host" },
          observations: [],
        }],
      },
    };
    const e = new Engine(liveDoc);
    e.enqueue({ kind: "play" });
    e.tick(0);
    primaryObservations(liveDoc).push(
      {
        id: "l1",
        t: e.clock.t + 1,
        kind: "peer-joined",
        peerId: "rooms",
        profile: "pancake",
      },
      {
        id: "l2",
        t: e.clock.t + 1,
        kind: "peer-joined",
        peerId: "bob",
        profile: "pancake",
      },
      {
        id: "l3",
        t: e.clock.t + 1,
        kind: "session-opened",
        sessionId: "s1",
        a: attachedEndpoint("rooms"),
        b: attachedEndpoint("bob"),
        codec: "syrup",
        captpVersion: "v1_0",
      },
    );
    e.tick(20);
    assert(findPeer(e.world, "bob") !== undefined, "bob joined");
    // The close arrives LATER — after s1 and bob were projected.
    primaryObservations(liveDoc).push(
      { id: "l4", t: e.clock.t + 1, kind: "session-closed", sessionId: "s1" },
      { id: "l5", t: e.clock.t + 1, kind: "peer-left", peerId: "bob" },
    );
    e.tick(20);
    assert(
      findPeer(e.world, "bob") === undefined,
      "bob must leave the stage after peer-left",
    );
    const sessions = [...e.world.with("session")];
    assertEquals(sessions.length, 0, "s1 must close on stage");
  },
);

engineTest(
  "live churn end to end: a closing session takes its loose end with it",
  () => {
    // The reported bug: a Goblins vat joins a room and leaves, and the end
    // nobody could name stays on the stage, selectable, reporting a session
    // that has closed. One orphan per join-and-leave cycle. The same document
    // replayed from a fresh world drew no such node, which is what named the
    // defect: the world is reconciled to `t`, and the loose end was the one
    // thing only ever added.
    const liveDoc: TimelineDocument = {
      id: "live",
      duration: 60_000,
      recording: {
        sources: [{
          id: "live",
          meta: { kind: "pancake-host" },
          observations: [],
        }],
      },
    };
    const e = new Engine(liveDoc);
    e.enqueue({ kind: "play" });
    e.tick(0);
    const before = [...e.world.with("endpoint")].length;
    // Two rounds, because the ledger mints a fresh wire incarnation for each
    // return: a stranded end per cycle is what the reporter counted.
    for (const wire of ["s1", "s2"]) {
      primaryObservations(liveDoc).push({
        id: `${wire}-open`,
        t: e.clock.t + 1,
        kind: "session-opened",
        sessionId: wire,
        a: attachedEndpoint("rooms"),
        b: unattributedEndpoint("goblins-carol"),
        codec: "syrup",
        captpVersion: "v1_0",
      });
      e.tick(20);
      assert(
        findEndpoint(e.world, `${wire}::b`) !== undefined,
        `the end nobody named is drawn while ${wire} is open`,
      );
      // The two paths agree, asked while there is something to agree
      // about: the world reconciled tick by tick holds what a fresh
      // world materialized at the same moment holds. Asked after the
      // close instead, both sides are empty and the reading is free.
      const openReplay = new Engine(structuredClone(liveDoc));
      openReplay.seekTo(e.clock.t);
      const drawn = [...e.world.with("endpoint")].map((x) => x.endpoint.id);
      assert(drawn.length > 0, `${wire} puts ends on the stage to compare`);
      assertEquals(
        [...openReplay.world.with("endpoint")].map((x) => x.endpoint.id),
        drawn,
        `live and replay draw the same ends while ${wire} is open`,
      );
      primaryObservations(liveDoc).push({
        id: `${wire}-close`,
        t: e.clock.t + 1,
        kind: "session-closed",
        sessionId: wire,
      });
      e.tick(20);
      assert(
        findEndpoint(e.world, `${wire}::b`) === undefined,
        `${wire}'s loose end must leave when ${wire} closes`,
      );
    }
    assertEquals(
      [...e.world.with("endpoint")].length,
      before,
      "every cycle gives back the node it took",
    );
  },
);

engineTest(
  "deleting a recorded entity leaves no ghost across re-projection",
  () => {
    // The reported bug: record, switch to Build, delete a rogue
    // peer, restart the playhead — the peer returns. Deletion
    // removed the definition but spared the observations, and the
    // projection re-synthesizes a definition for any id a creation
    // observation mentions, so every re-projection resurrected the
    // ghost. The cascade now purges the observations too.
    const rec: TimelineDocument = {
      id: "rec",
      duration: 5_000,
      recording: {
        sources: [{
          id: "live",
          meta: { kind: "pancake-host" },
          observations: [
            {
              id: "o1",
              t: 0,
              kind: "peer-joined",
              peerId: "rooms",
              profile: "pancake",
            },
            {
              id: "o2",
              t: 0,
              kind: "peer-joined",
              peerId: "rogue",
              profile: "pancake",
            },
            {
              id: "o3",
              t: 10,
              kind: "session-opened",
              sessionId: "s1",
              a: attachedEndpoint("rooms"),
              b: attachedEndpoint("rogue"),
              codec: "syrup",
              captpVersion: "v1_0",
            },
            {
              id: "o4",
              t: 100,
              kind: "message-sent",
              messageId: "m1",
              sessionId: "s1",
              from: "rogue",
              to: "rooms",
              arrivalT: 100,
            },
          ],
        }],
      },
    };
    const e = new Engine(structuredClone(rec));
    e.seekTo(200);
    assert(findPeer(e.world, "rogue") !== undefined, "rogue is on stage");
    e.dispatch({ kind: "delete-peer", peerId: "rogue" });
    // Restart — the re-projection that used to resurrect the ghost.
    e.restart();
    e.seekTo(200);
    assert(
      findPeer(e.world, "rogue") === undefined,
      "the deleted peer must stay deleted across re-projection",
    );
    assert(
      e.doc.entities?.sessions?.s1 === undefined,
      "the cascade took the rogue's session with it",
    );
    assert(
      observationsOf(e.doc).every(
        (ev) => !("peerId" in ev && ev.peerId === "rogue"),
      ),
      "the rogue's observations are purged",
    );
    // Undo restores the whole family — observations included.
    e.undo();
    e.restart();
    e.seekTo(200);
    assert(
      findPeer(e.world, "rogue") !== undefined,
      "undo restores the deleted peer",
    );
  },
);

engineTest(
  "renaming a recorded entity leaves no ghost and keeps its timing",
  () => {
    // The rename sibling of the delete-ghost bug: an observation
    // left on the old id would resurrect a ghost there, and the
    // renamed entity — matching no observations — would collapse to
    // eternal derived timing. The rename carries the observations.
    const rec: TimelineDocument = {
      id: "rec",
      duration: 5_000,
      recording: {
        sources: [{
          id: "live",
          meta: { kind: "pancake-host" },
          observations: [
            {
              id: "o1",
              t: 100,
              kind: "peer-joined",
              peerId: "127.0.0.1:0",
              profile: "pancake",
            },
            { id: "o2", t: 900, kind: "peer-left", peerId: "127.0.0.1:0" },
          ],
        }],
      },
    };
    const e = new Engine(structuredClone(rec));
    e.dispatch({
      kind: "rename-peer",
      oldId: "127.0.0.1:0",
      newId: "carol",
    });
    e.restart();
    e.seekTo(500);
    assert(
      findPeer(e.world, "127.0.0.1:0") === undefined,
      "no ghost under the old id after re-projection",
    );
    assert(findPeer(e.world, "carol") !== undefined, "carol is on stage");
    // The derived span survived the rename: carol still leaves.
    e.seekTo(2_000);
    assert(
      findPeer(e.world, "carol") === undefined,
      "carol's derived leave still applies after the rename",
    );
  },
);
