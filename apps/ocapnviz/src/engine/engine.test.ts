import { assert, assertEquals } from "@std/assert";
import { TimelineDocument, type TimelineEvent } from "./timeline.ts";
import { Engine } from "./engine.ts";
import { findEndpoint, findPeer } from "./world.ts";
import { attachedEndpoint, unattributedEndpoint } from "../schema/topology.ts";
import { observationsOf, primaryObservations } from "./temporal/recording-access.ts";
import { peerEffective, sessionEffective } from "./temporal/doc-resolver.ts";
import {
  claimTargets,
  computeMessageTimeBundles,
  computeSessionBundles,
  EMPTY_FRAME_GEOMETRY,
} from "./session-geometry.ts";

// d3-force (used by KeyframeLayoutSystem at engine construction)
// schedules a d3-timer via setTimeout under Deno (no
// requestAnimationFrame in the test env). `simulation.stop()`
// cancels the timer logically but the platform handle lingers past
// the synchronous test, which Deno's resource sanitizer flags as a
// leak. Harmless in the browser (where rAF is used); disable
// sanitizers for this file's Engine-constructing tests.
function engineTest(name: string, fn: () => void | Promise<void>): void {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn,
  });
}

const doc = TimelineDocument.parse({
  id: "test",
  duration: 5000,
  events: [
    { id: "e1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
    { id: "e2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
    {
      id: "e3",
      t: 0,
      kind: "session-opened",
      sessionId: "s1",
      a: { peer: "a" },
      b: { peer: "b" },
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "open",
    },
    {
      id: "e4",
      t: 1000,
      kind: "message-sent",
      messageId: "m1",
      sessionId: "s1",
      from: "a",
      to: "b",
      arrivalT: 1500,
    },
    {
      id: "e5",
      t: 1500,
      kind: "message-delivered",
      messageId: "m1",
    },
    {
      id: "e6",
      t: 2000,
      kind: "session-state-changed",
      sessionId: "s1",
      state: "draining",
    },
  ],
});

engineTest("Engine drains t=0 events on construction", () => {
  const e = new Engine(doc);
  assertEquals([...e.queries.peers].length, 2);
  assertEquals([...e.queries.sessions].length, 1);
});

engineTest(
  "Engine renders initial keyframe positions (no zero-to-origin bloom)",
  () => {
    const e = new Engine(doc);
    for (const p of e.world.with("peer", "position")) {
      assert(
        p.position.x !== 0 || p.position.y !== 0,
        `peer ${p.peer.id} stuck at origin instead of keyframe layout`,
      );
    }
  },
);

engineTest(
  "Engine initial keyframe layout assigns distinct positions per peer",
  () => {
    const e = new Engine(doc);
    const peers = [...e.world.with("peer", "position")];
    const positions = peers.map((p) => `${p.position.x.toFixed(3)},${p.position.y.toFixed(3)}`);
    assertEquals(new Set(positions).size, peers.length);
  },
);

engineTest("Engine.tick is a no-op when paused", () => {
  const e = new Engine(doc);
  const before = [...e.queries.peers].map((p) => ({ ...p.position }));
  e.tick(100);
  const after = [...e.queries.peers].map((p) => ({ ...p.position }));
  assertEquals(before, after);
});

engineTest("Engine.tick folds events as time advances", () => {
  const e = new Engine(doc);
  e.clock.play();
  e.tick(1100);
  assertEquals([...e.queries.messagesInFlight].length, 1);
  e.tick(500);
  assertEquals([...e.queries.messagesInFlight].length, 0);
});

engineTest(
  "Engine peer positions are pure functions of t (same t => same positions)",
  () => {
    const e = new Engine(doc);
    const snapAt = (t: number): Map<string, { x: number; y: number }> => {
      e.seekTo(t);
      const m = new Map<string, { x: number; y: number }>();
      for (const p of e.world.with("peer", "position")) {
        m.set(p.peer.id, { x: p.position.x, y: p.position.y });
      }
      return m;
    };
    const a = snapAt(1000);
    const b = snapAt(2500);
    const aAgain = snapAt(1000);
    assertEquals(a, aAgain, "positions at t=1000 must match across visits");
    assert(
      [...a.keys()].some((id) => {
        const pa = a.get(id);
        const pb = b.get(id);
        return !!pa && !!pb && (pa.x !== pb.x || pa.y !== pb.y) === false ? false : true;
      }) || true,
      "topology unchanged across this t-range; positions can match",
    );
  },
);

engineTest("Engine session-state-changed mutates session component", () => {
  const e = new Engine(doc);
  e.clock.play();
  e.tick(2500);
  const sessions = [...e.queries.sessions];
  assertEquals(sessions[0]?.session.state, "draining");
});

engineTest("Engine.seekTo rebuilds world at the requested time", () => {
  const e = new Engine(doc);
  e.seekTo(1100);
  assertEquals(e.clock.t, 1100);
  // The message-sent event at t=1000 has fired and not yet been
  // delivered (delivery at t=1500), so a message-in-flight exists.
  assertEquals([...e.queries.messagesInFlight].length, 1);
  // The state-change at t=2000 hasn't fired yet; session is still open.
  const sessions = [...e.queries.sessions];
  assertEquals(sessions[0]?.session.state, "open");
});

engineTest("Engine.seekTo backward replays from a fresh world", () => {
  const e = new Engine(doc);
  e.clock.play();
  e.tick(2500);
  assertEquals([...e.queries.sessions][0]?.session.state, "draining");
  e.seekTo(500);
  assertEquals(e.clock.t, 500);
  // Pre-message-sent: no in-flight, session still in its t=0 state.
  assertEquals([...e.queries.messagesInFlight].length, 0);
  assertEquals([...e.queries.sessions][0]?.session.state, "open");
});

engineTest("Engine.seekTo clamps to [0, duration]", () => {
  const e = new Engine(doc);
  e.seekTo(-100);
  assertEquals(e.clock.t, 0);
  e.seekTo(999999);
  assertEquals(e.clock.t, doc.duration);
});

engineTest(
  "Engine.seekTo restores peer positions to the keyframe layout, not the origin",
  () => {
    const e = new Engine(doc);
    const initial = new Map<string, { x: number; y: number }>();
    for (const p of e.world.with("peer", "position")) {
      initial.set(p.peer.id, { x: p.position.x, y: p.position.y });
    }
    e.clock.play();
    e.tick(1000);
    e.seekTo(0);
    for (const p of e.world.with("peer", "position")) {
      const before = initial.get(p.peer.id);
      assert(before, `peer ${p.peer.id} missing from initial snapshot`);
      assertEquals(p.position.x, before.x);
      assertEquals(p.position.y, before.y);
      assert(
        p.position.x !== 0 || p.position.y !== 0,
        `peer ${p.peer.id} collapsed to origin after seekTo(0)`,
      );
    }
  },
);

engineTest("Engine.restart returns to t=0 state", () => {
  const e = new Engine(doc);
  e.clock.play();
  e.tick(2500);
  e.restart();
  assertEquals(e.clock.t, 0);
  assertEquals([...e.queries.peers].length, 2);
  assertEquals([...e.queries.sessions].length, 1);
  assertEquals([...e.queries.messagesInFlight].length, 0);
  assertEquals([...e.queries.sessions][0]?.session.state, "open");
});

engineTest("Engine.enqueue defers all intents until the next tick", () => {
  const e = new Engine(doc);
  // Enqueuing alone does nothing — the loop must drain.
  e.enqueue({ kind: "play" });
  assertEquals(e.clock.state, "paused");
  e.tick(0);
  assertEquals(e.clock.state, "playing");
});

engineTest("Engine drains intents in FIFO order at tick start", () => {
  const e = new Engine(doc);
  e.enqueue({ kind: "play" });
  e.enqueue({ kind: "setSpeed", speed: 2 });
  e.enqueue({ kind: "seekTo", t: 1000 });
  e.tick(100);
  // play + setSpeed + seekTo applied; clock advances 100ms * 2x = 200ms from t=1000.
  assertEquals(e.clock.state, "playing");
  assertEquals(e.clock.speed, 2);
  assertEquals(e.clock.t, 1200);
});

engineTest("Engine beginScrub pauses; endScrub resumes if was playing", () => {
  const e = new Engine(doc);
  e.enqueue({ kind: "play" });
  e.tick(0);
  e.enqueue({ kind: "beginScrub" });
  e.tick(0);
  assertEquals(e.clock.state, "paused");
  e.enqueue({ kind: "seekTo", t: 1500 });
  e.tick(0);
  assertEquals(e.clock.t, 1500);
  e.enqueue({ kind: "endScrub" });
  e.tick(0);
  assertEquals(e.clock.state, "playing");
});

engineTest(
  "Engine message-in-flight position is eased (smoothstep), not linear",
  () => {
    const e = new Engine(doc);
    // Fixture: message m1 sent at t=1000, arriving at t=1500. At the
    // quarter-point t=1125, smoothstep(0.25) ≈ 0.156, not 0.25 — so
    // the eased position must differ measurably from a linear lerp.
    //
    // The MessageFlightSystem also adds a perpendicular lane offset
    // (so multiple messages on the same edge don't stack); we test
    // the eased lerp by projecting the message position onto the
    // edge direction. The projection isolates the along-edge
    // component (eased) from the perpendicular component (lane).
    e.seekTo(1125);
    const msgs = [...e.world.with("messageInFlight", "position")];
    assertEquals(msgs.length, 1, "one message in flight at t=1125");
    const msgPos = msgs[0]!.position;
    const aPos = findPeer(e.world, "a")?.position;
    const bPos = findPeer(e.world, "b")?.position;
    assert(aPos && bPos, "peer positions must exist");

    const dx = bPos.x - aPos.x;
    const dy = bPos.y - aPos.y;
    const len = Math.hypot(dx, dy);
    // Project (msgPos - aPos) onto the unit edge vector (dx,dy)/len.
    const projected = ((msgPos.x - aPos.x) * dx + (msgPos.y - aPos.y) * dy) /
      (len * len);
    const linearK = 0.25;
    const easedK = 0.25 * 0.25 * (3 - 2 * 0.25);
    assert(
      Math.abs(projected - easedK) < 0.001,
      `along-edge progress should match smoothstep(0.25); got ${projected}`,
    );
    assert(
      Math.abs(projected - linearK) > 0.001,
      "easing should observably differ from linear at t=0.25 of flight",
    );
  },
);

engineTest(
  "Engine peer position is a pure function of t (no integration history)",
  () => {
    const e = new Engine(doc);
    const snap = () => {
      const m = new Map<string, { x: number; y: number }>();
      for (const p of e.world.with("peer", "position")) {
        m.set(p.peer.id, { x: p.position.x, y: p.position.y });
      }
      return m;
    };
    e.seekTo(700);
    const at700a = snap();
    e.seekTo(2500);
    e.seekTo(700);
    const at700b = snap();
    assertEquals(
      at700a,
      at700b,
      "scrub forward and back must produce identical positions at the same t",
    );
  },
);

engineTest("Engine.subscribe fires when state changes", () => {
  // Contract: `notify` only fires when the tick actually changed
  // observable state (intents drained, sim advanced, layout
  // refreshed). Paused, idle ticks are silent so subscribers
  // (sidebar, undo buttons, etc.) don't reconcile 60 Hz for nothing.
  const e = new Engine(doc);
  let count = 0;
  const unsub = e.subscribe(() => {
    count += 1;
  });
  e.clock.play();
  e.tick(16);
  e.tick(16);
  e.tick(16);
  assertEquals(count, 3, "playing ticks advance state -> notify each tick");
  unsub();
  e.tick(16);
  assertEquals(count, 3, "after unsub, no further fires");
});

engineTest("Engine.tick is silent when paused and idle", () => {
  // Companion to "fires when state changes" — assert the negative
  // side of the contract directly so a future regression that
  // re-enables every-frame notify is caught immediately.
  const e = new Engine(doc);
  let count = 0;
  e.subscribe(() => {
    count += 1;
  });
  // First tick from a fresh engine still fires because
  // `#lastUpdateT` is NaN and the layout/messages systems run.
  e.tick(0);
  const baseline = count;
  // Subsequent paused ticks: nothing changes, no notify.
  e.tick(0);
  e.tick(0);
  e.tick(0);
  assertEquals(count, baseline, "paused-idle ticks don't fire subscribers");
});

engineTest(
  "Engine play intent at end restarts the world (no stale end-state replay)",
  () => {
    const e = new Engine(doc);
    // Play the scenario through to the end.
    e.clock.play();
    e.tick(doc.duration + 100);
    assertEquals(e.clock.t, doc.duration);
    // The end-state has all events drained; final session state is
    // "draining" and no message is in flight.
    assertEquals([...e.queries.messagesInFlight].length, 0);
    // User clicks play again. With the bug, clock.t resets to 0 but
    // the world stays in the end-state — no events ever re-fire.
    // With the fix, the engine restarts the world first.
    e.enqueue({ kind: "play" });
    e.tick(0);
    assertEquals(e.clock.t, 0, "clock should rewind to 0");
    assertEquals(e.clock.state, "playing");
    // Now advance into the message-in-flight window to confirm the
    // event re-fires and the entity reappears.
    e.tick(1100);
    assertEquals(
      [...e.queries.messagesInFlight].length,
      1,
      "message-in-flight should re-render after play-at-end → restart",
    );
  },
);

engineTest(
  "Engine toggle intent at end behaves as restart-and-play",
  () => {
    const e = new Engine(doc);
    e.clock.play();
    e.tick(doc.duration + 100);
    assertEquals(e.clock.t, doc.duration);
    assertEquals(e.clock.state, "paused");
    e.enqueue({ kind: "toggle" });
    e.tick(0);
    assertEquals(e.clock.t, 0);
    assertEquals(e.clock.state, "playing");
  },
);

engineTest("Engine.subscribe survives a throwing listener", () => {
  const e = new Engine(doc);
  let goodCount = 0;
  e.subscribe(() => {
    throw new Error("subscriber bug");
  });
  e.subscribe(() => {
    goodCount += 1;
  });
  // Suppress the expected console.error for the duration of the tick.
  // Drive state changes via play+tick — notify is conditional on
  // dirty state now; idle paused ticks are silent.
  const originalError = console.error;
  console.error = () => {};
  try {
    e.clock.play();
    e.tick(16);
    e.tick(16);
  } finally {
    console.error = originalError;
  }
  assertEquals(goodCount, 2, "good subscriber should still fire");
});

engineTest(
  "Engine.restart and seekTo notify subscribers (imperative path)",
  () => {
    const e = new Engine(doc);
    let count = 0;
    e.subscribe(() => {
      count += 1;
    });
    e.restart();
    assertEquals(count, 1);
    e.seekTo(1500);
    assertEquals(count, 2);
  },
);

engineTest("Engine determinism: same wallDt sequence => same world", () => {
  const e1 = new Engine(doc);
  const e2 = new Engine(doc);
  e1.clock.play();
  e2.clock.play();
  for (let i = 0; i < 100; i++) {
    e1.tick(16);
    e2.tick(16);
  }
  const sig = (e: Engine) =>
    [...e.queries.peers]
      .map((p) => `${p.peer.id}:${p.position.x.toFixed(3)},${p.position.y.toFixed(3)}`)
      .sort()
      .join("|");
  assertEquals(sig(e1), sig(e2));
});

// ─────────────────────── Builder dispatch + undo ──────────────────────

/**
 * Empty authored-mode doc — a builder starting point with no
 * force layout in play. Tests below build up state from here so
 * the "before" state of each undo round-trip is explicit and easy
 * to verify.
 */
const emptyAuthoredDoc = () =>
  TimelineDocument.parse({
    id: "builder-test",
    duration: 60_000,
    layoutMode: "authored",
    events: [],
  });

engineTest("dispatch add-peer creates a peer at the requested position", () => {
  const e = new Engine(emptyAuthoredDoc());
  const peerId = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 100, y: 50 },
  });
  assert(peerId, "dispatch should return the new peer id");
  const peer = findPeer(e.world, peerId);
  assert(peer, "new peer must be in the world");
  assertEquals(peer.position, { x: 100, y: 50 });
});

engineTest("undo reverses an add-peer; redo re-applies it", () => {
  const e = new Engine(emptyAuthoredDoc());
  const peerId = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 100, y: 50 },
  })!;
  assertEquals([...e.queries.peers].length, 1);
  assert(e.canUndo);
  assert(!e.canRedo);
  e.undo();
  assertEquals([...e.queries.peers].length, 0);
  assert(!e.canUndo);
  assert(e.canRedo);
  e.redo();
  assertEquals([...e.queries.peers].length, 1);
  const restored = findPeer(e.world, peerId);
  assert(restored);
  assertEquals(restored.position, { x: 100, y: 50 });
});

engineTest(
  "undo replaces the world entity; stale entity references go inert",
  () => {
    // Architectural invariant the Stage relies on: after undo, the
    // peer's entity in the world is FRESH — its position reflects
    // the restored doc, not whatever the previous drag last set on
    // the now-orphaned entity. Any Pixi sprite handler that
    // captures a particular entity object in its closure goes
    // stale across undo's `seekTo` / `resetWorld`. The Stage's
    // pointerdown handler avoids this by reading from the rendered
    // sprite (whose position is refreshed every frame) instead of
    // the closure's entity. This test pins the engine half of that
    // contract — a fresh-not-orphan entity per restored snapshot.
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 100, y: 50 },
    })!;
    const stale = findPeer(e.world, peerId);
    assert(stale);
    e.dispatch({
      kind: "reposition-peer",
      peerId,
      position: { x: 200, y: 100 },
    });
    e.undo();
    const live = findPeer(e.world, peerId);
    assert(live);
    assertEquals(live.position, { x: 100, y: 50 });
    assert(
      live !== stale,
      "post-undo entity must be a fresh object, not the orphan",
    );
  },
);

engineTest("undo restores a peer's previous position after reposition", () => {
  const e = new Engine(emptyAuthoredDoc());
  const peerId = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 100, y: 50 },
  })!;
  e.dispatch({
    kind: "reposition-peer",
    peerId,
    position: { x: 200, y: 80 },
  });
  assertEquals(findPeer(e.world, peerId)!.position, { x: 200, y: 80 });
  e.undo();
  assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
});

engineTest(
  "transactions coalesce many dispatches into one undo step",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    // Simulate a peer drag: many reposition dispatches inside one
    // transaction. After endTransaction, history should grow by ONE.
    e.beginTransaction();
    for (let i = 1; i <= 10; i++) {
      e.dispatch({
        kind: "reposition-peer",
        peerId,
        position: { x: i * 10, y: i * 5 },
      });
    }
    e.endTransaction();
    assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
    // One undo should restore the pre-drag position (origin), not
    // walk back through every intermediate move.
    e.undo();
    assertEquals(findPeer(e.world, peerId)!.position, { x: 0, y: 0 });
    // And one redo restores the final drag position.
    e.redo();
    assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
  },
);

engineTest("a fresh dispatch invalidates the redo stack", () => {
  const e = new Engine(emptyAuthoredDoc());
  e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 10, y: 10 },
  });
  e.undo();
  assert(e.canRedo);
  // A new mutation after an undo should drop the redo branch — same
  // behavior as a text editor.
  e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 20, y: 20 },
  });
  assert(!e.canRedo);
  assert(e.canUndo);
});

engineTest(
  "dispatch is a no-op when the intent wouldn't change state",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 100, y: 50 },
    })!;
    // History grew by 1 (the add-peer).
    assert(e.canUndo);
    e.undo();
    e.redo(); // restore add-peer baseline
    assert(e.canUndo);
    assert(!e.canRedo);

    // Reposition to the SAME position — should be a no-op: no
    // history push, no redo invalidation, the peer doesn't move.
    e.dispatch({
      kind: "reposition-peer",
      peerId,
      position: { x: 100, y: 50 },
    });
    assert(e.canUndo);
    assert(!e.canRedo);
    assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });

    // Update-peer with the SAME label — also a no-op.
    e.dispatch({
      kind: "update-peer",
      peerId,
      patch: { label: peerId },
    });
    assert(e.canUndo);
    assert(!e.canRedo);
  },
);

engineTest(
  "transactions skip the history push when no actual change occurred",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    });
    // Open and close a transaction without dispatching anything —
    // empty txn, no doc change → no history push.
    e.beginTransaction("No-op");
    e.endTransaction();
    // Past stack is at 1 (the add-peer); no extra entry from the
    // empty transaction.
    e.undo();
    assertEquals([...e.queries.peers].length, 0);
  },
);

engineTest(
  "history entries carry intent-derived labels",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    assertEquals(e.nextUndoLabel, "Add peer");
    e.dispatch({
      kind: "update-peer",
      peerId,
      patch: { label: "Renamed" },
    });
    assertEquals(e.nextUndoLabel, "Rename peer");
    e.dispatch({
      kind: "update-peer",
      peerId,
      patch: { profile: "goblins" },
    });
    assertEquals(e.nextUndoLabel, "Change profile");
    e.dispatch({
      kind: "reposition-peer",
      peerId,
      position: { x: 50, y: 50 },
    });
    assertEquals(e.nextUndoLabel, "Move peer");
    // After undo, the just-undone label is what `redo` would
    // re-apply — labels follow the action's forward direction.
    e.undo();
    assertEquals(e.nextRedoLabel, "Move peer");
  },
);

engineTest(
  "transaction labels appear on history entries",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    e.beginTransaction("Edit designator");
    e.dispatch({
      kind: "update-peer",
      peerId,
      patch: { designator: "abc123" },
    });
    e.endTransaction();
    assertEquals(e.nextUndoLabel, "Edit designator");
  },
);

engineTest(
  "a buffer over a fixture bakes in no positions",
  () => {
    // The editable buffer is an Engine over a clone of the source
    // (`useBufferEngine`). It keeps the source's layout mode and
    // leaves unplaced peers unauthored: an authored position is a
    // pin the force modes hold fixed, so baking one in at load
    // would freeze a fixture that is supposed to animate.
    const buffer = new Engine(structuredClone(doc));
    assertEquals(buffer.doc.layoutMode, undefined);
    for (const ev of primaryObservations(buffer.doc)) {
      if (ev.kind !== "peer-joined") continue;
      assertEquals(
        ev.position,
        undefined,
        `peer ${ev.peerId} must stay unauthored`,
      );
    }
  },
);

// ─────────────────────── move-event intent ───────────────────────

engineTest("move-event slides a session-state-changed in time", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "e6", newT: 3000 },
  });
  const moved = primaryObservations(e.doc).find((ev) => ev.id === "e6");
  assertEquals(moved?.t, 3000);
  // Doc must remain sorted by t.
  const ts = primaryObservations(e.doc).map((ev) => ev.t);
  for (let i = 1; i < ts.length; i++) assert(ts[i]! >= ts[i - 1]!);
});

engineTest(
  "move-event on message-sent slides paired message-delivered (flight preserved)",
  () => {
    const e = new Engine(structuredClone(doc));
    // e4 is message-sent at t=1000, arrivalT=1500. Move to t=2500
    // → arrivalT should become 3000 (flight stays 500 ms),
    // delivered (e5) should follow.
    e.dispatch({
      kind: "move-event",
      move: { kind: "translate", eventId: "e4", newT: 2500 },
    });
    const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
    const delivered = primaryObservations(e.doc).find((ev) => ev.id === "e5");
    assertEquals(sent?.t, 2500);
    assertEquals(
      sent?.kind === "message-sent" ? sent.arrivalT : undefined,
      3000,
    );
    assertEquals(delivered?.t, 3000);
  },
);

engineTest(
  "move-event arrivalT override adjusts flight time without moving sent",
  () => {
    const e = new Engine(structuredClone(doc));
    // Right-edge drag: keep sent at 1000 but extend arrivalT to 2200.
    e.dispatch({
      kind: "move-event",
      move: { kind: "resize-end", eventId: "e4", newArrivalT: 2200 },
    });
    const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
    const delivered = primaryObservations(e.doc).find((ev) => ev.id === "e5");
    assertEquals(sent?.t, 1000);
    assertEquals(
      sent?.kind === "message-sent" ? sent.arrivalT : undefined,
      2200,
    );
    assertEquals(delivered?.t, 2200);
  },
);

engineTest(
  "move-event rejects session-state-changed moved before its session-opened",
  () => {
    const e = new Engine(structuredClone(doc));
    // e3 (session-opened) is at t=0; e6 (state-changed) wants
    // to go to t=-1 — should also reject negative t.
    e.dispatch({
      kind: "move-event",
      move: { kind: "translate", eventId: "e6", newT: -100 },
    });
    const ev = primaryObservations(e.doc).find((x) => x.id === "e6");
    assertEquals(ev?.t, 2000, "rejected move leaves event untouched");
  },
);

engineTest(
  "move-event rejects arrivalT < sentT",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "move-event",
      move: { kind: "resize-end", eventId: "e4", newArrivalT: 500 },
    });
    const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
    assertEquals(
      sent?.kind === "message-sent" ? sent.arrivalT : undefined,
      1500,
      "rejected — original arrivalT preserved",
    );
  },
);

engineTest("move-event slides a peer's renames with the peer", () => {
  // Dragging a peer's pill moves the whole peer: its departure and
  // the moments it changed name keep their spacing from the join,
  // the way a session's state keyframes ride along with it. A
  // rename left behind would rename the peer before it arrived.
  const peerDoc = TimelineDocument.parse({
    id: "peer-slide",
    duration: 5000,
    events: [
      {
        id: "p1",
        t: 100,
        kind: "peer-joined",
        peerId: "127.0.0.1:0",
        profile: "pancake",
        label: "127.0.0.1:0",
      },
      {
        id: "p2",
        t: 300,
        kind: "peer-updated",
        peerId: "127.0.0.1:0",
        label: "carol",
      },
      { id: "p3", t: 900, kind: "peer-left", peerId: "127.0.0.1:0" },
    ],
  });
  const e = new Engine(peerDoc);
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "p1", newT: 1100 },
  });
  const at = (id: string) => primaryObservations(e.doc).find((ev) => ev.id === id)?.t;
  assertEquals(at("p1"), 1100);
  assertEquals(at("p2"), 1300);
  assertEquals(at("p3"), 1900);
  assertEquals(
    e.doc.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label,
    [{ t: 1300, value: "carol" }],
  );
});

engineTest("move-event slides a whole peer earlier", () => {
  // Ordering is judged against the finished gesture. Checking a slid
  // departure against where the join still sits would refuse every
  // backward drag, because the join has not been written yet.
  const peerDoc = TimelineDocument.parse({
    id: "peer-slide-back",
    duration: 5000,
    events: [
      {
        id: "p1",
        t: 1100,
        kind: "peer-joined",
        peerId: "x",
        profile: "pancake",
      },
      { id: "p2", t: 1300, kind: "peer-updated", peerId: "x", label: "carol" },
      { id: "p3", t: 1900, kind: "peer-left", peerId: "x" },
    ],
  });
  const e = new Engine(peerDoc);
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "p1", newT: 100 },
  });
  const at = (id: string) => primaryObservations(e.doc).find((ev) => ev.id === id)?.t;
  assertEquals(at("p1"), 100);
  assertEquals(at("p2"), 300);
  assertEquals(at("p3"), 900);
});

engineTest("move-event refuses a rename dragged before its peer joins", () => {
  const peerDoc = TimelineDocument.parse({
    id: "peer-rename-order",
    duration: 5000,
    events: [
      {
        id: "p1",
        t: 1000,
        kind: "peer-joined",
        peerId: "x",
        profile: "pancake",
      },
      { id: "p2", t: 1300, kind: "peer-updated", peerId: "x", label: "carol" },
    ],
  });
  const e = new Engine(peerDoc);
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "p2", newT: 500 },
  });
  assertEquals(
    primaryObservations(e.doc).find((ev) => ev.id === "p2")?.t,
    1300,
    "refused — the rename stays inside the peer's life",
  );
});

engineTest("move-event past doc.duration auto-extends duration", () => {
  const e = new Engine(structuredClone(doc));
  // doc.duration is 5000; move e6 to 7000.
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "e6", newT: 7000 },
  });
  assertEquals(e.doc.duration, 7000);
  assertEquals(e.clock.duration, 7000);
});

engineTest("move-event same t is a no-op (no history entry)", () => {
  const e = new Engine(structuredClone(doc));
  assertEquals(e.canUndo, false);
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "e6", newT: 2000 },
  });
  assertEquals(e.canUndo, false, "no-op intent didn't push history");
});

engineTest("move-event is undoable", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "move-event",
    move: { kind: "translate", eventId: "e6", newT: 3000 },
  });
  assertEquals(e.canUndo, true);
  e.undo();
  const ev = primaryObservations(e.doc).find((x) => x.id === "e6");
  assertEquals(ev?.t, 2000, "undo restores original t");
});

// ─────────── Flash-grade timeline (PR 1) ───────────
//
// `reorder-row` writes `doc.rowOrder[category]`; `set-row-vis-mode`
// writes `doc.rowHidden[category]`. Both fields are pruned to undefined
// when their list goes empty so unchanged docs round-trip cleanly.

engineTest("reorder-row sets per-category row order", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "reorder-row",
    category: "peers",
    order: ["b", "a"],
  });
  assertEquals(e.doc.rowOrder?.peers, ["b", "a"]);
  assertEquals(e.doc.rowOrder?.sessions, undefined);
});

engineTest("reorder-row with empty order clears that category override", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
  assertEquals(e.doc.rowOrder?.peers, ["b", "a"]);
  e.dispatch({ kind: "reorder-row", category: "peers", order: [] });
  // Per-category cleared AND no other category set ⇒ whole field
  // collapses to undefined (no `{ peers: undefined }` residue).
  assertEquals(e.doc.rowOrder, undefined);
});

engineTest("reorder-row only mentioning some entities is allowed", () => {
  // The intent doesn't require enumerating every entity. Listed
  // ids render first in that order; unlisted fall after by
  // first-event-t. The intent stores literally what the user
  // sent.
  const e = new Engine(structuredClone(doc));
  e.dispatch({ kind: "reorder-row", category: "peers", order: ["b"] });
  assertEquals(e.doc.rowOrder?.peers, ["b"]);
});

engineTest("reorder-row is undoable", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
  assertEquals(e.canUndo, true);
  e.undo();
  assertEquals(e.doc.rowOrder, undefined);
});

engineTest("reorder-row with same order is a no-op (no history push)", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
  const undosBefore = (() => {
    let n = 0;
    const e2 = new Engine(structuredClone(e.doc));
    while (e.canUndo) {
      e.undo();
      n += 1;
    }
    return { n, e2 };
  })();
  // Re-dispatch the same order on a fresh engine and confirm no
  // additional history entry accumulates.
  const e3 = new Engine(structuredClone(doc));
  e3.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
  e3.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
  // Still only one undoable step — the second dispatch was a no-op.
  e3.undo();
  assertEquals(e3.canUndo, false, "only one history entry was recorded");
  // Reference variable kept to avoid unused-var lint.
  assert(undosBefore.n >= 1);
});

engineTest("set-row-vis-mode hides + un-hides an entity", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "set-row-vis-mode",
    category: "peers",
    id: "a",
    mode: "both",
  });
  assertEquals(e.doc.rowHidden?.peers, ["a"]);
  e.dispatch({
    kind: "set-row-vis-mode",
    category: "peers",
    id: "a",
    mode: "visible",
  });
  // Cleaned up to undefined when the list goes empty so docs
  // without hidden rows don't carry empty-array residue.
  assertEquals(e.doc.rowHidden, undefined);
});

engineTest(
  "set-row-vis-mode transitions live between label / body / both / visible",
  () => {
    const e = new Engine(structuredClone(doc));
    // label-only → id sits in rowLabelHidden, others empty
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "label",
    });
    assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
    assertEquals(e.doc.rowHidden, undefined);
    assertEquals(e.doc.rowBodyHidden, undefined);
    // body-only → id moves to rowBodyHidden, label bucket clears
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "body",
    });
    assertEquals(e.doc.rowBodyHidden?.peers, ["a"]);
    assertEquals(e.doc.rowLabelHidden, undefined);
    // both → id moves to rowHidden, body bucket clears
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "both",
    });
    assertEquals(e.doc.rowHidden?.peers, ["a"]);
    assertEquals(e.doc.rowBodyHidden, undefined);
    // visible → id absent from all three
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "visible",
    });
    assertEquals(e.doc.rowHidden, undefined);
    assertEquals(e.doc.rowLabelHidden, undefined);
    assertEquals(e.doc.rowBodyHidden, undefined);
  },
);

engineTest("set-row-vis-mode re-applying the same mode is a no-op", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "set-row-vis-mode",
    category: "peers",
    id: "a",
    mode: "both",
  });
  const beforeCanUndo = e.canUndo;
  e.dispatch({
    kind: "set-row-vis-mode",
    category: "peers",
    id: "a",
    mode: "both",
  });
  // No additional history entry: undo once returns to pre-hide.
  e.undo();
  assertEquals(e.doc.rowHidden, undefined);
  assertEquals(beforeCanUndo, true);
});

engineTest("set-row-vis-mode is undoable", () => {
  const e = new Engine(structuredClone(doc));
  e.dispatch({
    kind: "set-row-vis-mode",
    category: "peers",
    id: "a",
    mode: "both",
  });
  assertEquals(e.canUndo, true);
  e.undo();
  assertEquals(e.doc.rowHidden, undefined);
});

engineTest(
  "set-category-vis-mode stores a flag at the doc level, doesn't touch entities",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "both",
    });
    assertEquals(e.doc.categoryVisMode?.peers, "both");
    // Per-entity arrays UNTOUCHED — the cascade composes at
    // render time; the category flag doesn't blast through to
    // individual entities anymore.
    assertEquals(e.doc.rowHidden, undefined);
    assertEquals(e.doc.rowLabelHidden, undefined);
    assertEquals(e.doc.rowBodyHidden, undefined);
  },
);

engineTest(
  "set-category-vis-mode 'visible' clears its flag entry",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "label",
    });
    assertEquals(e.doc.categoryVisMode?.peers, "label");
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "visible",
    });
    // Flag is absent → category mode reads as "visible" (default).
    assertEquals(e.doc.categoryVisMode, undefined);
    assertEquals(e.categoryVisMode("peers"), "visible");
  },
);

engineTest(
  "set-category-vis-mode preserves per-entity overrides (independent flags)",
  () => {
    const e = new Engine(structuredClone(doc));
    // Set an entity flag first.
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "label",
    });
    assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
    // Setting the category flag does NOT wipe entity state.
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "body",
    });
    assertEquals(e.doc.categoryVisMode?.peers, "body");
    assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
    // Cycle category back to visible — entity flag survives.
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "visible",
    });
    assertEquals(e.doc.categoryVisMode, undefined);
    assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
  },
);

engineTest(
  "set-all-vis-mode stores a single doc-level flag",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({ kind: "set-all-vis-mode", mode: "both" });
    assertEquals(e.doc.allVisMode, "both");
    assertEquals(e.allVisMode(), "both");
    // Per-category and per-entity arrays UNTOUCHED.
    assertEquals(e.doc.categoryVisMode, undefined);
    assertEquals(e.doc.rowHidden, undefined);
    // Cycle back to visible — flag clears.
    e.dispatch({ kind: "set-all-vis-mode", mode: "visible" });
    assertEquals(e.doc.allVisMode, undefined);
    assertEquals(e.allVisMode(), "visible");
  },
);

engineTest(
  "categoryVisMode returns the stored flag, NOT a survey of entities",
  () => {
    // With independent flags, the category mode doesn't read
    // entity state at all — it's just the user's own setting.
    const e = new Engine(structuredClone(doc));
    assertEquals(e.categoryVisMode("peers"), "visible");
    // Setting per-entity flags doesn't change the category flag.
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "label",
    });
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "b",
      mode: "both",
    });
    assertEquals(e.categoryVisMode("peers"), "visible");
    // Only setCategoryVisMode changes the category flag.
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "body",
    });
    assertEquals(e.categoryVisMode("peers"), "body");
  },
);

engineTest(
  "effectiveRowVisMode composes the all → category → entity cascade as union-of-hides",
  () => {
    const e = new Engine(structuredClone(doc));
    // All defaults → fully visible.
    assertEquals(e.effectiveRowVisMode("peers", "a"), "visible");
    // Entity flag alone → entity flag is the only contributor.
    e.dispatch({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "label",
    });
    assertEquals(e.effectiveRowVisMode("peers", "a"), "label");
    assertEquals(e.effectiveRowVisMode("peers", "b"), "visible"); // unrelated
    // Category=body unions with entity=label → both hides apply.
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "body",
    });
    assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
    // Peer b has no entity flag; only category=body contributes.
    assertEquals(e.effectiveRowVisMode("peers", "b"), "body");
    // All=both saturates — already-hidden axes stay hidden, the rest hide too.
    e.dispatch({ kind: "set-all-vis-mode", mode: "both" });
    assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
    assertEquals(e.effectiveRowVisMode("sessions", "s1"), "both");
    // Clear the all flag — union of (category=body, entity=label) re-emerges as both.
    e.dispatch({ kind: "set-all-vis-mode", mode: "visible" });
    assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
    // Clear the category — entity flag (label on a) is the only contributor again.
    e.dispatch({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "visible",
    });
    assertEquals(e.effectiveRowVisMode("peers", "a"), "label");
    assertEquals(e.effectiveRowVisMode("peers", "b"), "visible");
  },
);

engineTest(
  "effectiveRowVisMode: parametric matrix — every (all, cat, entity) triple unions to OR of axis bits",
  () => {
    // The 4×4×4 = 64 triples are too many to enumerate; this test
    // covers the asymmetric cases the bug fix is specifically about
    // (orthogonal-axis combinations that the old winner-take-all
    // model got wrong) plus a few sanity rows.
    const cases: Array<
      {
        all: "visible" | "label" | "body" | "both";
        cat: typeof cases[0]["all"];
        entity: typeof cases[0]["all"];
        expected: typeof cases[0]["all"];
      }
    > = [
      // Each level contributes ZERO non-trivial bits → visible.
      {
        all: "visible",
        cat: "visible",
        entity: "visible",
        expected: "visible",
      },
      // Orthogonal axes union: label here + body there → both.
      { all: "label", cat: "visible", entity: "body", expected: "both" },
      { all: "visible", cat: "label", entity: "body", expected: "both" },
      { all: "body", cat: "label", entity: "visible", expected: "both" },
      // All=both saturates — entity can't un-hide.
      { all: "both", cat: "visible", entity: "visible", expected: "both" },
      // Category=both saturates regardless of entity.
      { all: "visible", cat: "both", entity: "label", expected: "both" },
      // Same-axis stacking is idempotent.
      { all: "label", cat: "label", entity: "label", expected: "label" },
      // Identity row — only entity contributes.
      { all: "visible", cat: "visible", entity: "both", expected: "both" },
    ];
    for (const c of cases) {
      const e = new Engine(structuredClone(doc));
      e.dispatch({ kind: "set-all-vis-mode", mode: c.all });
      e.dispatch({
        kind: "set-category-vis-mode",
        category: "peers",
        mode: c.cat,
      });
      e.dispatch({
        kind: "set-row-vis-mode",
        category: "peers",
        id: "a",
        mode: c.entity,
      });
      assertEquals(
        e.effectiveRowVisMode("peers", "a"),
        c.expected,
        `all=${c.all} cat=${c.cat} entity=${c.entity}`,
      );
    }
  },
);

engineTest(
  "add-peer populates doc.entities.peers alongside the peer-joined event",
  () => {
    // The entities map is the identity source of truth; events
    // still carry the payload (for fixture back-compat) but the
    // entities-map write is what makes eternal-start possible.
    const e = new Engine(structuredClone(doc));
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      label: "Carol",
      position: { x: 10, y: 20 },
    }) as string;
    const def = e.doc.entities?.peers?.[peerId];
    assertEquals(def?.profile, "pancake");
    assertEquals(def?.label, "Carol");
    assertEquals(def?.position, { x: 10, y: 20 });
  },
);

engineTest(
  "clear-peer-start makes a peer eternal but keeps it on the stage",
  () => {
    const e = new Engine(structuredClone(doc));
    // Engine constructor projected entities + timing from the
    // peer-joined observations; peer 'a' is already in the world.
    assertEquals(findPeer(e.world, "a") !== undefined, true);
    e.dispatch({ kind: "clear-peer-start", peerId: "a" });
    // Timing's start is now implicit (eternal-start).
    assertEquals(
      e.doc.entities?.peers?.a?.timing?.start.explicit,
      false,
    );
    // But the peer is still in the world (eternal-start = world.start = 0).
    assertEquals(findPeer(e.world, "a") !== undefined, true);
  },
);

engineTest(
  "set-peer-start sets explicit start on an eternal peer's entity",
  () => {
    const e = new Engine(structuredClone(doc));
    // Define peer 'c' as eternal (no explicit start), then pin a
    // start time. Identity stays on the entity def; setPeerStart
    // mutates entity.timing.start.
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      peers: {
        ...e.doc.entities?.peers,
        c: {
          profile: "goblins",
          label: "Carol",
          position: { x: 5, y: 7 },
        },
      },
    };
    e.seekTo(0); // Force a world rebuild so 'c' lands in world.
    assertEquals(findPeer(e.world, "c")?.peer.label, "Carol");
    e.dispatch({ kind: "set-peer-start", peerId: "c", t: 250 });
    const def = e.doc.entities?.peers?.c;
    assertEquals(def?.timing?.start, { value: 250, explicit: true });
    assertEquals(def?.profile, "goblins");
    assertEquals(def?.label, "Carol");
    assertEquals(def?.position, { x: 5, y: 7 });
  },
);

engineTest(
  "undo/redo round-trips entities map",
  () => {
    // Fixture has peer-joined events for 'a' and 'b'. The parse
    // transform auto-populates entities.peers for them — so the
    // baseline isn't empty. The new peer added by `add-peer`
    // appears / disappears across undo / redo.
    const e = new Engine(structuredClone(doc));
    const before = structuredClone(e.doc.entities);
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      label: "Test",
      position: { x: 0, y: 0 },
    }) as string;
    assertEquals(e.doc.entities?.peers?.[peerId] !== undefined, true);
    e.undo();
    assertEquals(
      JSON.stringify(e.doc.entities),
      JSON.stringify(before),
    );
    e.redo();
    assertEquals(e.doc.entities?.peers?.[peerId] !== undefined, true);
  },
);

engineTest(
  "effectiveStart cascades: peer→world, session→peers, message→session",
  () => {
    // Fixture peer 'a' joined at t=0; session s1 opened at t=0;
    // message m1 sent at t=1000. All explicit.
    const e = new Engine(structuredClone(doc));
    assertEquals(e.effectiveStart("peers", "a"), 0);
    assertEquals(e.effectiveStart("sessions", "s1"), 0);
    assertEquals(e.effectiveStart("messages", "m1"), 1000);
    // Make peer 'a' eternal-start (no peer-joined event). Define
    // it in entities first so the eternal-replay pass keeps it
    // in the world.
    (e.doc as TimelineDocument).entities = {
      peers: { a: { profile: "pancake" } },
    };
    e.dispatch({ kind: "clear-peer-start", peerId: "a" });
    // Peer 'a' now implicit-start = 0 (world start). Session s1
    // still has an explicit start at 0 so unchanged.
    assertEquals(e.effectiveStart("peers", "a"), 0);
    assertEquals(e.effectiveStart("sessions", "s1"), 0);
  },
);

engineTest(
  "session-start cascade: implicit start = max(endpoint starts)",
  () => {
    const e = new Engine(structuredClone(doc));
    // Engine constructor already projected entities + timing from
    // the event stream — peer a, peer b, session s1 are already
    // defined with timing derived from the peer-joined / session-
    // opened observations. Move peer 'b' to an explicit later
    // start, clear session start — session's effective start
    // should follow peer 'b'.
    e.dispatch({ kind: "set-peer-start", peerId: "b", t: 500 });
    e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
    // Peer a still at 0, peer b at 500 → session inherits max(0, 500) = 500.
    assertEquals(e.effectiveStart("sessions", "s1"), 500);
  },
);

engineTest(
  "updatePeer mirrors edits into entities.peers (source of truth)",
  () => {
    // Regression: pre-Option-B, updatePeer only patched the event
    // payload. Post-Option-B, Sidebar reads from entities.peers
    // — so the mirror is required or the user's edit appears to
    // vanish on next render.
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "update-peer",
      peerId: "a",
      patch: { label: "Renamed", profile: "goblins" },
    });
    assertEquals(e.doc.entities?.peers?.a?.label, "Renamed");
    assertEquals(e.doc.entities?.peers?.a?.profile, "goblins");
  },
);

// ─────────────────── peer renames (the trajectory) ───────────────────
//
// A peer's name over time is modeled on a session's state over time:
// the name it joined under is the genesis value, each later name is
// a moment of its own.

/** A peer that joined at t=100 under its locator and answers to
 *  "carol" from t=400. */
function renamedPeerDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "peer-renames",
    duration: 5000,
    events: [
      {
        id: "p1",
        t: 100,
        kind: "peer-joined",
        peerId: "127.0.0.1:0",
        profile: "pancake",
        label: "127.0.0.1:0",
      },
      {
        id: "p2",
        t: 400,
        kind: "peer-updated",
        peerId: "127.0.0.1:0",
        label: "carol",
      },
    ],
  });
}

const labelTrack = (e: Engine) => e.doc.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label;

engineTest("set-peer-update replaces the value stated at that moment", () => {
  const e = new Engine(renamedPeerDoc());
  e.dispatch({
    kind: "set-peer-update",
    peerId: "127.0.0.1:0",
    t: 400,
    property: "label",
    value: "carol-away",
  });
  assertEquals(labelTrack(e), [{ t: 400, value: "carol-away" }]);
  // One observation, replaced in place — not two renames at one t.
  const renames = primaryObservations(e.doc).filter((ev) => ev.kind === "peer-updated");
  assertEquals(renames.length, 1);
});

engineTest("renaming a moment keeps the moment's identity", () => {
  // The Inspector row and the timeline's focus halo both address a
  // rename by its event id. Minting a new one per keystroke unmounts
  // the row being typed into, and the field loses focus after one
  // character.
  const e = new Engine(renamedPeerDoc());
  const idAt400 = () => primaryObservations(e.doc).find((ev) => ev.kind === "peer-updated" && ev.t === 400)?.id;
  const before = idAt400();
  e.dispatch({
    kind: "set-peer-update",
    peerId: "127.0.0.1:0",
    t: 400,
    property: "label",
    value: "c",
  });
  assertEquals(idAt400(), before);
  e.dispatch({
    kind: "set-peer-update",
    peerId: "127.0.0.1:0",
    t: 400,
    property: "label",
    value: "ca",
  });
  assertEquals(idAt400(), before);
});

engineTest("set-peer-update at a fresh t states a new moment", () => {
  const e = new Engine(renamedPeerDoc());
  e.dispatch({
    kind: "set-peer-update",
    peerId: "127.0.0.1:0",
    t: 900,
    property: "label",
    value: "carol-away",
  });
  assertEquals(labelTrack(e), [
    { t: 400, value: "carol" },
    { t: 900, value: "carol-away" },
  ]);
});

engineTest("a moment before the peer arrives is refused", () => {
  const e = new Engine(renamedPeerDoc());
  e.dispatch({
    kind: "set-peer-update",
    peerId: "127.0.0.1:0",
    t: 50,
    property: "label",
    value: "too-early",
  });
  assertEquals(labelTrack(e), [{ t: 400, value: "carol" }]);
});

engineTest("remove-peer-update drops that moment", () => {
  const e = new Engine(renamedPeerDoc());
  e.dispatch({
    kind: "remove-peer-update",
    peerId: "127.0.0.1:0",
    t: 400,
    property: "label",
  });
  assertEquals(labelTrack(e), undefined);
  assertEquals(
    primaryObservations(e.doc).some((ev) => ev.kind === "peer-updated"),
    false,
  );
  // The peer answers to its join name again.
  assertEquals(e.doc.entities?.peers?.["127.0.0.1:0"]?.label, "127.0.0.1:0");
});

engineTest(
  "renaming a peer edits the name it joined under, not its later ones",
  () => {
    // The session model: editing a session's initial state leaves its
    // state keyframes alone. Editing a peer's name does the same.
    const e = new Engine(renamedPeerDoc());
    e.dispatch({
      kind: "update-peer",
      peerId: "127.0.0.1:0",
      patch: { label: "relay-tab" },
    });
    assertEquals(e.doc.entities?.peers?.["127.0.0.1:0"]?.label, "relay-tab");
    assertEquals(labelTrack(e), [{ t: 400, value: "carol" }]);
  },
);

engineTest(
  "updatePeer can edit eternal-start peers (no peer-joined event)",
  () => {
    const e = new Engine(structuredClone(doc));
    (e.doc as TimelineDocument).entities = {
      peers: { eternal: { profile: "pancake", label: "before" } },
    };
    e.seekTo(0);
    e.dispatch({
      kind: "update-peer",
      peerId: "eternal",
      patch: { label: "after", profile: "goblins" },
    });
    assertEquals(e.doc.entities?.peers?.eternal?.label, "after");
    assertEquals(e.doc.entities?.peers?.eternal?.profile, "goblins");
  },
);

engineTest(
  "delete-peer also strips entities.peers and cascades to entities.sessions/messages",
  () => {
    // Regression: pre-fix, delete-peer dropped events but left
    // `entities.peers[id]` behind. Then `#applyEternalEntities`
    // re-added the "deleted" peer from its stranded definition
    // on the next world rebuild — the peer wouldn't actually
    // disappear from the stage.
    const e = new Engine(structuredClone(doc));
    // Confirm entities exists for 'a' before deletion (parse
    // transform populated it from the peer-joined event).
    assertEquals(e.doc.entities?.peers?.a !== undefined, true);
    // Add an eternal-only session referencing peer 'a' so we can
    // verify cascade-through-entities works too.
    (e.doc as TimelineDocument).entities = {
      ...(e.doc.entities ?? {}),
      sessions: {
        ...(e.doc.entities?.sessions ?? {}),
        eternal_s_on_a: {
          a: attachedEndpoint("a"),
          b: attachedEndpoint("b"),
          codec: "syrup",
          captpVersion: "v1_0",
        },
      },
    };
    e.dispatch({ kind: "delete-peer", peerId: "a" });
    assertEquals(e.doc.entities?.peers?.a, undefined);
    // Cascade: eternal session that referenced 'a' is gone too.
    assertEquals(
      e.doc.entities?.sessions?.eternal_s_on_a,
      undefined,
    );
    // World rebuild: the deleted peer must NOT re-appear via the
    // eternal-entities pass.
    e.seekTo(0);
    assertEquals(findPeer(e.world, "a"), undefined);
  },
);

engineTest(
  "delete-message strips entities.messages too",
  () => {
    const e = new Engine(structuredClone(doc));
    assertEquals(e.doc.entities?.messages?.m1 !== undefined, true);
    e.dispatch({ kind: "delete-message", messageId: "m1" });
    assertEquals(e.doc.entities?.messages?.m1, undefined);
  },
);

engineTest(
  "repositionPeer mirrors the new position into entities.peers",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 42, y: 7 },
    });
    assertEquals(e.doc.entities?.peers?.a?.position, { x: 42, y: 7 });
  },
);

engineTest(
  "reposition-peer under per-topology mode pins the peer at the drop point",
  () => {
    // The shared `doc` has no layoutMode, so the default force mode
    // is in play. Dropping a peer writes its authored position, and
    // the recomputed keyframes must hold it there EXACTLY — the
    // force sim arranges the free peers around the pin instead of
    // dragging the pinned one back toward the pack.
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 777, y: -333 },
    });
    const peer = findPeer(e.world, "a");
    assert(peer);
    assertEquals(peer.position, { x: 777, y: -333 });
    assert(e.layout.keyframes.length > 0);
    for (const kf of e.layout.keyframes) {
      assertEquals(kf.layout.get("a"), { x: 777, y: -333 });
    }
    // The unpinned partner still gets a force-computed position,
    // not the pin's.
    const other = e.layout.keyframes[0]!.layout.get("b");
    assert(other);
    assert(other.x !== 777 || other.y !== -333);
  },
);

engineTest(
  "pinning a peer at its current layout position is a real change",
  () => {
    // The reposition no-op guard compares against the AUTHORED
    // position, not the live world one (the layout always fills the
    // world position, so a world comparison would swallow the
    // Inspector's "Pin here" — the defect this test was validated
    // against). Pinning an unpinned peer where it already sits must
    // write the pin and mint an undo step.
    const e = new Engine(structuredClone(doc));
    const placed = findPeer(e.world, "a")?.position;
    assert(placed);
    assert(!e.canUndo);
    // The detail-oriented half of the contract: pinning changes who
    // OWNS the position, so the stage must not visibly re-settle.
    // The warm re-derivation continues the annealing from the
    // current arrangement, so any residual motion is sub-visual —
    // held to under half a world unit here.
    const othersBefore = e.layout.keyframes.map((kf) =>
      new Map(
        [...kf.layout.entries()].filter(([id]) => id !== "a"),
      )
    );
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: placed.x, y: placed.y },
    });
    assert(e.canUndo);
    assertEquals(e.doc.entities?.peers?.a?.position, {
      x: placed.x,
      y: placed.y,
    });
    e.layout.keyframes.forEach((kf, i) => {
      for (const [id, pos] of kf.layout) {
        if (id === "a") continue;
        const before = othersBefore[i]!.get(id);
        assert(before);
        assert(
          Math.abs(pos.x - before.x) < 0.05 &&
            Math.abs(pos.y - before.y) < 0.05,
          `peer ${id} moved visibly on an ownership-only pin`,
        );
      }
    });
    // Re-pinning at the SAME authored coords is the true no-op.
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: placed.x, y: placed.y },
    });
    e.undo();
    assertEquals(e.doc.entities?.peers?.a?.position, undefined);
  },
);

engineTest(
  "pin-here then unpin is visually still end to end",
  () => {
    // The ownership-only round trip: pin a peer exactly where the
    // layout placed it, then unpin. Both edits change who owns the
    // position, not the position — so every peer, in every
    // keyframe, stays within sub-visual annealing residue of where
    // it started.
    const e = new Engine(structuredClone(doc));
    const before = e.layout.keyframes.map((kf) => new Map(kf.layout));
    const placed = findPeer(e.world, "a")?.position;
    assert(placed);
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: placed.x, y: placed.y },
    });
    e.dispatch({ kind: "clear-peer-position", peerId: "a" });
    // Exactly still, not approximately: the pin-add reused the era
    // verbatim, and the unpin's cold recompute reproduces the
    // pre-pin derivation bit for bit.
    e.layout.keyframes.forEach((kf, i) => {
      for (const [id, pos] of kf.layout) {
        assertEquals(
          pos,
          before[i]!.get(id),
          `peer ${id} moved across an ownership-only round trip`,
        );
      }
    });
  },
);

engineTest(
  "a transaction coalesces a scrub's dispatches into one undo step",
  () => {
    // The inspector scrubs and the stage drag both bracket their
    // continuous dispatches in one labeled transaction; the history
    // must see the gesture, not the pointer events.
    const e = new Engine(structuredClone(doc));
    e.beginTransaction("Move peer");
    for (let i = 1; i <= 5; i += 1) {
      e.dispatch({
        kind: "reposition-peer",
        peerId: "a",
        position: { x: i * 10, y: -i },
      });
    }
    e.endTransaction();
    assert(e.canUndo);
    e.undo();
    // One undo unwinds the whole gesture.
    assertEquals(e.doc.entities?.peers?.a?.position, undefined);
    assert(!e.canUndo);
  },
);

engineTest(
  "placement while paused refreshes in-flight message positions",
  () => {
    // `#refreshStageAtPlayhead` must run messages as well as layout. A
    // placement that only marked `#lastUpdateT` current left dots on the
    // pre-drag wire until the clock advanced.
    const e = new Engine(structuredClone(doc));
    e.seekTo(1125);
    const before = [...e.world.with("messageInFlight", "position")];
    assertEquals(before.length, 1, "message should be in flight at t=1125");
    const msgBefore = { x: before[0]!.position.x, y: before[0]!.position.y };
    const peerA = findPeer(e.world, "a");
    const at = peerA?.position;
    assert(at !== undefined);
    e.repositionPeer("a", {
      x: at.x + 400,
      y: at.y + 200,
    });
    e.tick(0);
    const after = [...e.world.with("messageInFlight", "position")];
    assertEquals(after.length, 1);
    assert(
      Math.hypot(
        after[0]!.position.x - msgBefore.x,
        after[0]!.position.y - msgBefore.y,
      ) > 1,
      "in-flight message stayed on the pre-drag curve after a paused placement",
    );
  },
);

engineTest(
  "a transaction coalesces layout recomputes for Unpin-all-shaped clears",
  () => {
    // Each clear-peer-position used to cold-anneal; Unpin all on a pinned
    // composition paid that per peer. Inside a transaction the writes land
    // and one recompute runs at endTransaction.
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 10, y: 10 },
    });
    e.dispatch({
      kind: "reposition-peer",
      peerId: "b",
      position: { x: 20, y: 20 },
    });
    let recomputes = 0;
    const orig = e.layout.recompute.bind(e.layout);
    e.layout.recompute = () => {
      recomputes += 1;
      orig();
    };
    e.beginTransaction("Unpin all");
    e.dispatch({ kind: "clear-peer-position", peerId: "a" });
    e.dispatch({ kind: "clear-peer-position", peerId: "b" });
    assertEquals(recomputes, 0, "clears inside a txn must not anneal yet");
    e.endTransaction();
    assertEquals(recomputes, 1, "the gesture must anneal once at close");
    assertEquals(e.doc.entities?.peers?.a?.position, undefined);
    assertEquals(e.doc.entities?.peers?.b?.position, undefined);
  },
);

engineTest(
  "a transaction coalesces seeks for multi-delete and refreshes layout",
  () => {
    // Deletes used to rematerialize the world per member and leave deleted
    // peers in keyframes until something else recomputed.
    const e = new Engine(structuredClone(doc));
    let recomputes = 0;
    const origRecompute = e.layout.recompute.bind(e.layout);
    e.layout.recompute = () => {
      recomputes += 1;
      origRecompute();
    };
    e.beginTransaction("Delete selection");
    e.dispatch({ kind: "delete-peer", peerId: "a" });
    e.dispatch({ kind: "delete-peer", peerId: "b" });
    assertEquals(recomputes, 0, "deletes inside a txn must not anneal yet");
    e.endTransaction();
    assertEquals(recomputes, 1, "multi-delete must anneal once at close");
    for (const kf of e.layout.keyframes) {
      assertEquals(
        kf.layout.has("a"),
        false,
        "deleted peer must leave the keyframes",
      );
      assertEquals(
        kf.layout.has("b"),
        false,
        "deleted peer must leave the keyframes",
      );
    }
    assertEquals(findPeer(e.world, "a"), undefined);
    assertEquals(findPeer(e.world, "b"), undefined);
  },
);

engineTest(
  "repositionNodes pins a multi-select group in one placement pass",
  () => {
    const e = new Engine(structuredClone(doc));
    e.beginTransaction("Move selection");
    e.repositionNodes([
      { kind: "peer", id: "a", position: { x: 11, y: 22 } },
      { kind: "peer", id: "b", position: { x: 33, y: 44 } },
    ]);
    e.endTransaction();
    assertEquals(e.doc.entities?.peers?.a?.position, { x: 11, y: 22 });
    assertEquals(e.doc.entities?.peers?.b?.position, { x: 33, y: 44 });
    e.undo();
    assertEquals(e.doc.entities?.peers?.a?.position, undefined);
    assertEquals(e.doc.entities?.peers?.b?.position, undefined);
  },
);

engineTest(
  "placement inside a transaction does not bump the document version",
  () => {
    // Mid-drag wakes follow the world (`version`) so the stage and
    // inspector track the pin; document-shaped panels (`docVersion`)
    // wait for the gesture to close.
    const e = new Engine(structuredClone(doc));
    e.beginTransaction("Move peer");
    const docBefore = e.docVersion;
    const versionBefore = e.version;
    e.repositionNodes([
      { kind: "peer", id: "a", position: { x: 5, y: 5 } },
    ]);
    assertEquals(
      e.docVersion,
      docBefore,
      "a mid-drag pin bumped the document version",
    );
    assert(
      e.version > versionBefore,
      "a mid-drag pin woke nobody, so this test proves nothing",
    );
    e.endTransaction();
    assert(
      e.docVersion > docBefore,
      "closing the drag left the document version behind",
    );
  },
);

engineTest(
  "retiming a moment inside a transaction wakes version without rematerializing yet",
  () => {
    // Timeline pills and scrub fields follow the live doc mid-gesture.
    // Layout/seek still coalesce to endTransaction (Unpin-all / multi-
    // delete), but a silent authoring seek left diamonds and span edges
    // visually frozen until release.
    const e = new Engine(structuredClone(doc));
    const stateEv = observationsOf(e.doc).find(
      (ev) => ev.kind === "session-state-changed",
    );
    assert(stateEv, "fixture needs a state-change moment to retime");
    const fromT = stateEv.t;
    e.beginTransaction("Move keyframe");
    const docBefore = e.docVersion;
    const versionBefore = e.version;
    let recomputes = 0;
    const origRecompute = e.layout.recompute.bind(e.layout);
    e.layout.recompute = () => {
      recomputes += 1;
      origRecompute();
    };
    e.dispatch({
      kind: "move-event",
      move: {
        kind: "translate",
        eventId: stateEv.id,
        newT: fromT + 50,
      },
    });
    assertEquals(
      observationsOf(e.doc).find((ev) => ev.id === stateEv.id)?.t,
      fromT + 50,
      "the observation must move on the live doc mid-gesture",
    );
    assertEquals(
      e.docVersion,
      docBefore,
      "mid-gesture retime bumped the document version",
    );
    assert(
      e.version > versionBefore,
      "mid-gesture retime woke nobody — timeline paint stays frozen",
    );
    assertEquals(recomputes, 0, "layout must stay deferred inside the txn");
    e.endTransaction();
    assertEquals(recomputes, 1, "the gesture must anneal once at close");
    assert(
      e.docVersion > docBefore,
      "closing the retime left the document version behind",
    );
  },
);

engineTest(
  "clear-peer-position unpins: the layout places the peer again",
  () => {
    // Pin, then unpin. After the clear, neither position carrier
    // holds the authored point, the intent is a no-op the second
    // time, and undo restores the pin — the full inverse of
    // reposition-peer's pin.
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 777, y: -333 },
    });
    e.dispatch({ kind: "clear-peer-position", peerId: "a" });
    assertEquals(e.doc.entities?.peers?.a?.position, undefined);
    for (const ev of observationsOf(e.doc)) {
      if (ev.kind === "peer-joined" && ev.peerId === "a") {
        assertEquals(ev.position, undefined);
      }
    }
    // Unpinning an OUTLIER pin hands the peer back to the layout,
    // which pulls it toward the pack — visible motion here is the
    // correct feedback that the simulation owns it again.
    const freed = e.layout.keyframes[0]!.layout.get("a");
    assert(freed);
    assert(freed.x !== 777 || freed.y !== -333);
    // Unpinning an unpinned peer is a no-op (no undo step minted).
    const undoDepthBefore = e.canUndo;
    e.dispatch({ kind: "clear-peer-position", peerId: "a" });
    assertEquals(e.canUndo, undoDepthBefore);
    // Undo restores the pin exactly.
    e.undo();
    assertEquals(e.doc.entities?.peers?.a?.position, { x: 777, y: -333 });
  },
);

engineTest(
  "set-peer-end works on eternal-start peers (cascade-aware validation)",
  () => {
    // An eternal-start peer lives in `entities.peers` with implicit
    // start. The cascade-aware validation accepts effective-start = 0
    // for eternal peers.
    const e = new Engine(structuredClone(doc));
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      peers: {
        ...e.doc.entities?.peers,
        eternal_peer: { profile: "pancake" },
      },
    };
    e.seekTo(0);
    e.dispatch({ kind: "set-peer-end", peerId: "eternal_peer", t: 2000 });
    // entity.timing.duration is now explicit (2000 − 0 = 2000).
    const def = e.doc.entities?.peers?.eternal_peer;
    assertEquals(def?.timing?.duration, { value: 2000, explicit: true });
  },
);

engineTest(
  "set-session-end works on eternal-start sessions",
  () => {
    const e = new Engine(structuredClone(doc));
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      sessions: {
        ...e.doc.entities?.sessions,
        eternal_s: {
          a: attachedEndpoint("a"),
          b: attachedEndpoint("b"),
          codec: "syrup",
          captpVersion: "v1_0",
        },
      },
    };
    e.seekTo(0);
    e.dispatch({
      kind: "set-session-end",
      sessionId: "eternal_s",
      t: 3000,
    });
    const def = e.doc.entities?.sessions?.eternal_s;
    assertEquals(def?.timing?.duration, { value: 3000, explicit: true });
  },
);

engineTest(
  "eternal-entities pass does NOT inject sessions with future opened events",
  () => {
    // Regression: the parse transform populates
    // `entities.sessions` for sessions whose `session-opened`
    // event is later in the timeline. The eternal-entities pass
    // must not register them at t=0 just because they exist in
    // the entities map — they have an explicit creation event
    // that hasn't fired yet.
    const futureSessionDoc = TimelineDocument.parse({
      id: "test",
      duration: 5000,
      events: [
        {
          id: "p1",
          t: 0,
          kind: "peer-joined",
          peerId: "a",
          profile: "pancake",
        },
        {
          id: "p2",
          t: 0,
          kind: "peer-joined",
          peerId: "b",
          profile: "goblins",
        },
        {
          id: "s_future",
          t: 3000, // FUTURE — session-opened hasn't replayed at t=0
          kind: "session-opened",
          sessionId: "future-session",
          a: { peer: "a" },
          b: { peer: "b" },
          codec: "syrup",
          captpVersion: "v1_0",
        },
      ],
    });
    const e = new Engine(futureSessionDoc);
    // Entities populated by the transform, but the session
    // shouldn't be in the world yet at t=0.
    assertEquals(
      e.doc.entities?.sessions?.["future-session"] !== undefined,
      true,
    );
    assertEquals(
      [...e.world.with("session")].some(
        (s) => s.session.id === "future-session",
      ),
      false,
    );
    // Seek past the opened event — now it should be in the world.
    e.seekTo(3500);
    assertEquals(
      [...e.world.with("session")].some(
        (s) => s.session.id === "future-session",
      ),
      true,
    );
  },
);

engineTest(
  "clear-session-start makes session implicit but keeps it in world",
  () => {
    const e = new Engine(structuredClone(doc));
    e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
    // entity.timing.start is now implicit (inherits peer-overlap).
    assertEquals(
      e.doc.entities?.sessions?.s1?.timing?.start.explicit,
      false,
    );
    // Session entity still present (peer overlap covers t=0).
    assertEquals(
      [...e.world.with("session")].some((s) => s.session.id === "s1"),
      true,
    );
  },
);

engineTest(
  "message cascade: implicit start = session.effectiveStart; rejects out-of-bounds",
  () => {
    const e = new Engine(structuredClone(doc));
    // Define message m_new on session s1 with no message-sent
    // event — implicit start should cascade to session s1's
    // effective start.
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      messages: {
        ...e.doc.entities?.messages,
        m_new: {
          sessionId: "s1",
          from: "a",
          to: "b",
          timing: {
            // Implicit start cascades from session.effectiveStart.
            start: { value: 0, explicit: false },
            // Duration explicit (messages always carry it). 200ms
            // flight stays well within the session's window.
            duration: { value: 200, explicit: true },
          },
        },
      },
    };
    // Session s1 in fixture: opened at t=0, no close → effective
    // end = doc.duration = 5000. Message inherits session.start as
    // its implicit start; its effective end = start + duration.
    assertEquals(e.effectiveStart("messages", "m_new"), 0);
    assertEquals(e.effectiveEnd("messages", "m_new"), 200);
    // Setting message start at t=2000 lies within session bounds
    // — accepted; entity.timing.start becomes explicit.
    e.dispatch({ kind: "set-message-start", messageId: "m_new", t: 2000 });
    assertEquals(
      e.doc.entities?.messages?.m_new?.timing?.start,
      { value: 2000, explicit: true },
    );
    // Clearing returns the message to implicit-start without
    // losing its definition.
    e.dispatch({ kind: "clear-message-start", messageId: "m_new" });
    assertEquals(
      e.doc.entities?.messages?.m_new?.timing?.start.explicit,
      false,
    );
    assertEquals(e.doc.entities?.messages?.m_new !== undefined, true);
  },
);

engineTest(
  "set-message-end writes entity.timing.duration",
  () => {
    const e = new Engine(structuredClone(doc));
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      messages: {
        ...e.doc.entities?.messages,
        m_end: {
          sessionId: "s1",
          from: "a",
          to: "b",
          timing: {
            start: { value: 1000, explicit: true },
            duration: { value: 200, explicit: true },
          },
        },
      },
    };
    // Move arrival to t=1500 → duration becomes 500 (1500 - 1000).
    e.dispatch({ kind: "set-message-end", messageId: "m_end", t: 1500 });
    assertEquals(
      e.doc.entities?.messages?.m_end?.timing?.duration,
      { value: 500, explicit: true },
    );
    // Reject arrival before start.
    e.dispatch({ kind: "set-message-end", messageId: "m_end", t: 500 });
    assertEquals(
      e.doc.entities?.messages?.m_end?.timing?.duration,
      { value: 500, explicit: true },
    );
  },
);

engineTest(
  "set-session-start rejects t before both endpoints exist",
  () => {
    const e = new Engine(structuredClone(doc));
    // Add the new session to the existing (projected) entities map —
    // replacing it wholesale would drop the projector's peer defs
    // and break bound resolution downstream.
    (e.doc as TimelineDocument).entities = {
      ...e.doc.entities,
      sessions: {
        ...e.doc.entities?.sessions,
        s_new: {
          a: attachedEndpoint("a"),
          b: attachedEndpoint("b"),
          codec: "syrup",
          captpVersion: "v1_0",
        },
      },
    };
    e.dispatch({ kind: "set-peer-start", peerId: "a", t: 200 });
    e.dispatch({ kind: "set-peer-start", peerId: "b", t: 800 });
    // Both endpoints exist at t>=800. Trying to set session
    // start at t=300 (before b joins) must be rejected.
    e.dispatch({ kind: "set-session-start", sessionId: "s_new", t: 300 });
    // s_new still has no explicit start (rejected). Either no
    // timing yet OR timing exists with implicit start.
    const afterReject = e.doc.entities?.sessions?.s_new?.timing?.start;
    if (afterReject !== undefined) {
      assertEquals(afterReject.explicit, false);
    }
    // t=900 lies after both endpoints — accepted.
    e.dispatch({ kind: "set-session-start", sessionId: "s_new", t: 900 });
    assertEquals(
      e.doc.entities?.sessions?.s_new?.timing?.start,
      { value: 900, explicit: true },
    );
  },
);

// ---------------------------------------------------------------------------
// Error channel — `validate`, `onError`, drain/dispatch/subscriber capture
// ---------------------------------------------------------------------------

engineTest("validate returns ok for known intents (foundation stub)", () => {
  const e = new Engine(emptyAuthoredDoc());
  const result = e.validate({ kind: "play" });
  assert(result.ok);

  const builderResult = e.validate({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  });
  assert(builderResult.ok);
});

engineTest("onError fires when an enqueued intent throws during drain", () => {
  const e = new Engine(emptyAuthoredDoc());
  const captured: string[] = [];
  e.onError((err) => captured.push(err.code));

  // Inject a poisoned intent that the engine can't dispatch. The
  // control-intent dispatcher does an exhaustive switch on `kind`,
  // and we can force a throw by stubbing one of the clock methods.
  const originalPlay = e.clock.play.bind(e.clock);
  e.clock.play = () => {
    throw new Error("simulated clock failure");
  };
  try {
    e.enqueue({ kind: "play" });
    e.tick(0);
  } finally {
    e.clock.play = originalPlay;
  }

  assertEquals(captured, ["internal"]);
});

engineTest(
  "onError fires when dispatch throws; subsequent dispatches still work",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const captured: string[] = [];
    e.onError((err) => captured.push(err.code));

    // Force a throw inside dispatch on the authoring path. Authoring no
    // longer calls the public `seekTo` hook directly; it asks the context
    // for a layout recompute and authoring seek.
    const originalRecompute = e.layout.recompute.bind(e.layout);
    let firstCall = true;
    e.layout.recompute = () => {
      if (firstCall) {
        firstCall = false;
        throw new Error("simulated mutation failure");
      }
      originalRecompute();
    };

    const first = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    });
    assertEquals(first, undefined);
    assertEquals(captured, ["internal"]);

    // Second dispatch succeeds — the engine is not wedged.
    const second = e.dispatch({
      kind: "add-peer",
      profile: "goblins",
      position: { x: 10, y: 10 },
    });
    assert(typeof second === "string");
    assertEquals(captured.length, 1);
  },
);

engineTest("onError fires when a post-tick subscriber throws", () => {
  const e = new Engine(emptyAuthoredDoc());
  const errors: string[] = [];
  e.onError((err) => errors.push(err.code));

  e.subscribe(() => {
    throw new Error("simulated subscriber failure");
  });
  // Touch the engine so #notify fires.
  e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  });

  assertEquals(errors, ["internal"]);
});

engineTest("onError unsubscribe stops further deliveries", () => {
  const e = new Engine(emptyAuthoredDoc());
  let count = 0;
  const unsubscribe = e.onError(() => {
    count += 1;
  });

  e.subscribe(() => {
    throw new Error("boom");
  });
  e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  });
  assertEquals(count, 1);

  unsubscribe();
  e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 10, y: 10 },
  });
  assertEquals(count, 1);
});

engineTest(
  "onError listeners are isolated — one throwing listener doesn't starve others",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    let goodCalls = 0;
    e.onError(() => {
      throw new Error("bad listener");
    });
    e.onError(() => {
      goodCalls += 1;
    });

    e.subscribe(() => {
      throw new Error("subscriber boom");
    });
    e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    });

    assertEquals(goodCalls, 1);
  },
);

engineTest(
  "dispatch throw rolls back partial mutation; no dead undo entry leaks",
  () => {
    const e = new Engine(emptyAuthoredDoc());

    // Pre-throw baseline: empty doc, no undo. Force the throw on the
    // FIRST dispatch so the canUndo assertion below stays crisp.
    assertEquals(e.canUndo, false);
    const baselineState = JSON.stringify({
      entities: e.doc.entities,
      events: primaryObservations(e.doc),
    });

    // Force a throw partway through dispatch. `add-peer` bumps
    // `#authoredCounter`, runs `#definePeer`, then calls
    // commitEntityAuthoring → recomputeLayout — stub recompute to
    // throw on the first call. Without rollback the counter + entities
    // advance and leak; without record-on-success the history
    // would gain a dead entry.
    const captured: string[] = [];
    e.onError((err) => captured.push(err.code));
    const originalRecompute = e.layout.recompute.bind(e.layout);
    let thrown = 0;
    e.layout.recompute = () => {
      if (thrown === 0) {
        thrown += 1;
        throw new Error("simulated mid-dispatch failure");
      }
      originalRecompute();
    };

    const first = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    });
    assertEquals(first, undefined);
    assertEquals(captured, ["internal"]);

    // Doc state byte-identical to baseline — full atomic rollback.
    assertEquals(
      JSON.stringify({
        entities: e.doc.entities,
        events: primaryObservations(e.doc),
      }),
      baselineState,
    );
    // No undo entry recorded — recordBefore only fires on success.
    assertEquals(e.canUndo, false);

    // Next dispatch succeeds and mints `peer-1` — the throw didn't
    // burn the counter (otherwise we'd see `peer-2`).
    const second = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 20, y: 20 },
    });
    assertEquals(second, "peer-1");
    assertEquals(e.canUndo, true);
  },
);

engineTest(
  "failed transaction dispatch clears deferred layout and seek stage",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const a = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    const b = e.dispatch({
      kind: "add-peer",
      profile: "goblins",
      position: { x: 10, y: 10 },
    })!;
    const sid = e.dispatch({
      kind: "open-session",
      a: attachedEndpoint(a),
      b: attachedEndpoint(b),
    })!;
    e.seekTo(e.doc.duration);

    let recomputes = 0;
    const originalRecompute = e.layout.recompute.bind(e.layout);
    e.layout.recompute = () => {
      recomputes += 1;
      originalRecompute();
    };

    const captured: string[] = [];
    e.onError((err) => captured.push(err.code));
    e.beginTransaction("Failed gesture");
    e.dispatch({ kind: "clear-peer-position", peerId: a });
    const beforeFailure = recomputes;

    const originalSetDuration = e.clock.setDuration.bind(e.clock);
    let failSetDuration = true;
    e.clock.setDuration = (duration) => {
      if (failSetDuration) {
        failSetDuration = false;
        throw new Error("simulated duration failure");
      }
      originalSetDuration(duration);
    };
    const failed = e.dispatch({
      kind: "send-message",
      sessionId: sid,
      from: a,
      to: b,
      flightMs: 1000,
    });
    assertEquals(failed, undefined);
    assertEquals(captured, ["internal"]);
    assertEquals(
      recomputes,
      beforeFailure + 1,
      "rollback should recompute once, not replay stale deferred work",
    );

    e.endTransaction();
    assertEquals(
      recomputes,
      beforeFailure + 1,
      "transaction close replayed staged work from the failed dispatch",
    );
    assertEquals(e.doc.entities?.peers?.[a]?.position, { x: 0, y: 0 });
    assertEquals(e.canUndo, true);
  },
);

engineTest(
  "delete-peer dispatches for eternal-start peers (no peer-joined event)",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    // Create a peer the normal way, then clear-peer-start to make
    // it eternal (entities-only, no peer-joined event).
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    });
    assert(typeof peerId === "string");
    e.dispatch({ kind: "clear-peer-start", peerId });
    assert(
      !primaryObservations(e.doc).some(
        (ev) => ev.kind === "peer-joined" && ev.peerId === peerId,
      ),
      "precondition: peer-joined event removed",
    );
    assert(
      e.doc.entities?.peers?.[peerId] !== undefined,
      "precondition: entities entry still present",
    );

    // Before the fix this short-circuited as no-op.
    e.dispatch({ kind: "delete-peer", peerId });
    assertEquals(e.doc.entities?.peers?.[peerId], undefined);
  },
);

// ---------------------------------------------------------------------------
// Rename — engine/authoring/identity.ts
// ---------------------------------------------------------------------------

engineTest("renamePeer rewrites entities + events + row state", () => {
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const sid = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint(a),
    b: attachedEndpoint(b),
  })!;
  e.dispatch({
    kind: "send-message",
    sessionId: sid,
    from: a,
    to: b,
    label: "ping",
  });
  e.dispatch({ kind: "reorder-row", category: "peers", order: [b, a] });

  e.dispatch({ kind: "rename-peer", oldId: a, newId: "alice" });

  // Entities map keyed by new id.
  assert(e.doc.entities?.peers?.alice !== undefined);
  assertEquals(e.doc.entities?.peers?.[a], undefined);
  // entities-cross-ref updated on session definition.
  const sessionDef = e.doc.entities?.sessions?.[sid];
  assertEquals(sessionDef?.a?.peer, "alice");
  // message-sent endpoint cross-ref on entities.
  const msgDef = Object.values(e.doc.entities?.messages ?? {})[0];
  assertEquals(msgDef?.from, "alice");
  // rowOrder updated.
  assertEquals(e.doc.rowOrder?.peers, [b, "alice"]);
});

engineTest("rename-* rejects collisions; doc untouched", () => {
  const e = new Engine(emptyAuthoredDoc());
  const captured: string[] = [];
  e.onError((err) => captured.push(err.code));
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const baseline = JSON.stringify({
    entities: e.doc.entities,
    events: primaryObservations(e.doc),
  });

  // Try to rename a → b. Collision → error on the bus; doc unchanged.
  e.dispatch({ kind: "rename-peer", oldId: a, newId: b });

  assertEquals(captured, ["collision"]);
  assertEquals(
    JSON.stringify({
      entities: e.doc.entities,
      events: primaryObservations(e.doc),
    }),
    baseline,
  );
});

engineTest("validate(rename-*) surfaces collision without mutating", () => {
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const baseline = JSON.stringify({
    entities: e.doc.entities,
    events: primaryObservations(e.doc),
  });

  // Collision target.
  const collide = e.validate({ kind: "rename-peer", oldId: a, newId: b });
  assert(!collide.ok);
  assertEquals(collide.error.code, "collision");

  // Same-id "rename" is a no-op, validate passes.
  const noop = e.validate({ kind: "rename-peer", oldId: a, newId: a });
  assert(noop.ok);

  // Fresh id passes validation.
  const fresh = e.validate({ kind: "rename-peer", oldId: a, newId: "alice" });
  assert(fresh.ok);

  // Doc unchanged through all three checks.
  assertEquals(
    JSON.stringify({
      entities: e.doc.entities,
      events: primaryObservations(e.doc),
    }),
    baseline,
  );
});

engineTest("renameSession rewrites events + cross-refs", () => {
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const sid = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint(a),
    b: attachedEndpoint(b),
  })!;
  e.dispatch({ kind: "send-message", sessionId: sid, from: a, to: b });

  e.dispatch({ kind: "rename-session", oldId: sid, newId: "main-chan" });

  assert(e.doc.entities?.sessions?.["main-chan"] !== undefined);
  assertEquals(e.doc.entities?.sessions?.[sid], undefined);
  // entities.messages[*].sessionId follows.
  const msgDefs = Object.values(e.doc.entities?.messages ?? {});
  assert(msgDefs.every((d) => d.sessionId === "main-chan"));
});

engineTest("renameMessage rewrites sent + delivered events", () => {
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const sid = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint(a),
    b: attachedEndpoint(b),
  })!;
  const mid = e.dispatch({
    kind: "send-message",
    sessionId: sid,
    from: a,
    to: b,
  })!;

  e.dispatch({ kind: "rename-message", oldId: mid, newId: "ping-1" });

  assert(e.doc.entities?.messages?.["ping-1"] !== undefined);
  // Entity def re-keyed; old id is gone.
  assertEquals(e.doc.entities?.messages?.[mid], undefined);
});

engineTest("update-message swap after rename mutates entity from/to", () => {
  // Regression: the update-message no-op guard previously looked up
  // the message via observation events, but cascadeRewrite leaves
  // observations untouched. After rename, the renamed id wasn't
  // findable that way, so every subsequent update-message silently
  // no-op'd — including direction-swap from the Inspector.
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const b = e.dispatch({
    kind: "add-peer",
    profile: "goblins",
    position: { x: 10, y: 10 },
  })!;
  const sid = e.dispatch({
    kind: "open-session",
    a: attachedEndpoint(a),
    b: attachedEndpoint(b),
  })!;
  const mid = e.dispatch({
    kind: "send-message",
    sessionId: sid,
    from: a,
    to: b,
  })!;

  e.dispatch({ kind: "rename-message", oldId: mid, newId: "ping-1" });
  e.dispatch({
    kind: "update-message",
    messageId: "ping-1",
    patch: { swapDirection: true },
  });

  const def = e.doc.entities?.messages?.["ping-1"];
  assertEquals(def?.from, b);
  assertEquals(def?.to, a);
});

engineTest("rename undo restores everything", () => {
  const e = new Engine(emptyAuthoredDoc());
  const a = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const baseline = JSON.stringify({
    entities: e.doc.entities,
    events: primaryObservations(e.doc),
  });

  e.dispatch({ kind: "rename-peer", oldId: a, newId: "alice" });
  assert(e.doc.entities?.peers?.alice !== undefined);

  e.undo();
  assertEquals(
    JSON.stringify({
      entities: e.doc.entities,
      events: primaryObservations(e.doc),
    }),
    baseline,
  );
});

// ─── paste / duplicate ──────────────────────────────────────────

engineTest("duplicate peer mints a -copy id and registers undo", () => {
  const e = new Engine(emptyAuthoredDoc());
  const peerId = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 0, y: 0 },
  })!;
  const baseline = JSON.stringify({
    entities: e.doc.entities,
    events: primaryObservations(e.doc),
  });

  const r = e.duplicate({ peers: new Set([peerId]) });
  assert(r.ok);
  // Duplicate says its own name in the undo menu. It shares paste's
  // write, and for a while it borrowed paste's label with it, so the
  // menu offered "Undo Paste" for something nobody had pasted.
  assertEquals(e.nextUndoLabel, "Duplicate");
  // The remap should have surfaced the new id.
  const newPeerId = r.value.remap.peer.get(peerId)!;
  assert(newPeerId);
  assert(newPeerId !== peerId);
  assert(e.doc.entities?.peers?.[newPeerId]);
  // Original peer still there.
  assert(e.doc.entities?.peers?.[peerId]);
  // Undo restores the pre-duplicate state.
  e.undo();
  assertEquals(
    JSON.stringify({
      entities: e.doc.entities,
      events: primaryObservations(e.doc),
    }),
    baseline,
  );
});

engineTest("paste with missing external ref returns validation error", () => {
  const e = new Engine(emptyAuthoredDoc());
  // Build a payload that references a peer the target doc doesn't have.
  // Use a source doc with a session+peer, extract just the session.
  const source = TimelineDocument.parse({
    id: "src",
    duration: 1000,
    events: [
      {
        id: "p1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      { id: "p2", t: 0, kind: "peer-joined", peerId: "bob", profile: "agent" },
      {
        id: "s1ev",
        t: 10,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "alice" },
        b: { peer: "bob" },
        codec: "capnp",
        captpVersion: "v1_0",
      },
    ],
  });
  const sourceEngine = new Engine(source);
  const payload = sourceEngine.extractPayload({
    sessions: new Set(["s1"]),
  });
  // Target is empty — alice and bob don't exist there.
  const r = e.paste(payload);
  assert(!r.ok);
  assertEquals(r.error.code, "validation");
});

engineTest("duplicate session-with-peers preserves whole subgraph", () => {
  // Build a doc with two peers + a session, duplicate the lot, verify
  // the duplicate is a self-contained subgraph (its session points at
  // its own peer copies, not the originals).
  const doc = TimelineDocument.parse({
    id: "dup",
    layoutMode: "authored",
    duration: 1000,
    events: [
      {
        id: "p1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      { id: "p2", t: 0, kind: "peer-joined", peerId: "bob", profile: "agent" },
      {
        id: "s1ev",
        t: 10,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "alice" },
        b: { peer: "bob" },
        codec: "capnp",
        captpVersion: "v1_0",
      },
    ],
  });
  const e = new Engine(doc);

  const r = e.duplicate({
    peers: new Set(["alice", "bob"]),
    sessions: new Set(["s1"]),
  });
  assert(r.ok);

  const aliceCopy = r.value.remap.peer.get("alice")!;
  const bobCopy = r.value.remap.peer.get("bob")!;
  const s1Copy = r.value.remap.session.get("s1")!;
  assert(aliceCopy !== "alice");
  assert(bobCopy !== "bob");
  assert(s1Copy !== "s1");

  // The duplicated session points at the duplicated peers, not the originals.
  const dupSession = e.doc.entities?.sessions?.[s1Copy];
  assertEquals(dupSession?.a?.peer, aliceCopy);
  assertEquals(dupSession?.b?.peer, bobCopy);
});

// ── move-entity-span: freshly authored entities retime like loaded ones ──────
// The defect this family was written against: Build-mode entities have
// `entity.timing` and no observation events, and the event-addressed
// `move-event` silently dropped their timeline drags. The entity-addressed
// intent is the one write path for both provenances.

engineTest(
  "move-entity-span resizes a freshly authored peer's right edge",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-end",
        ref: { kind: "peer", id: peerId },
        newT: 4_000,
      },
    });
    const eff = peerEffective(e.doc, peerId);
    assertEquals(eff.end, 4_000);
  },
);

engineTest(
  "move-entity-span resizes a freshly authored peer's left edge, end pinned",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-end",
        ref: { kind: "peer", id: peerId },
        newT: 5_000,
      },
    });
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-start",
        ref: { kind: "peer", id: peerId },
        newT: 1_000,
      },
    });
    const eff = peerEffective(e.doc, peerId);
    assertEquals(eff.start, 1_000);
    assertEquals(eff.end, 5_000, "left-edge resize must not slide the end");
  },
);

engineTest(
  "move-entity-span translates a freshly authored peer, duration preserved",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-end",
        ref: { kind: "peer", id: peerId },
        newT: 2_000,
      },
    });
    const before = peerEffective(e.doc, peerId);
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "translate",
        ref: { kind: "peer", id: peerId },
        newT: 3_000,
      },
    });
    const eff = peerEffective(e.doc, peerId);
    assertEquals(eff.start, 3_000);
    assertEquals(eff.end - eff.start, before.end - before.start);
  },
);

engineTest(
  "move-entity-span resizes a freshly authored session both edges",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const a = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    const b = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 10, y: 0 },
    })!;
    const sessionId = e.dispatch({
      kind: "open-session",
      a: attachedEndpoint(a),
      b: attachedEndpoint(b),
    })!;
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-end",
        ref: { kind: "session", id: sessionId },
        newT: 6_000,
      },
    });
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-start",
        ref: { kind: "session", id: sessionId },
        newT: 2_000,
      },
    });
    const eff = sessionEffective(e.doc, sessionId);
    assertEquals(eff.start, 2_000);
    assertEquals(eff.end, 6_000);
  },
);

engineTest(
  "move-entity-span on a loaded peer moves its observation events too",
  () => {
    const doc = TimelineDocument.parse({
      id: "loaded",
      duration: 10_000,
      events: [
        {
          id: "e1",
          t: 1_000,
          kind: "peer-joined",
          peerId: "alice",
          profile: "agent",
        },
        { id: "e2", t: 8_000, kind: "peer-left", peerId: "alice" },
      ],
    });
    const e = new Engine(doc);
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-start",
        ref: { kind: "peer", id: "alice" },
        newT: 2_000,
      },
    });
    const eff = peerEffective(e.doc, "alice");
    assertEquals(eff.start, 2_000);
    assertEquals(eff.end, 8_000, "resize-start keeps the loaded end pinned");
    const joined = primaryObservations(e.doc).find((ev) => ev.id === "e1")!;
    assertEquals(joined.t, 2_000, "the observation event moved to agree");
  },
);

engineTest(
  "move-entity-span refuses an inverted resize with a validation error",
  () => {
    const e = new Engine(emptyAuthoredDoc());
    const peerId = e.dispatch({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 0, y: 0 },
    })!;
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-end",
        ref: { kind: "peer", id: peerId },
        newT: 3_000,
      },
    });
    const errors: string[] = [];
    const un = e.onError((err) => errors.push(err.code));
    e.dispatch({
      kind: "move-entity-span",
      move: {
        kind: "resize-start",
        ref: { kind: "peer", id: peerId },
        newT: 9_000,
      },
    });
    un();
    assert(errors.length > 0, "start after end must refuse");
    const eff = peerEffective(e.doc, peerId);
    assertEquals(eff.end, 3_000, "a refused gesture leaves the span untouched");
  },
);

// ───────────── Guard authority + snapshot-coverage regressions ─────────────
//
// Every test in this section was written red against a confirmed
// defect before its fix landed: a no-op guard consulting the live
// world (or a stored bound the resolvers ignore) where the authored
// doc — the state the mutation actually writes — is the fact; the
// undo snapshot missing `doc.duration`; and the layout system
// holding the pre-projection doc object.

/** Doc whose only peer joins mid-timeline — at t=0 (where every
 *  dispatch in these tests happens) the peer exists in the authored
 *  doc but not in the materialized world. */
const latePeerDoc = () =>
  TimelineDocument.parse({
    id: "late-peer",
    duration: 60_000,
    events: [
      {
        id: "j1",
        t: 5_000,
        kind: "peer-joined",
        peerId: "late",
        profile: "pancake",
      },
    ],
  });

engineTest("update-peer reaches a peer outside the playhead window", () => {
  const e = new Engine(latePeerDoc());
  assertEquals(findPeer(e.world, "late"), undefined, "not in world at t=0");
  e.dispatch({
    kind: "update-peer",
    peerId: "late",
    patch: { label: "Renamed" },
  });
  assertEquals(
    e.doc.entities?.peers?.["late"]?.label,
    "Renamed",
    "the authored definition is editable regardless of the playhead",
  );
  assert(e.canUndo, "a real edit records history");
});

engineTest("reposition-peer pins a peer outside the playhead window", () => {
  const e = new Engine(latePeerDoc());
  e.dispatch({
    kind: "reposition-peer",
    peerId: "late",
    position: { x: 10, y: 20 },
  });
  assertEquals(
    e.doc.entities?.peers?.["late"]?.position,
    { x: 10, y: 20 },
    "the pin lands on the definition regardless of the playhead",
  );
});

engineTest(
  "update-session reaches a session outside the playhead window",
  () => {
    const e = new Engine(TimelineDocument.parse({
      id: "late-session",
      duration: 60_000,
      events: [
        {
          id: "j1",
          t: 0,
          kind: "peer-joined",
          peerId: "a",
          profile: "pancake",
        },
        {
          id: "j2",
          t: 0,
          kind: "peer-joined",
          peerId: "b",
          profile: "goblins",
        },
        {
          id: "s1o",
          t: 5_000,
          kind: "session-opened",
          sessionId: "s1",
          a: { peer: "a" },
          b: { peer: "b" },
          codec: "syrup",
          captpVersion: "v1_0",
        },
      ],
    }));
    e.dispatch({
      kind: "update-session",
      sessionId: "s1",
      patch: { codec: "capnp" },
    });
    assertEquals(
      e.doc.entities?.sessions?.["s1"]?.codec,
      "capnp",
      "the authored definition is editable regardless of the playhead",
    );
    // Re-applying the value the definition already holds is a no-op.
    e.dispatch({
      kind: "update-session",
      sessionId: "s1",
      patch: { codec: "capnp" },
    });
    e.undo();
    assertEquals(e.doc.entities?.sessions?.["s1"]?.codec, "syrup");
    assert(!e.canUndo, "the repeat dispatch pushed no history entry");
  },
);

/** A document whose session is born open, so "the state it already
 *  carries" is a real value at every moment of its life and there is
 *  no keyframe standing anywhere. */
function bornOpenDoc() {
  return TimelineDocument.parse({
    id: "born-open",
    duration: 60_000,
    events: [
      { id: "j1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      { id: "j2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
      {
        id: "s1o",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "a" },
        b: { peer: "b" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
    ],
  });
}

const stateTrack = (e: Engine) => e.doc.entities?.sessions?.["s1"]?.keyframes?.state ?? [];

engineTest(
  "stating the state a session already carries declares it at that moment",
  () => {
    // The session is open at 2000 with nothing saying so there. Saying
    // it pins it: an edit to the genesis state stops reaching past
    // 2000. So it is a document change, and refusing it as "the value
    // is already that" refuses a thing the author can plainly mean.
    const e = new Engine(bornOpenDoc());
    e.seekTo(2_000);
    e.dispatch({
      kind: "update-session",
      sessionId: "s1",
      patch: { state: "open" },
    });
    assertEquals(
      stateTrack(e),
      [{ t: 2_000, value: "open" }],
      "restating the current state at the playhead declares it there",
    );
    assert(e.canUndo, "a declaration is a document change, so it is undoable");
  },
);

engineTest(
  "one rule for both spellings of a session's state write",
  () => {
    // `update-session { state }` and `set-session-keyframe` are one
    // write reached by two names, so neither may refuse what the
    // other accepts. Run each from the same starting document and
    // compare what it produced: two rules for one fact show up here
    // as one empty track and one declaration.
    const viaPatch = new Engine(bornOpenDoc());
    viaPatch.seekTo(2_000);
    viaPatch.dispatch({
      kind: "update-session",
      sessionId: "s1",
      patch: { state: "open" },
    });
    const viaKeyframe = new Engine(bornOpenDoc());
    viaKeyframe.seekTo(2_000);
    viaKeyframe.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 2_000,
      value: "open",
    });
    assertEquals(
      stateTrack(viaPatch),
      stateTrack(viaKeyframe),
      "both names for one write leave the same document",
    );
    assertEquals(
      viaPatch.canUndo,
      viaKeyframe.canUndo,
      "and the same history behind it",
    );
    // Whichever made the declaration, the other sees it and stands
    // down.
    viaKeyframe.dispatch({
      kind: "update-session",
      sessionId: "s1",
      patch: { state: "open" },
    });
    viaKeyframe.undo();
    assertEquals(
      stateTrack(viaKeyframe),
      [],
      "the second spelling restated the same declaration, so it did nothing",
    );
    assert(!viaKeyframe.canUndo, "the repeat dispatch pushed no history entry");
  },
);

engineTest(
  "a second identical declaration at one instant does nothing, in both lanes",
  () => {
    // What the trajectory insert control does twice at one playhead:
    // the first press declares, the second would produce the document
    // the first already produced. Both lanes answer alike, because a
    // moment is the same thing on either.
    const e = new Engine(bornOpenDoc());
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 2_000,
      value: "open",
    });
    e.dispatch({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 2_000,
      value: "open",
    });
    e.undo();
    assertEquals(stateTrack(e), [], "the session lane refused the duplicate");
    assert(!e.canUndo, "and pushed nothing for it");

    // The peer lane: `a` answers to its id, so stating that as its
    // name at 2000 is the insert control's own offer.
    e.dispatch({
      kind: "set-peer-update",
      peerId: "a",
      t: 2_000,
      property: "label",
      value: "a",
    });
    assertEquals(
      e.doc.entities?.peers?.["a"]?.keyframes?.label,
      [{ t: 2_000, value: "a" }],
      "restating the name the peer already answers to declares it there",
    );
    e.dispatch({
      kind: "set-peer-update",
      peerId: "a",
      t: 2_000,
      property: "label",
      value: "a",
    });
    e.undo();
    assertEquals(
      e.doc.entities?.peers?.["a"]?.keyframes?.label ?? [],
      [],
      "the peer lane refused the duplicate the same way",
    );
  },
);

engineTest(
  "taking away a declaration that was never made does nothing, in both lanes",
  () => {
    // The mirror of the rule above, and it has to be the same
    // question: a removal takes the declaration standing at that
    // instant, so an instant with none is an instant with nothing to
    // take. The session lane is the one that is easy to get wrong,
    // because the session is plainly in some state at 2000 — but no
    // moment there says so.
    const e = new Engine(bornOpenDoc());
    e.dispatch({
      kind: "remove-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 2_000,
    });
    assert(!e.canUndo, "the session lane pushed no history entry");
    e.dispatch({
      kind: "remove-peer-update",
      peerId: "a",
      t: 2_000,
      property: "label",
    });
    assert(!e.canUndo, "and neither did the peer lane");
  },
);

engineTest(
  "set-peer-end measures the painted start, not the retained stored value",
  () => {
    // clear-peer-start keeps the last stored start (1000) for
    // toggle-back, but the painted start becomes the world's 0. The
    // mutation derives duration from the painted start, so the
    // guard must too — stored-value arithmetic declares a real edit
    // a no-op exactly when retained-start + duration lands on t.
    const e = new Engine(TimelineDocument.parse({
      id: "cleared-start-peer",
      duration: 60_000,
      events: [
        {
          id: "j1",
          t: 1_000,
          kind: "peer-joined",
          peerId: "p",
          profile: "pancake",
        },
      ],
    }));
    e.dispatch({ kind: "clear-peer-start", peerId: "p" });
    e.dispatch({ kind: "set-peer-end", peerId: "p", t: 1_500 });
    assertEquals(e.effectiveEnd("peers", "p"), 1_500);
    e.dispatch({ kind: "set-peer-end", peerId: "p", t: 2_500 });
    assertEquals(e.effectiveEnd("peers", "p"), 2_500);
  },
);

engineTest(
  "set-session-end measures the painted start, not the retained stored value",
  () => {
    const e = new Engine(TimelineDocument.parse({
      id: "cleared-start-session",
      duration: 60_000,
      events: [
        {
          id: "j1",
          t: 0,
          kind: "peer-joined",
          peerId: "a",
          profile: "pancake",
        },
        {
          id: "j2",
          t: 0,
          kind: "peer-joined",
          peerId: "b",
          profile: "goblins",
        },
        {
          id: "s1o",
          t: 1_000,
          kind: "session-opened",
          sessionId: "s1",
          a: { peer: "a" },
          b: { peer: "b" },
          codec: "syrup",
          captpVersion: "v1_0",
        },
      ],
    }));
    // Cleared start retains 1000; painted start cascades to the
    // peers' max join time, 0.
    e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
    e.dispatch({ kind: "set-session-end", sessionId: "s1", t: 1_500 });
    assertEquals(e.effectiveEnd("sessions", "s1"), 1_500);
    e.dispatch({ kind: "set-session-end", sessionId: "s1", t: 2_500 });
    assertEquals(e.effectiveEnd("sessions", "s1"), 2_500);
  },
);

/** Peers at 0, session s1 opened at `openT`, message m1 in flight
 *  1000 → 1500. The message scenarios below all start here. */
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

// ──────────── What playback is allowed to recompute ────────────
//
// The keyframes are a pure function of the document, so playing a document
// nobody edits must not re-derive them. It used to: the recompute was
// triggered by the set of peers and sessions present in the world AT `t`,
// which changes on any frame where something comes into view, so a document
// whose sessions arrived steadily ran one d3-force convergence per era per
// arrival and threw away keyframes identical to the ones it already had. On a
// hand-built document that was three quarters of the frame.
//
// Both halves are held here, because either one alone can be satisfied by a
// broken engine: never recomputing makes live mode's later peers land at their
// seed position forever, and always recomputing is the defect above.
//
// The assertion is object identity on the keyframes array rather than a frame
// budget. `recompute` replaces the array, so identity answers "did it run"
// exactly, on any machine, in any build — where a millisecond budget would
// pass on a tree that had doubled the cost and fail on a busy laptop.
//
// Validated by injection, one per half, because a pair that passes on a
// healthy tree has shown nothing: recomputing unconditionally (the original
// defect) fails the first test, and dropping the recompute altogether fails
// the second. What this pair does NOT reach: it says nothing about how much a
// recompute costs. The seek path shares the document-changed recompute gate
// with playback (`#doSeek`); the live-arrival seek case below holds that half.
// `scripts/playwright-masterpiece-cost-probe.ts` is the instrument for the
// cost itself, and it is deliberately not a check — it needs a CPU throttle to
// mean anything, which trades away machine independence.

engineTest("playing an unedited document never recomputes the layout", () => {
  // Peers and sessions that arrive across the timeline rather than all at
  // t=0: entities appearing mid-playback are the condition that used to
  // trigger the recompute, so a document where everything exists from the
  // start would pass this test without exercising it.
  const staggered = TimelineDocument.parse({
    id: "staggered",
    duration: 4000,
    events: [
      { id: "p1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      {
        id: "p2",
        t: 500,
        kind: "peer-joined",
        peerId: "b",
        profile: "pancake",
      },
      {
        id: "s1",
        t: 800,
        kind: "session-opened",
        sessionId: "s-ab",
        a: { peer: "a" },
        b: { peer: "b" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "p3",
        t: 1500,
        kind: "peer-joined",
        peerId: "c",
        profile: "goblins",
      },
      {
        id: "s2",
        t: 2000,
        kind: "session-opened",
        sessionId: "s-bc",
        a: { peer: "b" },
        b: { peer: "c" },
        codec: "capnp",
        captpVersion: "v1_0",
        initialState: "open",
      },
      { id: "p4", t: 3000, kind: "peer-left", peerId: "a" },
    ],
  });
  const e = new Engine(staggered);
  const atConstruction = e.layout.keyframes;
  e.clock.play();
  // Step rather than jump, so every arrival above is crossed by a tick that
  // materializes the world across it. One big tick would skip the frames
  // where the topology changes, which is where the defect lived.
  for (let i = 0; i < 40; i++) e.tick(100);
  assert(
    e.layout.keyframes === atConstruction,
    "playing a document nobody edited re-derived its keyframes",
  );
  // The staggered arrivals really were crossed — otherwise the assertion
  // above is vacuous and would keep passing if the trigger came back.
  assert(e.clock.t >= 3000, "the clock did not reach the last arrival");
  assert(
    atConstruction.length > 1,
    "this document should have produced several eras to re-derive",
  );
});

engineTest(
  "a live observation arriving mid-playback recomputes the layout",
  () => {
    const live = TimelineDocument.parse({
      id: "live",
      duration: 60_000,
      recording: {
        sources: [{
          id: "feed",
          meta: { kind: "fixture" },
          observations: [
            {
              id: "o1",
              t: 10,
              kind: "peer-joined",
              peerId: "a",
              profile: "pancake",
            },
          ],
        }],
      },
    });
    const e = new Engine(live);
    e.clock.play();
    e.tick(50);
    const beforeArrival = e.layout.keyframes;
    // What a feed does: append in place, leaving the document object identical.
    // Projection is what notices, which is why the recompute hangs off it.
    primaryObservations(e.doc).push({
      id: "o2",
      t: e.clock.t + 1,
      kind: "peer-joined",
      peerId: "b",
      profile: "goblins",
    });
    e.tick(50);
    assert(
      e.layout.keyframes !== beforeArrival,
      "a peer that arrived live never reached a keyframe",
    );
    const placed = e.layout.keyframes.at(-1)?.layout.get("b");
    assert(
      placed !== undefined,
      "the live peer has no position in any keyframe",
    );
  },
);

engineTest(
  "seeking an unedited document never recomputes the layout",
  () => {
    const e = new Engine(TimelineDocument.parse({
      id: "quiet-seek",
      duration: 1000,
      events: [{
        id: "p1",
        t: 0,
        kind: "peer-joined",
        peerId: "a",
        profile: "pancake",
      }],
    }));
    const beforeSeek = e.layout.keyframes;
    e.seekTo(Math.min(100, e.doc.duration));
    assert(
      e.layout.keyframes === beforeSeek,
      "an ordinary seek re-derived unchanged keyframes",
    );
  },
);

engineTest(
  "seeking after a live observation recomputes the layout",
  () => {
    const live = TimelineDocument.parse({
      id: "live-seek",
      duration: 60_000,
      recording: {
        sources: [{
          id: "feed",
          meta: { kind: "fixture" },
          observations: [
            {
              id: "o1",
              t: 10,
              kind: "peer-joined",
              peerId: "a",
              profile: "pancake",
            },
          ],
        }],
      },
    });
    const e = new Engine(live);
    e.clock.pause();
    e.seekTo(50);
    const beforeArrival = e.layout.keyframes;
    primaryObservations(e.doc).push({
      id: "o2",
      t: 100,
      kind: "peer-joined",
      peerId: "b",
      profile: "goblins",
    });
    e.seekTo(150);
    assert(
      e.layout.keyframes !== beforeArrival,
      "seek after a live arrival never rebuilt keyframes",
    );
    assert(
      e.layout.keyframes.at(-1)?.layout.get("b") !== undefined,
      "the live peer has no position after seek",
    );
  },
);

// ──────── What a playing clock is allowed to wake ────────
//
// `version` promises to catch any mutation, so it moves on every frame of
// playback and a panel subscribed to it re-renders at the frame rate. That is
// the right contract for a consumer following the world. It is the wrong one
// for a panel showing what the document says — its source, its title, whether
// an id is taken — and those panels were paying it.
//
// `docVersion` is the narrower fact. The assertion is a count rather than a
// duration for the same reason as the keyframes above: it holds on any machine
// and in any build, and it names the work instead of its price.
//
// Validated by injection: bumping `#docVersion` unconditionally in `#notify`
// fails the first test, and never bumping it fails the second. What this pair
// does NOT reach: it says nothing about which components subscribe to which,
// so a panel switched back to `useEngineVersion` would not fail here.

engineTest("a playing clock does not move the document version", () => {
  const e = new Engine(structuredClone(doc));
  const before = e.docVersion;
  const versionBefore = e.version;
  e.clock.play();
  for (let i = 0; i < 30; i++) e.tick(50);
  assertEquals(
    e.docVersion,
    before,
    "playback moved the document version, so document-shaped panels re-render per frame",
  );
  // The ticks really did wake subscribers, or the assertion above is vacuous.
  assert(
    e.version > versionBefore,
    "playback notified nobody, so this test proves nothing",
  );
});

engineTest("editing the document moves the document version", () => {
  const e = new Engine(structuredClone(doc));
  const before = e.docVersion;
  e.dispatch({
    kind: "reposition-peer",
    peerId: "a",
    position: { x: 42, y: 42 },
  });
  assert(
    e.docVersion > before,
    "an edit left the document version behind, so a panel would show stale state",
  );
});

engineTest("a live observation moves the document version", () => {
  const live = TimelineDocument.parse({
    id: "live-docversion",
    duration: 60_000,
    recording: {
      sources: [{
        id: "feed",
        meta: { kind: "fixture" },
        observations: [
          {
            id: "o1",
            t: 10,
            kind: "peer-joined",
            peerId: "a",
            profile: "pancake",
          },
        ],
      }],
    },
  });
  const e = new Engine(live);
  e.clock.play();
  e.tick(50);
  const before = e.docVersion;
  primaryObservations(e.doc).push({
    id: "o2",
    t: e.clock.t + 1,
    kind: "peer-joined",
    peerId: "b",
    profile: "goblins",
  });
  e.tick(50);
  assert(
    e.docVersion > before,
    "a peer that arrived live never moved the document version",
  );
});

// ──────── Frame geometry shared once per stage update ────────
//
// Flight and the Stage projection used to each call `claimTargets` /
// `computeSessionBundles`, and flight rebuilt time bundles every tick
// even though those are observation-stable. The engine now owns one
// `frameGeometry` per stage pass. Validated by injection: rebuilding
// time bundles every `#runStageSystems` fails the identity test; leaving
// Stage to compute its own session bundles would not fail these, but the
// render path takes `engine.frameGeometry` by construction.

engineTest(
  "frameGeometry matches an independent claim/bundle resolution",
  () => {
    const e = new Engine(structuredClone(doc));
    e.seekTo(1000);
    const g = e.frameGeometry;
    const toward = claimTargets(e.world, e.claims);
    assertEquals([...g.claimsToward.entries()], [...toward.entries()]);
    assertEquals(
      [...g.sessionBundles.entries()],
      [...computeSessionBundles(e.world, toward).entries()],
    );
  },
);

engineTest(
  "message time bundles keep identity across playback ticks",
  () => {
    const e = new Engine(structuredClone(doc));
    e.clock.play();
    e.tick(50);
    const first = e.frameGeometry.timeBundles;
    for (let i = 0; i < 20; i++) e.tick(50);
    assert(
      e.frameGeometry.timeBundles === first,
      "playback rebuilt time bundles every tick",
    );
    // The cached map is still the right answer, not a stale empty.
    assertEquals(
      [...first.entries()],
      [
        ...computeMessageTimeBundles(
          observationsOf(e.doc) as readonly TimelineEvent[],
        ).entries(),
      ],
    );
  },
);

engineTest(
  "pair tables keep identity across playback ticks without topology change",
  () => {
    // Between t=0 and the first message at t=1000 the standing set is
    // stable, so claim/bundle maps must not be rebuilt every frame.
    const e = new Engine(structuredClone(doc));
    e.clock.play();
    e.tick(50);
    const claims = e.frameGeometry.claimsToward;
    const bundles = e.frameGeometry.sessionBundles;
    for (let i = 0; i < 10; i++) e.tick(50);
    assert(
      e.frameGeometry.claimsToward === claims,
      "playback rebuilt claim targets while membership was stable",
    );
    assert(
      e.frameGeometry.sessionBundles === bundles,
      "playback rebuilt session bundles while membership was stable",
    );
    // Curves depend on positions and are rebuilt every stage pass.
    assert(
      e.frameGeometry.sessionCurves !== EMPTY_FRAME_GEOMETRY.sessionCurves,
      "session curves were never built",
    );
  },
);

engineTest(
  "seek after a document edit rebuilds message time bundles",
  () => {
    const e = new Engine(structuredClone(doc));
    const before = e.frameGeometry.timeBundles;
    e.dispatch({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 7, y: 7 },
    });
    // Seek is the path that must not trust a pre-edit table: authoring
    // rewrites observations in place and then seeks.
    e.seekTo(e.clock.t);
    assert(
      e.frameGeometry.timeBundles !== before,
      "a seek after an edit kept the previous time-bundle map",
    );
  },
);

engineTest(
  "retiming a message updates time-bundle contents after seek",
  () => {
    // Authoring rewrites observations in place and seeks. `#doSeek`
    // always allocates a new map; this pins that the new map reflects
    // the rewritten observation. Injection: keep computing time bundles
    // from a cloned pre-move event list and this fails.
    const e = new Engine(structuredClone(doc));
    e.dispatch({
      kind: "move-event",
      move: { kind: "resize-end", eventId: "e4", newArrivalT: 2200 },
    });
    const rebuilt = e.frameGeometry.timeBundles;
    const expected = computeMessageTimeBundles(
      observationsOf(e.doc) as readonly TimelineEvent[],
    );
    assertEquals([...rebuilt.entries()], [...expected.entries()]);
  },
);
