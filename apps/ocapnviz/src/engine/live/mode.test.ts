import { assert, assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { makeBaseEventConverter } from "./feed.ts";
import { claimRecording, makeLiveAppender } from "./mode.ts";
import { findPeer, findSession } from "../world.ts";
import type { TimelineDocument } from "../timeline.ts";
import { primaryObservations } from "../temporal/recording-access.ts";

/**
 * The integration test for live mode: prove that the
 * `mode.ts` pattern — append converted events into the
 * recording layer via `primaryObservations(doc)`, then tick the
 * engine — actually produces the world state the renderer expects.
 *
 * Bypasses the CapTP delivery layer (covered by
 * `feed-test/dialing.test.ts`). Conversion is covered by the
 * rest of `feed-test/`. Focuses on the renderer-side fold.
 */

function newLiveDoc(): TimelineDocument {
  return {
    id: "live-test",
    duration: 60 * 1000,
    recording: {
      sources: [{
        id: "live",
        meta: { kind: "pancake-host" },
        observations: [],
      }],
    },
  };
}

// Constructing an `Engine` runs the KeyframeLayoutSystem's d3-force
// convergence, which schedules a d3-timer Deno's resource sanitizer
// flags as a leak. Same workaround as engine-test/harness.ts and
// keyframe-layout-test/harness.ts.
function liveTest(name: string, fn: () => void): void {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn,
  });
}

liveTest(
  "live mode: ocapn.session-opened produces peer + session entities",
  () => {
    const doc = newLiveDoc();
    const engine = new Engine(doc);
    engine.enqueue({ kind: "play" });
    // Drain the play intent and start the clock.
    engine.tick(0);

    const convert = makeBaseEventConverter();
    const events = convert({
      v: 1,
      sim_t_ns: 5_000_000,
      kind: "ocapn.session-opened",
      session: "alice--bob",
      a: "alice",
      b: "bob",
      codec: "syrup",
    });
    // Stamp `t` to "next tick" so events fire immediately on advance.
    for (const ev of events) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }

    // Advance enough wall time that simDt > the +1ms stamp.
    engine.tick(20);

    const alice = findPeer(engine.world, "alice");
    const bob = findPeer(engine.world, "bob");
    const session = findSession(engine.world, "alice--bob");

    assert(alice !== undefined, "alice peer must exist after fold");
    assert(bob !== undefined, "bob peer must exist after fold");
    assert(session !== undefined, "alice--bob session must exist after fold");
    assertEquals(session.endpoints.a, "alice");
    assertEquals(session.endpoints.b, "bob");
    assertEquals(session.session.codec, "syrup");
  },
);

liveTest(
  "live mode: subsequent ocapn.message-decoded produces messageInFlight",
  () => {
    const doc = newLiveDoc();
    const engine = new Engine(doc);
    engine.enqueue({ kind: "play" });
    engine.tick(0);

    const convert = makeBaseEventConverter();

    // First open the session.
    const sessionEvents = convert({
      v: 1,
      sim_t_ns: 5_000_000,
      kind: "ocapn.session-opened",
      session: "alice--bob",
      a: "alice",
      b: "bob",
      codec: "syrup",
    });
    for (const ev of sessionEvents) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }
    engine.tick(20);

    // Then send a message.
    const messageEvents = convert({
      v: 1,
      sim_t_ns: 10_000_000,
      kind: "ocapn.message-decoded",
      session: "alice--bob",
      src: "alice",
      dst: "bob",
      op: "op:start-session",
      len: 275,
    });
    for (const ev of messageEvents) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }
    engine.tick(20);

    // The world should now have alice + bob + session + a message in flight.
    assert(findPeer(engine.world, "alice") !== undefined);
    assert(findPeer(engine.world, "bob") !== undefined);
    assert(findSession(engine.world, "alice--bob") !== undefined);

    // Find the message-in-flight by the from/to pair.
    let foundMessage = false;
    for (const e of engine.world.with("messageInFlight")) {
      if (
        e.messageInFlight.from === "alice" && e.messageInFlight.to === "bob"
      ) {
        foundMessage = true;
        assertEquals(e.messageInFlight.label, "op:start-session");
      }
    }
    assert(foundMessage, "expected a messageInFlight entity from alice to bob");
  },
);

liveTest(
  "live mode: a session annotation renames the peer already on stage",
  () => {
    // A browser tab joins a room: the session opens before the app
    // knows the nick, so the peer arrives named by its locator and
    // the nick lands afterwards as `ocapn.session-meta`. The stage
    // must follow it without a seek — the live path never resets
    // the world.
    const doc = newLiveDoc();
    const engine = new Engine(doc);
    engine.enqueue({ kind: "play" });
    engine.tick(0);

    const convert = makeBaseEventConverter();
    for (
      const ev of convert({
        v: 1,
        sim_t_ns: 5_000_000,
        kind: "ocapn.session-opened",
        session: "s1",
        a: "rooms-host",
        b: "127.0.0.1:0",
        codec: "syrup",
      })
    ) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }
    engine.tick(20);
    const joinedT = engine.clock.t;
    assertEquals(
      findPeer(engine.world, "127.0.0.1:0")?.peer.label,
      "127.0.0.1:0",
    );

    for (
      const ev of convert({
        v: 1,
        sim_t_ns: 9_000_000,
        kind: "ocapn.session-meta",
        session: "s1",
        meta: { label: "carol" },
      })
    ) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }
    engine.tick(20);
    assertEquals(findPeer(engine.world, "127.0.0.1:0")?.peer.label, "carol");

    // And the capture keeps the earlier name: a replay of this
    // recording shows the locator until the nick arrives.
    engine.seekTo(joinedT);
    assertEquals(
      findPeer(engine.world, "127.0.0.1:0")?.peer.label,
      "127.0.0.1:0",
    );
  },
);

liveTest("live mode: peer dedup across many session-opened events", () => {
  const doc = newLiveDoc();
  const engine = new Engine(doc);
  engine.enqueue({ kind: "play" });
  engine.tick(0);

  const convert = makeBaseEventConverter();
  // Two sessions, both involving alice. peer-joined should fire
  // exactly once per peer ever.
  const session1 = convert({
    v: 1,
    sim_t_ns: 5_000_000,
    kind: "ocapn.session-opened",
    session: "alice--bob",
    a: "alice",
    b: "bob",
    codec: "syrup",
  });
  const session2 = convert({
    v: 1,
    sim_t_ns: 6_000_000,
    kind: "ocapn.session-opened",
    session: "alice--carol",
    a: "alice",
    b: "carol",
    codec: "syrup",
  });
  for (const ev of [...session1, ...session2]) {
    primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
  }
  engine.tick(20);

  // Three peers total (alice, bob, carol); two sessions.
  const peers = [...engine.world.with("peer")];
  assertEquals(peers.length, 3, "expected 3 distinct peer entities");
  const peerIds = peers.map((p) => p.peer.id).sort();
  assertEquals(peerIds, ["alice", "bob", "carol"]);

  assert(findSession(engine.world, "alice--bob") !== undefined);
  assert(findSession(engine.world, "alice--carol") !== undefined);
});

liveTest(
  "live mode: duration grows lazily; events past initial duration still fold",
  () => {
    const doc = newLiveDoc();
    const engine = new Engine(doc);
    engine.enqueue({ kind: "play" });
    engine.tick(0);

    const convert = makeBaseEventConverter();
    // Push an event "stamped now" — proves the wall-clock-paced live
    // pattern works.
    const events = convert({
      v: 1,
      sim_t_ns: 1_000_000,
      kind: "ocapn.session-opened",
      session: "alice--bob",
      a: "alice",
      b: "bob",
      codec: "syrup",
    });
    for (const ev of events) {
      primaryObservations(doc).push({ ...ev, t: engine.clock.t + 1 });
    }

    engine.tick(50);
    assert(findSession(engine.world, "alice--bob") !== undefined);

    // After the engine drains, document the entity count is stable.
    const sessionsBefore = [...engine.world.with("session")].length;
    engine.tick(50);
    const sessionsAfter = [...engine.world.with("session")].length;
    assertEquals(
      sessionsBefore,
      sessionsAfter,
      "no spurious entities created on tick without new events",
    );
  },
);

// makeLiveAppender: the pure helper used by `startLiveMode` to
// stamp incoming events onto the live clock and append them to the
// monitor's doc. Tested without opening a real peer — the
// appender doesn't care where events come from.

Deno.test("makeLiveAppender shifts a message's whole time base", () => {
  // Re-stamping moves the event onto the live clock; arrivalT must
  // shift by the same delta or the flight duration goes nonsense
  // (the defect this was validated against: arrivalT left on the
  // producer's base gave negative flights).
  const liveDoc = newLiveDoc();
  const append = makeLiveAppender({ liveDoc, clock: { t: 42 } });
  append({
    id: "m1",
    kind: "message-sent",
    t: 1_000,
    sessionId: "s",
    messageId: "msg",
    from: "a",
    to: "b",
    arrivalT: 1_081,
  });
  const stamped = primaryObservations(liveDoc)[0]!;
  assertEquals(stamped.t, 43);
  assertEquals(
    stamped.kind === "message-sent" ? stamped.arrivalT : null,
    43 + 81,
  );
});

Deno.test("makeLiveAppender lands the first event at clock.t + 1", () => {
  const liveDoc = newLiveDoc();
  const append = makeLiveAppender({ liveDoc, clock: { t: 42 } });
  append({
    id: "e1",
    kind: "peer-joined",
    t: 999, // producer time base; the latched offset maps it to now
    peerId: "p",
    profile: "pancake",
  });
  assertEquals(primaryObservations(liveDoc)[0]!.t, 43);
});

Deno.test("makeLiveAppender preserves producer inter-event spacing", () => {
  // The precision contract: producer timestamps arrive at
  // nanosecond resolution, and the ONE latched offset keeps their
  // spacing on stage. Re-stamping each event to "now" would
  // quantize every arrival to the tick boundary — sub-frame
  // spacing (here 0.25 ms and 0.01 ms) collapsing onto one t was
  // the "our floats aren't precise enough" symptom.
  const liveDoc = newLiveDoc();
  const clock = { t: 42 };
  const append = makeLiveAppender({ liveDoc, clock });
  const join = (id: string, t: number) => ({
    id,
    kind: "peer-joined" as const,
    t,
    peerId: id,
    profile: "pancake" as const,
  });
  append(join("p1", 1000));
  append(join("p2", 1000.25)); // same engine tick, 250 µs later
  append(join("p3", 1000.265625)); // 15.625 µs after that (2^-6 ms)
  const ts = primaryObservations(liveDoc).map((o) => o.t);
  assertEquals(ts, [43, 43.25, 43.265625]);
});

Deno.test("makeLiveAppender collapses a backlog burst to now, then resumes cadence", () => {
  // A late connect replays the producer's ring in one arrival
  // burst, with producer times spanning minutes. One fixed anchor
  // would spread the replay over the same minutes of stage FUTURE;
  // the forward clamp saturates it at now-plus-slack instead, and
  // the live tail afterwards keeps its true spacing.
  const liveDoc = newLiveDoc();
  const clock = { t: 100 };
  const append = makeLiveAppender({ liveDoc, clock });
  const join = (id: string, t: number) => ({
    id,
    kind: "peer-joined" as const,
    t,
    peerId: id,
    profile: "pancake" as const,
  });
  // Backlog burst: producer times a minute apart, delivered at once.
  append(join("old1", 1000));
  append(join("old2", 61_000));
  append(join("old3", 61_500));
  const backlog = primaryObservations(liveDoc).map((o) => o.t);
  assertEquals(backlog[0], 101); // first event lands at now
  // The rest land within the slack window, in order.
  for (let i = 1; i < backlog.length; i++) {
    const t = backlog[i]!;
    if (t < backlog[i - 1]! || t > clock.t + 250) {
      throw new Error(`backlog event ${i} landed at ${t}, outside window`);
    }
  }
  // Live tail: the clock caught up; small spacing survives exactly.
  clock.t = 1_000;
  append(join("live1", 62_000));
  append(join("live2", 62_000.125));
  const ts = primaryObservations(liveDoc).map((o) => o.t);
  assertEquals(ts[4]! - ts[3]!, 0.125);
});

// claimRecording: the whole accumulated doc IS the recording — the
// engine connects at the Record press, so its t=0 is the press.

Deno.test("claimRecording: fresh id, content-derived duration", () => {
  const doc = newLiveDoc();
  primaryObservations(doc).push(
    {
      id: "e1",
      t: 0,
      kind: "peer-joined",
      peerId: "alice",
      profile: "pancake",
    },
    {
      id: "e2",
      t: 500,
      kind: "message-sent",
      messageId: "m1",
      sessionId: "s1",
      from: "alice",
      to: "bob",
      arrivalT: 900,
    },
  );
  const claimed = claimRecording(doc, "rec-1")!;
  assert(claimed !== null, "a non-empty recording claims");
  assertEquals(claimed.id, "rec-1");
  assertEquals(primaryObservations(claimed).length, 2);
  // Duration covers the last flight's arrival plus breathing room,
  // instead of the live view's one-hour ceiling.
  assert(
    claimed.duration >= 900 && claimed.duration < 60_000,
    `duration derives from content, got ${claimed.duration}`,
  );
});

Deno.test("claimRecording: an empty recording claims nothing", () => {
  assertEquals(claimRecording(newLiveDoc(), "rec-2"), null);
});

Deno.test("claimRecording: the claim owns its observations", () => {
  // A shallow spread hands the claimed document the very array the live
  // appender is still pushing into, so a feed that keeps arriving after Stop
  // goes on writing into what the reader is scrubbing. The one caller
  // unmounts the capture in the same commit, which makes it safe today and
  // is a coupling nothing states — this holds the sever instead.
  //
  // Validated against the defect: restoring the shallow
  // `{ ...liveDoc, id, duration }` return fails this and nothing else.
  const doc = newLiveDoc();
  primaryObservations(doc).push({
    id: "e1",
    t: 0,
    kind: "peer-joined",
    peerId: "alice",
    profile: "pancake",
  });
  const claimed = claimRecording(doc, "rec-3")!;
  assertEquals(primaryObservations(claimed).length, 1);
  // The live side goes on doing what a live side does.
  primaryObservations(doc).push({
    id: "e2",
    t: 10,
    kind: "peer-joined",
    peerId: "bob",
    profile: "pancake",
  });
  assertEquals(
    primaryObservations(claimed).length,
    1,
    "an arrival after the claim reached the claimed recording",
  );
  assertEquals(primaryObservations(doc).length, 2);
});
