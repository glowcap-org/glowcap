import { assert, assertAlmostEquals } from "@std/assert";
import { CLAIM_LEAN } from "./claim-placement.ts";
import { bezierAt, claimTargets, computeSessionBundles, drawnSessionCurve } from "../session-geometry.ts";
import { Engine } from "../engine.ts";
import { TimelineDocument } from "../timeline.ts";

// End-to-end check that the user's actual test scenario — 5
// simultaneous messages on one session, same direction — produces
// 5 visibly different positions on the spine at mid-flight. Uses
// the full Engine so peer positions come from the real layout
// system (KeyframeLayoutSystem honors `peer-joined.position` only
// under `layoutMode: "authored"`).

function buildFiveMessageDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "test-five-messages",
    duration: 1000,
    layoutMode: "authored",
    events: [
      {
        id: "auth-alice",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
        position: { x: -100, y: 0 },
      },
      {
        id: "auth-bob",
        t: 0,
        kind: "peer-joined",
        peerId: "bob",
        profile: "goblins",
        position: { x: 100, y: 0 },
      },
      {
        id: "auth-session-1",
        t: 0,
        kind: "session-opened",
        sessionId: "session-1",
        a: { peer: "alice" },
        b: { peer: "bob" },
        codec: "capnp",
        captpVersion: "v1_0",
        initialState: "open",
      },
      // All 5 sent at t=0 first (sort-by-t requires they come
      // before the t=500 delivered events).
      ...[1, 2, 3, 4, 5].map((i) => ({
        id: `auth-msg-${i}-sent`,
        t: 0,
        kind: "message-sent" as const,
        messageId: `msg-${i}`,
        sessionId: "session-1",
        from: "alice",
        to: "bob",
        arrivalT: 500,
      })),
      ...[1, 2, 3, 4, 5].map((i) => ({
        id: `auth-msg-${i}-delivered`,
        t: 500,
        kind: "message-delivered" as const,
        messageId: `msg-${i}`,
      })),
    ],
  });
}

Deno.test("5 simultaneous A→B messages spread across the spine at mid-flight", () => {
  const engine = new Engine(buildFiveMessageDoc());
  engine.seekTo(250); // mid-flight (sentT=0, arrivalT=500)

  const xs: number[] = [];
  for (const e of engine.queries.messagesInFlight) {
    xs.push(e.position.x);
  }
  xs.sort((a, b) => a - b);

  // Chord runs from (-100, 0) to (100, 0); length 200.
  // 5 messages → adaptive spread across [-MAX, +MAX] = [-0.25, +0.25].
  // At kEased=0.5, kArced = 0.5 + arc * sin(π/2) = 0.5 + arc.
  // Arcs: -0.25, -0.125, 0, +0.125, +0.25.
  // kArced: 0.25, 0.375, 0.5, 0.625, 0.75.
  // x = -100 + kArced * 200: -50, -25, 0, 25, 50.
  assertAlmostEquals(xs[0]!, -50, 0.5);
  assertAlmostEquals(xs[1]!, -25, 0.5);
  assertAlmostEquals(xs[2]!, 0, 0.5);
  assertAlmostEquals(xs[3]!, 25, 0.5);
  assertAlmostEquals(xs[4]!, 50, 0.5);
});

Deno.test("5 simultaneous A→B messages monotonically move sender→receiver (never stuck or backwards)", () => {
  // The monotonicity contract: at every wall-time, every message's
  // x position is between the previous time's x and the receiver.
  // Catches the `MAX_TEMPORAL_ARC > 1/π` regression where extreme-
  // arc messages stalled at sender / receiver for ~30% of flight.
  const engine = new Engine(buildFiveMessageDoc());
  const sampleTimes = [10, 50, 100, 150, 200, 250, 300, 350, 400, 450, 490];
  const trajectories = new Map<string, number[]>();
  for (const t of sampleTimes) {
    engine.seekTo(t);
    for (const e of engine.queries.messagesInFlight) {
      let list = trajectories.get(e.messageInFlight.id);
      if (!list) {
        list = [];
        trajectories.set(e.messageInFlight.id, list);
      }
      list.push(e.position.x);
    }
  }
  // Every message's x must strictly increase across samples (chord
  // goes -100 → +100). Equal-x at consecutive samples = stuck.
  for (const [id, xs] of trajectories) {
    for (let i = 1; i < xs.length; i++) {
      const prev = xs[i - 1]!;
      const cur = xs[i]!;
      if (cur <= prev) {
        throw new Error(
          `${id} not monotonic: sample ${i - 1} = ${prev}, ` +
            `sample ${i} = ${cur} (sampleTimes ${sampleTimes[i - 1]}, ${sampleTimes[i]})`,
        );
      }
    }
  }
});

Deno.test("5 simultaneous A→B messages all converge at sender at sentT", () => {
  const engine = new Engine(buildFiveMessageDoc());
  engine.seekTo(0);
  for (const e of engine.queries.messagesInFlight) {
    assertAlmostEquals(e.position.x, -100, 0.1);
    assertAlmostEquals(e.position.y, 0, 0.1);
  }
});

Deno.test("5 simultaneous A→B messages all converge at receiver at arrivalT", () => {
  const engine = new Engine(buildFiveMessageDoc());
  // Seek to just under arrivalT — at exactly 500 the delivered
  // events fire and the messages are removed from flight.
  engine.seekTo(499);
  for (const e of engine.queries.messagesInFlight) {
    assertAlmostEquals(e.position.x, 100, 1);
    assertAlmostEquals(e.position.y, 0, 1);
  }
});

/** A session whose `a` end nothing has attributed, with the peer on `b`, and
 *  one message each way.
 *
 *  The loose end takes an authored position through the session that owns
 *  it, so both peers and the placeholder are placed deliberately and a
 *  flight direction is a coordinate comparison rather than an eyeball.
 *
 *  The message OUT of the loose end names its sender the way a producer that
 *  reported `src` directly does — by the name it knows it under, which is
 *  not the node id the stage drew the end at. That is the case a direction
 *  test asking only "is the sender `a`?" gets wrong, and it gets it wrong
 *  silently, by flying the dot out of the receiver. */
function buildLooseAEndDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "test-loose-a-end",
    duration: 1000,
    layoutMode: "authored",
    entities: {
      sessions: {
        "session-1": {
          a: { designator: "tcp://who-knows" },
          b: { peer: "bob", attributedBy: "self-reported" },
          codec: "capnp",
          captpVersion: "v1_0",
          endpointPosition: { a: { x: -100, y: 0 } },
        },
      },
    },
    events: [
      {
        id: "auth-bob",
        t: 0,
        kind: "peer-joined",
        peerId: "bob",
        profile: "pancake",
        position: { x: 100, y: 0 },
      },
      {
        id: "auth-session-1",
        t: 0,
        kind: "session-opened",
        sessionId: "session-1",
        a: { designator: "tcp://who-knows" },
        b: { peer: "bob", attributedBy: "self-reported" },
        codec: "capnp",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "auth-out",
        t: 0,
        kind: "message-sent",
        messageId: "from-loose",
        sessionId: "session-1",
        from: "tcp://who-knows",
        to: "bob",
        arrivalT: 500,
      },
      {
        id: "auth-in",
        t: 0,
        kind: "message-sent",
        messageId: "from-bob",
        sessionId: "session-1",
        from: "bob",
        to: "tcp://who-knows",
        arrivalT: 500,
      },
      {
        id: "auth-out-done",
        t: 500,
        kind: "message-delivered",
        messageId: "from-loose",
      },
      {
        id: "auth-in-done",
        t: 500,
        kind: "message-delivered",
        messageId: "from-bob",
      },
    ],
  });
}

/** Where one message sits at `t`. */
function messageXAt(engine: Engine, id: string, t: number): number {
  engine.seekTo(t);
  for (const e of engine.queries.messagesInFlight) {
    if (e.messageInFlight.id === id) return e.position.x;
  }
  throw new Error(`${id} is not in flight at t=${t}`);
}

Deno.test("each message leaves its own end when one of them is loose", () => {
  // bob sits at x=+100, the unattributed end at x=-100, so which end a dot
  // departs from is the whole claim. The two messages are on one session in
  // opposite directions: if either is read as travelling the other way, it
  // departs out of its receiver.
  const engine = new Engine(buildLooseAEndDoc());
  assertAlmostEquals(messageXAt(engine, "from-loose", 1), -100, 2);
  assertAlmostEquals(messageXAt(engine, "from-loose", 499), 100, 2);
  assertAlmostEquals(messageXAt(engine, "from-bob", 1), 100, 2);
  assertAlmostEquals(messageXAt(engine, "from-bob", 499), -100, 2);
});

Deno.test("a message on a claimed session flies along the drawn wire", () => {
  // The dot and the edge must be one geometry. An edge whose far end is a
  // claim is drawn as the prefix of the lane to the peer it names — arched as
  // though it were going there, and stopping at the claim — so a dot on the
  // curve between the raw endpoints would fly beside its own wire.
  const doc = TimelineDocument.parse({
    id: "claimed-flight",
    duration: 2000,
    events: [
      {
        id: "j-carol",
        t: 0,
        kind: "peer-joined",
        peerId: "carol",
        profile: "pancake",
      },
      {
        id: "j-alice",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
        designator: "10.0.0.1",
      },
      // Two sessions on the pair so the fan is real and the lane is bowed.
      {
        id: "o-real",
        t: 0,
        kind: "session-opened",
        sessionId: "s-real",
        a: { peer: "carol" },
        b: { peer: "alice" },
        codec: "capnp",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "o-claim",
        t: 0,
        kind: "session-opened",
        sessionId: "s-claim",
        a: { peer: "carol" },
        b: { designator: "10.0.0.1" },
        codec: "capnp",
        captpVersion: "v1_0",
        initialState: "open",
      },
      {
        id: "m-sent",
        t: 0,
        kind: "message-sent",
        messageId: "m1",
        sessionId: "s-claim",
        from: "carol",
        to: "s-claim::b",
        arrivalT: 1000,
      },
      { id: "m-got", t: 1000, kind: "message-delivered", messageId: "m1" },
    ],
  });
  const engine = new Engine(doc);
  engine.seekTo(500);
  const world = engine.world;

  const dot = [...world.with("messageInFlight", "position")]
    .find((e) => e.messageInFlight.id === "m1");
  assert(dot !== undefined, "the message was not in flight");
  const claims = claimTargets(world, engine.claims);
  const bundle = computeSessionBundles(world, claims).get("s-claim");
  assert(bundle !== undefined);
  const wire = drawnSessionCurve(
    world,
    "carol",
    "s-claim::b",
    bundle,
    claims,
    CLAIM_LEAN,
  );
  assert(wire !== null, "the claimed session had no wire");
  // Closest approach of the dot to the wire, sampled finely enough that a dot
  // on a different arc cannot hide between samples.
  let nearest = Infinity;
  for (let i = 0; i <= 200; i++) {
    const p = bezierAt(wire, i / 200);
    nearest = Math.min(
      nearest,
      Math.hypot(p.x - dot.position.x, p.y - dot.position.y),
    );
  }
  assert(nearest < 1, `the dot flew ${nearest.toFixed(1)} from its own wire`);
});
