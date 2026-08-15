/**
 * Tests for region-aware layout in `KeyframeLayoutSystem`.
 *
 * The keyframe layout normally produces opaque positions (d3-force
 * convergence depends on the full graph). We verify the
 * region-aware behavior by:
 *
 * 1. Building a `TimelineDocument` with region-prefixed peers
 *    spread across continents.
 * 2. Running the layout system on a fresh `GameWorld`.
 * 3. Asserting that each peer's final position is closer to its
 *    region's centroid than to other regions' centroids — i.e. the
 *    region pull force won.
 *
 * This pins the behavior so a future refactor can't accidentally
 * regress region-aware layout to a global force-only blob.
 */

import { assert, assertEquals } from "@std/assert";
import { World } from "miniplex";
import {
  DEFAULT_LAYOUT_CONFIG,
  forceFootprints,
  KeyframeLayoutSystem,
  type NodeFootprint,
  nodeFootprint,
} from "./keyframe-layout-system.ts";
import { NODE_RADIUS } from "../../render/draw-helpers.ts";
import {
  endpointLabelText,
  NODE_LABEL,
  NODE_LABEL_GAP_PX,
  peerLabelText,
  pillSize,
} from "../../render/stage-labels.ts";
import type { Components, GameWorld, Vec2 } from "../world.ts";
import { TimelineDocument } from "../timeline.ts";
import { attachedEndpoint } from "../../schema/topology.ts";
import { materializeWorldAt } from "./world-materializer.ts";

// d3-force schedules a d3-timer via setTimeout under Deno (no rAF
// in the test env). `simulation.stop()` cancels the timer logically
// but the platform handle lingers past the synchronous test, which
// Deno's resource sanitizer flags as a leak. Harmless in the
// browser; same workaround as engine.test.ts.
function layoutTest(name: string, fn: () => void): void {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn,
  });
}

function freshWorld(peerIds: string[]): GameWorld {
  const w = new World<Components>();
  for (const id of peerIds) {
    w.add({
      peer: { id, label: id, profile: "pancake" },
      position: { x: 0, y: 0 },
    });
  }
  return w;
}

function dist(a: Vec2, b: Vec2): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function makeRegionDoc(): TimelineDocument {
  return {
    id: "region-layout-test",
    duration: 1000,
    recording: {
      sources: [{
        id: "fixture",

        meta: { kind: "fixture" },

        observations: [
          {
            id: "j1",
            t: 0,
            kind: "peer-joined",
            peerId: "us-alice",
            profile: "pancake",
          },
          {
            id: "j2",
            t: 0,
            kind: "peer-joined",
            peerId: "eu-bob",
            profile: "pancake",
          },
          {
            id: "j3",
            t: 0,
            kind: "peer-joined",
            peerId: "ap-carol",
            profile: "pancake",
          },
          {
            id: "s1",
            t: 100,
            kind: "session-opened",
            sessionId: "eu-bob--us-alice",
            a: attachedEndpoint("us-alice"),
            b: attachedEndpoint("eu-bob"),
            codec: "syrup",
            captpVersion: "v1_0",
          },
          {
            id: "s2",
            t: 100,
            kind: "session-opened",
            sessionId: "ap-carol--us-alice",
            a: attachedEndpoint("us-alice"),
            b: attachedEndpoint("ap-carol"),
            codec: "syrup",
            captpVersion: "v1_0",
          },
        ],
      }],
    },
  };
}

layoutTest("region-prefixed peers land near their continental centroid", () => {
  const doc = makeRegionDoc();
  const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
  const world = freshWorld(["us-alice", "eu-bob", "ap-carol"]);
  layout.update(world, 100); // post-session keyframe, transition complete

  const positions = new Map<string, Vec2>();
  for (const e of world.with("peer", "position")) {
    positions.set(e.peer.id, e.position);
  }

  const usCentroid = { x: -480, y: -60 };
  const euCentroid = { x: 60, y: -180 };
  const apCentroid = { x: 460, y: -40 };

  const us = positions.get("us-alice")!;
  const eu = positions.get("eu-bob")!;
  const ap = positions.get("ap-carol")!;

  // Each peer must be closer to ITS centroid than to either of the
  // other two — the region force won over the link / charge forces.
  assert(
    dist(us, usCentroid) < dist(us, euCentroid),
    `us-alice should be closer to US than EU; got us=${JSON.stringify(us)}`,
  );
  assert(
    dist(us, usCentroid) < dist(us, apCentroid),
    `us-alice should be closer to US than AP; got us=${JSON.stringify(us)}`,
  );
  assert(
    dist(eu, euCentroid) < dist(eu, usCentroid),
    `eu-bob should be closer to EU than US; got eu=${JSON.stringify(eu)}`,
  );
  assert(
    dist(eu, euCentroid) < dist(eu, apCentroid),
    `eu-bob should be closer to EU than AP; got eu=${JSON.stringify(eu)}`,
  );
  assert(
    dist(ap, apCentroid) < dist(ap, usCentroid),
    `ap-carol should be closer to AP than US; got ap=${JSON.stringify(ap)}`,
  );
  assert(
    dist(ap, apCentroid) < dist(ap, euCentroid),
    `ap-carol should be closer to AP than EU; got ap=${JSON.stringify(ap)}`,
  );
});

layoutTest(
  "unprefixed peers ignore the region force and stay near (0, 0)",
  () => {
    const doc: TimelineDocument = {
      id: "unprefixed-layout-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "alice",
              profile: "pancake",
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "bob",
              profile: "pancake",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
    const world = freshWorld(["alice", "bob"]);
    layout.update(world, 0);

    // Without region prefix, both peers should be within ~400 of the
    // origin — the existing behavior. Far less than the ~480 a US-only
    // centroid would pull them.
    for (const e of world.with("peer", "position")) {
      const d = Math.hypot(e.position.x, e.position.y);
      assert(
        d < 400,
        `${e.peer.id} should stay near origin; got distance=${d}`,
      );
    }
  },
);

layoutTest(
  "multiple peers in the same region spread out from the centroid",
  () => {
    const doc: TimelineDocument = {
      id: "many-in-region-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "us-a",
              profile: "pancake",
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "us-b",
              profile: "pancake",
            },
            {
              id: "j3",
              t: 0,
              kind: "peer-joined",
              peerId: "us-c",
              profile: "pancake",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
    const world = freshWorld(["us-a", "us-b", "us-c"]);
    layout.update(world, 0);

    const positions: Vec2[] = [];
    for (const e of world.with("peer", "position")) {
      positions.push(e.position);
    }
    // No two peers should occupy the same point (collision force +
    // distinct seed positions). Pairwise distance > 0.
    for (let i = 0; i < positions.length; i++) {
      for (let j = i + 1; j < positions.length; j++) {
        const d = dist(positions[i]!, positions[j]!);
        assert(d > 1, `peers should not coincide; got distance=${d}`);
      }
    }
  },
);

layoutTest(
  "two-segment cloud-region tags (us-east, us-west) place peers at distinct sub-region centroids",
  () => {
    const doc: TimelineDocument = {
      id: "cloud-region-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "us-east-alice",
              profile: "pancake",
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "us-west-bob",
              profile: "pancake",
            },
            {
              id: "j3",
              t: 0,
              kind: "peer-joined",
              peerId: "ap-northeast-carol",
              profile: "pancake",
            },
            {
              id: "j4",
              t: 0,
              kind: "peer-joined",
              peerId: "ap-southeast-dave",
              profile: "pancake",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
    const world = freshWorld([
      "us-east-alice",
      "us-west-bob",
      "ap-northeast-carol",
      "ap-southeast-dave",
    ]);
    layout.update(world, 0);

    const positions = new Map<string, Vec2>();
    for (const e of world.with("peer", "position")) {
      positions.set(e.peer.id, e.position);
    }
    const usEast = positions.get("us-east-alice")!;
    const usWest = positions.get("us-west-bob")!;
    const apNe = positions.get("ap-northeast-carol")!;
    const apSe = positions.get("ap-southeast-dave")!;

    // East/West coast separation: us-east-alice should sit clearly
    // RIGHT of us-west-bob (us-east x = -380, us-west x = -560).
    assert(
      usEast.x > usWest.x,
      `us-east should be east (right) of us-west; got us-east=${JSON.stringify(usEast)} us-west=${
        JSON.stringify(usWest)
      }`,
    );
    // ap-southeast (Singapore-ish) should sit BELOW ap-northeast (Tokyo-ish).
    assert(
      apSe.y > apNe.y,
      `ap-southeast should be south (below) of ap-northeast; got se=${JSON.stringify(apSe)} ne=${JSON.stringify(apNe)}`,
    );
  },
);

layoutTest(
  "single-segment 'us-alice' falls back to continental rollup",
  () => {
    // Multiple peers across continents — d3-force's `forceCenter`
    // anchors center-of-mass to origin, so single-peer scenarios
    // are degenerate (the lone peer IS the COM and gets pulled to
    // origin). With three peers in three continents, COM averages
    // out and per-node region forces win.
    const doc: TimelineDocument = {
      id: "rollup-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "us-alice",
              profile: "pancake",
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "eu-bob",
              profile: "pancake",
            },
            {
              id: "j3",
              t: 0,
              kind: "peer-joined",
              peerId: "ap-carol",
              profile: "pancake",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
    const world = freshWorld(["us-alice", "eu-bob", "ap-carol"]);
    layout.update(world, 0);
    const positions = new Map<string, Vec2>();
    for (const e of world.with("peer", "position")) {
      positions.set(e.peer.id, e.position);
    }
    // 'us' continental rollup is at x=-480, eu at x=60, ap at x=480.
    // After force settles, us-alice should be CLEARLY left of eu-bob
    // and eu-bob clearly left of ap-carol — proving rollup parsing
    // handed each peer to its continental centroid.
    const us = positions.get("us-alice")!;
    const eu = positions.get("eu-bob")!;
    const ap = positions.get("ap-carol")!;
    assert(us.x < eu.x, `us should be left of eu; us=${us.x} eu=${eu.x}`);
    assert(eu.x < ap.x, `eu should be left of ap; eu=${eu.x} ap=${ap.x}`);
  },
);

// `authored` layout mode is the builder's substrate: peer positions
// come straight from each `peer-joined` event's `position` field and
// no d3-force convergence runs. These tests pin that contract — a
// builder that writes `(140, -82)` should see the canvas place that
// peer at exactly `(140, -82)`, every frame, forever.

layoutTest("authored mode places peers at their declared position", () => {
  const doc: TimelineDocument = {
    id: "authored-layout-test",
    duration: 1000,
    layoutMode: "authored",
    recording: {
      sources: [{
        id: "fixture",

        meta: { kind: "fixture" },

        observations: [
          {
            id: "j1",
            t: 0,
            kind: "peer-joined",
            peerId: "alice",
            profile: "pancake",
            position: { x: 140, y: -82 },
          },
          {
            id: "j2",
            t: 0,
            kind: "peer-joined",
            peerId: "bob",
            profile: "goblins",
            position: { x: -210, y: 60 },
          },
        ],
      }],
    },
  };
  const layout = new KeyframeLayoutSystem(doc, {
    ...DEFAULT_LAYOUT_CONFIG,
    mode: "authored",
  });
  const world = freshWorld(["alice", "bob"]);
  layout.update(world, 0);
  const positions = new Map<string, Vec2>();
  for (const e of world.with("peer", "position")) {
    positions.set(e.peer.id, e.position);
  }
  const alice = positions.get("alice")!;
  const bob = positions.get("bob")!;
  assert(
    alice.x === 140 && alice.y === -82,
    `alice should be at (140, -82); got ${JSON.stringify(alice)}`,
  );
  assert(
    bob.x === -210 && bob.y === 60,
    `bob should be at (-210, 60); got ${JSON.stringify(bob)}`,
  );
});

layoutTest(
  "authored mode falls back to (0, 0) for peers without a position",
  () => {
    const doc: TimelineDocument = {
      id: "authored-missing-position",
      duration: 1000,
      layoutMode: "authored",
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "alice",
              profile: "pancake",
              // position intentionally omitted
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      mode: "authored",
    });
    const world = freshWorld(["alice"]);
    layout.update(world, 0);
    const alice = [...world.with("peer", "position")][0]?.position;
    assert(
      alice?.x === 0 && alice?.y === 0,
      `alice should fall back to origin; got ${JSON.stringify(alice)}`,
    );
  },
);

// ───────────────── authored positions pin the force modes ─────────────────
// An authored `position` inside a force mode is a pin: every
// keyframe carries it exactly, and the sim holds the node fixed
// (`fx`/`fy`) while links still pull free neighbors around it. The
// defect this family was written against: a sim that integrates a
// pinned node like any other, drifting it off its authored point.

layoutTest(
  "per-topology keyframes hold a pinned peer exactly while free peers move",
  () => {
    const doc: TimelineDocument = {
      id: "pin-per-topology-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "alice",
              profile: "pancake",
              position: { x: 300, y: 200 },
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "bob",
              profile: "goblins",
            },
            {
              id: "j3",
              t: 0,
              kind: "peer-joined",
              peerId: "carol",
              profile: "pancake",
            },
            {
              id: "s1",
              t: 100,
              kind: "session-opened",
              sessionId: "alice--bob",
              a: attachedEndpoint("alice"),
              b: attachedEndpoint("bob"),
              codec: "syrup",
              captpVersion: "v1_0",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
    const kfs = layout.keyframes;
    assert(kfs.length === 2, `expected 2 keyframes; got ${kfs.length}`);
    for (const kf of kfs) {
      const alice = kf.layout.get("alice")!;
      assert(
        alice.x === 300 && alice.y === 200,
        `alice must sit exactly on her pin in every keyframe; got ${JSON.stringify(alice)} at t=${kf.t}`,
      );
    }
    // Bob gains a link to the pin at t=100 — his converged position
    // must move between the keyframes (he is NOT pinned).
    const bobBefore = kfs[0]!.layout.get("bob")!;
    const bobAfter = kfs[1]!.layout.get("bob")!;
    assert(
      dist(bobBefore, bobAfter) > 1,
      `bob should re-settle when the topology changes; before=${JSON.stringify(bobBefore)} after=${
        JSON.stringify(bobAfter)
      }`,
    );
  },
);

layoutTest(
  "static-union keyframe holds a pinned peer exactly at its authored position",
  () => {
    const doc: TimelineDocument = {
      id: "pin-static-union-test",
      duration: 1000,
      layoutMode: "static-union",
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "alice",
              profile: "pancake",
              position: { x: -450, y: 120 },
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "bob",
              profile: "goblins",
            },
            {
              id: "s1",
              t: 100,
              kind: "session-opened",
              sessionId: "alice--bob",
              a: attachedEndpoint("alice"),
              b: attachedEndpoint("bob"),
              codec: "syrup",
              captpVersion: "v1_0",
            },
          ],
        }],
      },
    };
    const layout = new KeyframeLayoutSystem(doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      mode: "static-union",
    });
    assert(layout.keyframes.length === 1);
    const kf = layout.keyframes[0]!;
    const alice = kf.layout.get("alice")!;
    assert(
      alice.x === -450 && alice.y === 120,
      `alice must sit exactly on her pin; got ${JSON.stringify(alice)}`,
    );
    const bob = kf.layout.get("bob")!;
    assert(
      bob.x !== -450 || bob.y !== 120,
      `bob must not collapse onto the pin; got ${JSON.stringify(bob)}`,
    );
  },
);

layoutTest(
  "all-pinned doc: per-topology keyframes match authored-mode placement",
  () => {
    const makeDoc = (): TimelineDocument => ({
      id: "all-pinned-test",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",

          meta: { kind: "fixture" },

          observations: [
            {
              id: "j1",
              t: 0,
              kind: "peer-joined",
              peerId: "alice",
              profile: "pancake",
              position: { x: 140, y: -82 },
            },
            {
              id: "j2",
              t: 0,
              kind: "peer-joined",
              peerId: "bob",
              profile: "goblins",
              position: { x: -210, y: 60 },
            },
            {
              id: "s1",
              t: 100,
              kind: "session-opened",
              sessionId: "alice--bob",
              a: attachedEndpoint("alice"),
              b: attachedEndpoint("bob"),
              codec: "syrup",
              captpVersion: "v1_0",
            },
          ],
        }],
      },
    });
    const forced = new KeyframeLayoutSystem(makeDoc(), DEFAULT_LAYOUT_CONFIG);
    const authored = new KeyframeLayoutSystem(makeDoc(), {
      ...DEFAULT_LAYOUT_CONFIG,
      mode: "authored",
    });
    const reference = authored.keyframes[0]!.layout;
    assert(forced.keyframes.length > 0);
    for (const kf of forced.keyframes) {
      for (const [peerId, pos] of kf.layout) {
        const expected = reference.get(peerId)!;
        assert(
          pos.x === expected.x && pos.y === expected.y,
          `${peerId} must match authored placement; got ${JSON.stringify(pos)} expected ${
            JSON.stringify(expected)
          } at t=${kf.t}`,
        );
      }
    }
  },
);

layoutTest(
  "all-pinned recomputeForPlacement stays cheap under many iterations",
  () => {
    // Every peer is pinned: the solver must not spend `iterations`
    // ticks moving nothing. A cold anneal at 5000 ticks on a small
    // all-pinned graph is tens of milliseconds; the pin-only path
    // is a map copy. The bound is loose on purpose — it fails when
    // someone removes the all-pinned short-circuit, not when a
    // machine is briefly busy.
    const joins: Array<{
      id: string;
      t: number;
      kind: "peer-joined";
      peerId: string;
      profile: string;
      position: { x: number; y: number };
    }> = [];
    for (let i = 0; i < 20; i += 1) {
      joins.push({
        id: `j${i}`,
        t: 0,
        kind: "peer-joined",
        peerId: `p${i}`,
        profile: "pancake",
        position: { x: i * 40, y: (i % 5) * 40 },
      });
    }
    const sessions = [];
    for (let i = 0; i < 19; i += 1) {
      sessions.push({
        id: `s${i}`,
        t: 0,
        kind: "session-opened" as const,
        sessionId: `s${i}`,
        a: attachedEndpoint(`p${i}`),
        b: attachedEndpoint(`p${i + 1}`),
        codec: "syrup" as const,
        captpVersion: "v1_0" as const,
      });
    }
    const doc = {
      id: "all-pinned-cheap",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",
          meta: { kind: "fixture" },
          observations: [...joins, ...sessions],
        }],
      },
    } as unknown as TimelineDocument;
    const layout = new KeyframeLayoutSystem(doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      iterations: 5000,
    });
    const t0 = performance.now();
    for (let i = 0; i < 30; i += 1) {
      const join = joins[i % 20]!;
      join.position = { x: join.position.x + 3, y: join.position.y };
      layout.recomputeForPlacement();
    }
    const elapsed = performance.now() - t0;
    assert(
      elapsed < 200,
      `all-pinned recompute spent ${elapsed.toFixed(1)}ms over 30 drags; expected the pin-only path`,
    );
  },
);

layoutTest(
  "pinning a peer in place does not anneal free eras",
  () => {
    // The old placement path cold-solved every era, then threw the result away
    // via reuseIfEquilibrium when the pin sat where the era already had the
    // peer. With a handful of free eras and a high iteration count that
    // throwaway was tens of milliseconds per drag; checking equilibrium
    // before runForce makes the same gesture a map copy.
    const observations: unknown[] = [];
    for (let i = 0; i < 8; i += 1) {
      observations.push({
        id: `j${i}`,
        t: i * 50,
        kind: "peer-joined",
        peerId: `p${i}`,
        profile: "pancake",
      });
    }
    for (let i = 0; i < 7; i += 1) {
      observations.push({
        id: `s${i}`,
        t: i * 50 + 1,
        kind: "session-opened",
        sessionId: `s${i}`,
        a: attachedEndpoint(`p${i}`),
        b: attachedEndpoint(`p${i + 1}`),
        codec: "syrup",
        captpVersion: "v1_0",
      });
    }
    const doc = {
      id: "pin-in-place-cheap",
      duration: 1000,
      recording: {
        sources: [{
          id: "fixture",
          meta: { kind: "fixture" },
          observations,
        }],
      },
    } as unknown as TimelineDocument;
    const layout = new KeyframeLayoutSystem(doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      iterations: 4000,
    });
    const at = layout.keyframes[0]!.layout.get("p0");
    assert(at !== undefined, "p0 should have a solved position");
    // Seed the pin at the solved point once so subsequent placement edits
    // are "pin here" rather than first-time pins.
    const joins = observations.filter((o) => (o as { kind: string }).kind === "peer-joined") as Array<
      { peerId: string; position?: { x: number; y: number } }
    >;
    const p0 = joins.find((j) => j.peerId === "p0")!;
    p0.position = { x: at.x, y: at.y };
    layout.recomputeForPlacement();
    const t0 = performance.now();
    for (let i = 0; i < 25; i += 1) {
      p0.position = { x: at.x, y: at.y };
      layout.recomputeForPlacement();
    }
    const elapsed = performance.now() - t0;
    assert(
      elapsed < 500,
      `pin-in-place spent ${elapsed.toFixed(1)}ms over 25 edits; ` +
        `free eras were probably annealed then discarded`,
    );
  },
);

// ───────────────── what a node draws is what is separated ─────────────────
// The solver used to keep one constant radius around each node's center,
// tuned to the body. A node's label is wider than its body — several times
// wider once it carries a designator — and hangs below it, so a circle sized
// for the body let labels sit on top of each other and a circle sized for the
// label spent that width upward too. `nodeFootprint` is the box the solver
// separates instead, and these hold the two halves of that: nothing drawn
// overlaps anything else drawn, and the box is the one the renderer draws.

/** One session per end, all of them hanging off a single peer, each end
 *  naming something nobody on stage answers to — so every end is an ordinary
 *  solved body rather than a claim leaning on its own edge. */
function hubDoc(
  designators: readonly (string | undefined)[],
): TimelineDocument {
  const observations: unknown[] = [{
    id: "j-hub",
    t: 0,
    kind: "peer-joined",
    peerId: "hub",
    profile: "pancake",
  }];
  designators.forEach((designator, i) => {
    observations.push({
      id: `o-${i}`,
      t: 0,
      kind: "session-opened",
      sessionId: `s${i}`,
      a: { peer: "hub", attributedBy: "self-reported" },
      b: designator === undefined ? {} : { designator },
      codec: "syrup",
      captpVersion: "v1_0",
    });
  });
  return {
    id: "hub-doc",
    duration: 1000,
    recording: {
      sources: [{ id: "fixture", meta: { kind: "fixture" }, observations }],
    },
  } as unknown as TimelineDocument;
}

/** A hub every peer holds a session with, each of those peers wearing the
 *  same display name. A name is the label a person chose, so unlike a
 *  designator it is drawn whole however long it is. */
function namedHubDoc(name: string, count: number): TimelineDocument {
  const observations: unknown[] = [{
    id: "j-hub",
    t: 0,
    kind: "peer-joined",
    peerId: "hub",
    profile: "pancake",
  }];
  for (let i = 0; i < count; i++) {
    observations.push({
      id: `j-${i}`,
      t: 0,
      kind: "peer-joined",
      peerId: `p${i}`,
      label: name,
      profile: "pancake",
    });
    observations.push({
      id: `o-${i}`,
      t: 0,
      kind: "session-opened",
      sessionId: `s${i}`,
      a: { peer: "hub", attributedBy: "self-reported" },
      b: { peer: `p${i}`, attributedBy: "self-reported" },
      codec: "syrup",
      captpVersion: "v1_0",
    });
  }
  return {
    id: "named-hub-doc",
    duration: 1000,
    recording: {
      sources: [{ id: "fixture", meta: { kind: "fixture" }, observations }],
    },
  } as unknown as TimelineDocument;
}

/** The last keyframe's layout, which is the arrangement a reader ends on. */
/** Two peers wearing the same caption, joined by one session. The smallest
 *  document in which a peer caption is the only thing deciding how far apart
 *  the graph has to stand. */
function pairDoc(label: string): TimelineDocument {
  return {
    id: "pair-doc",
    duration: 1000,
    recording: {
      sources: [{
        id: "fixture",
        meta: { kind: "fixture" },
        observations: [
          { id: "j0", t: 0, kind: "peer-joined", peerId: "p0", label },
          { id: "j1", t: 0, kind: "peer-joined", peerId: "p1", label },
          {
            id: "o0",
            t: 0,
            kind: "session-opened",
            sessionId: "s0",
            a: { peer: "p0", attributedBy: "self-reported" },
            b: { peer: "p1", attributedBy: "self-reported" },
            codec: "syrup",
            captpVersion: "v1_0",
          },
        ],
      }],
    },
  } as unknown as TimelineDocument;
}

function settled(doc: TimelineDocument): Map<string, Vec2> {
  const kfs = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG).keyframes;
  return new Map(kfs[kfs.length - 1]!.layout);
}

/** How far into each other two nodes' drawn boxes reach, in world units;
 *  zero or less when they clear. */
function boxOverlap(
  a: Vec2,
  aBox: NodeFootprint,
  b: Vec2,
  bBox: NodeFootprint,
): number {
  const x = aBox.halfWidth + bBox.halfWidth - Math.abs(a.x - b.x);
  const upper = a.y <= b.y ? aBox : bBox;
  const lower = a.y <= b.y ? bBox : aBox;
  const y = upper.below + lower.above - Math.abs(a.y - b.y);
  return Math.min(x, y);
}

layoutTest(
  "the box the solver keeps clear is the one the renderer draws",
  () => {
    // At 100% zoom, which is where a world-unit box and a counter-scaled
    // label are the same size. Zooming out grows every label against a graph
    // solved once; `stage-labels.ts` carries that and bounds the worst case.
    //
    // The mirror `keyframe-layout-system.ts` keeps of `NODE_RADIUS`, checked
    // against the authority rather than trusted. A body drawn at one size and
    // separated at another is a gap no reader could explain.
    assertEquals(nodeFootprint("", false).above, NODE_RADIUS);
    // The pill is not mirrored at all — it is read from the same module the
    // renderer sets the type from, and this is that arithmetic stated once
    // more from the outside. A padding change in `stage-labels.ts` moves both
    // sides of this together; a padding change made at either call site moves
    // only one, and `stage-labels.test.ts` is what refuses that.
    const label = "carol (exporter)";
    const pill = pillSize(label.length, NODE_LABEL, false);
    const box = nodeFootprint(label, false);
    assertEquals(box.halfWidth, pill.width / 2);
    assertEquals(box.below, NODE_RADIUS + NODE_LABEL_GAP_PX + pill.height);
    // And the label really is measured: a longer name is a wider box, in the
    // family the renderer draws that kind of label in.
    const short = nodeFootprint("ab", true);
    const long = nodeFootprint("ab".repeat(20), true);
    assert(
      long.halfWidth > short.halfWidth * 4,
      `a 40-character label measured ${long.halfWidth}, barely more than a two-character one at ${short.halfWidth}`,
    );
    // A short label still leaves the body as the widest thing at the node.
    assertEquals(short.halfWidth, NODE_RADIUS);
  },
);

layoutTest(
  "an end's box is the shortened designator the stage writes, not the whole one",
  () => {
    // The two halves of one fact. The stage shortens a long designator before
    // drawing it, so the room reserved for that end has to be the room the
    // shortened pill takes — reserving for the whole sixty-four characters
    // would hold a hub's ends a pill's width apart for a label nobody draws,
    // and the fan would not fit on one ring.
    const hostId = "9f".repeat(32);
    const drawn = endpointLabelText(hostId);
    const doc = hubDoc([hostId]);
    const at = settled(doc);
    const end = at.get("s0::b");
    const hub = at.get("hub");
    assert(end !== undefined && hub !== undefined);
    // What the solver kept clear, measured against what is written there.
    const box = nodeFootprint(drawn, true);
    assertEquals(
      box.halfWidth,
      pillSize(drawn.length, NODE_LABEL, true).width / 2,
    );
    assert(
      box.halfWidth < nodeFootprint(hostId, true).halfWidth / 2,
      "shortening the designator did not shrink the box the solver reserves",
    );
    // And the pair really settled: the end is on stage at a place of its own
    // rather than on top of the hub it belongs to.
    assert(Math.hypot(end.x - hub.x, end.y - hub.y) > NODE_RADIUS * 2);
  },
);

layoutTest(
  "a peer's box is the shortened caption the stage writes, not the whole one",
  () => {
    // The same fact on the peer side, and the reason it is a separate test:
    // a peer with no stated name wears its id, which for a wire-derived peer
    // is as long as any designator. The renderer shortens it; if the solver
    // did not, two such peers would be held a whole pill apart for text
    // nobody draws.
    const long = `pancake-peer-${"b4".repeat(40)}`;
    const doc = pairDoc(long);
    const at = settled(doc);
    const p0 = at.get("p0");
    const p1 = at.get("p1");
    assert(p0 !== undefined && p1 !== undefined);

    const drawn = peerLabelText(long);
    const drawnBox = nodeFootprint(drawn, false);
    assertEquals(
      drawnBox.halfWidth,
      pillSize(drawn.length, NODE_LABEL, false).width / 2,
    );
    // What the reservation has to buy: the captions the stage really writes
    // clear each other.
    assert(
      boxOverlap(p0, drawnBox, p1, drawnBox) <= 0,
      "two long-captioned peers overlap the labels they actually draw",
    );
    // And what it must not buy: room for the whole string. Nothing but the
    // caption differs between these two documents, so a solver measuring
    // what the stage draws settles them identically. One that measures the
    // whole caption stands the long pair further apart — for text nobody
    // writes — and the two pictures come apart.
    const asDrawn = settled(pairDoc(drawn));
    assertEquals(
      [p0, p1],
      [asDrawn.get("p0"), asDrawn.get("p1")],
      "the pair laid out differently from the caption the stage draws for it",
    );
  },
);

layoutTest("wide labels are kept out of each other", () => {
  // The screenshot this work started from: ends whose labels were several
  // times wider than the bodies they named, overlapping constantly. Every
  // node here wears a full-length designator, so the labels are the only
  // thing deciding how much room the graph needs.
  const doc = hubDoc(
    Array.from({ length: 8 }, (_, i) => String.fromCharCode(97 + i).repeat(48)),
  );
  const at = settled(doc);
  const boxes = new Map(
    [...at.keys()].map((
      id,
    ) => [
      id,
      id === "hub" ? nodeFootprint("hub", false) : nodeFootprint(
        // The label the stage actually writes under the end, which is what
        // the solver reserved for: a designator this long is shortened
        // before it is drawn.
        endpointLabelText(String.fromCharCode(97 + Number(id[1])).repeat(48)),
        true,
      ),
    ]),
  );
  const ids = [...at.keys()];
  for (let i = 0; i < ids.length; i++) {
    for (let j = i + 1; j < ids.length; j++) {
      const overlap = boxOverlap(
        at.get(ids[i]!)!,
        boxes.get(ids[i]!)!,
        at.get(ids[j]!)!,
        boxes.get(ids[j]!)!,
      );
      assert(
        overlap <= 0,
        `${ids[i]} and ${ids[j]} reach ${overlap.toFixed(0)} into each other's drawing`,
      );
    }
  }
});

layoutTest(
  "a wide label costs sideways room, not room in every direction",
  () => {
    // What the box buys over a circle, and the reason the separation is not
    // simply `forceCollide` with a bigger radius. A long display name's pill is
    // several hundred units across; a circle wide enough to clear it sideways
    // clears it upward too, so every node ends up demanding its widest
    // dimension in every direction — the dense-middle, empty-margin picture.
    // Two nodes wearing wide labels are free to sit one above the other, and
    // here they do, closer than a circle sized for the label would ever have
    // let them.
    //
    // A peer's display name rather than a designator, because a designator is
    // shortened before it is drawn and can no longer be the widest thing on
    // the stage. A name a person chose is not shortened, so it still can.
    const name = "a".repeat(48);
    const width = nodeFootprint(name, false).halfWidth * 2;
    const at = [...settled(namedHubDoc(name, 6)).values()];
    let closest = Infinity;
    for (let i = 0; i < at.length; i++) {
      for (let j = i + 1; j < at.length; j++) {
        closest = Math.min(
          closest,
          Math.hypot(at[i]!.x - at[j]!.x, at[i]!.y - at[j]!.y),
        );
      }
    }
    assert(
      closest < width,
      `the closest pair sits ${closest.toFixed(0)} apart with labels ${
        width.toFixed(0)
      } wide, which is the separation a circle would have insisted on`,
    );
    // And not so close that the bodies crowd: the box still holds them a body
    // and its label apart in the direction that matters.
    assert(
      closest > NODE_RADIUS * 4,
      `the closest pair sits ${closest.toFixed(0)} apart`,
    );
  },
);

layoutTest("a peer's unattributed ends fan around it", () => {
  // Every node with no region prefix used to seed on the same point, so the
  // solver started from a pile and broke the tie however its repulsion
  // happened to: a peer's ends came out gathered on one side of it, with a
  // wedge of empty canvas opposite. The seed is a phyllotaxis spiral now, so
  // the ends start apart and stay apart.
  const at = settled(hubDoc(Array.from({ length: 8 }, () => undefined)));
  const hub = at.get("hub");
  assert(hub !== undefined);
  const angles = [...at.entries()]
    .filter(([id]) => id !== "hub")
    .map(([, p]) => Math.atan2(p.y - hub.y, p.x - hub.x))
    .sort((a, b) => a - b);
  let widest = angles[0]! + Math.PI * 2 - angles[angles.length - 1]!;
  for (let i = 1; i < angles.length; i++) {
    widest = Math.max(widest, angles[i]! - angles[i - 1]!);
  }
  // An even fan of eight leaves a quarter turn between neighbours. Allow half
  // as much again for the pull of the links, and no more: at twice the even
  // share the ends have visibly taken one side.
  const even = (Math.PI * 2) / angles.length;
  assert(
    widest < even * 1.5,
    `the widest empty wedge around the peer is ${
      (widest / even).toFixed(2)
    } times an even share, so its ends are bunched`,
  );
});

/** One pass of the separation force over nodes starting at these points,
 *  answering where each would be once its velocity is integrated. Every node
 *  wears a bare body, and the padding is zero, so the room a pair needs is
 *  simply two half-widths. */
function afterOnePass(at: readonly Vec2[]): Vec2[] {
  const box = nodeFootprint("", false);
  const boxes = new Map(at.map((_, i) => [`n${i}`, box]));
  const nodes = at.map((p, i) => ({
    id: `n${i}`,
    x: p.x,
    y: p.y,
    vx: 0,
    vy: 0,
  }));
  const force = forceFootprints(boxes, 0, 1);
  force.initialize(nodes);
  force();
  return nodes.map((n) => ({ x: n.x + n.vx, y: n.y + n.vy }));
}

layoutTest(
  "two nodes on one point are pushed apart, wherever they sit in the array",
  () => {
    // A pile has no line to separate along, so the force invents a ray for it.
    // The ray used to be handed to arithmetic that grows an EXISTING gap, and a
    // pile has none: at the first index the ray runs along x, the growth factor
    // came out exactly one, and the pair was left stacked for every remaining
    // tick. At every other index it moved a fraction of the distance it needed.
    //
    // One pass with nothing else acting, because a whole solve's charge would
    // separate a pile anyway and hide the whole thing.
    const box = nodeFootprint("", false);
    const needX = box.halfWidth * 2;
    const needY = box.above + box.below;
    const clears = (p: Vec2, q: Vec2): boolean =>
      Math.abs(p.x - q.x) >= needX - 1e-9 ||
      Math.abs(p.y - q.y) >= needY - 1e-9;

    // The pair the first index owns, which is the one that never moved at all.
    const first = afterOnePass([{ x: 0, y: 0 }, { x: 0, y: 0 }]);
    assert(
      clears(first[0]!, first[1]!),
      `the first pair came out of the pass ${
        Math.hypot(first[0]!.x - first[1]!.x, first[0]!.y - first[1]!.y)
          .toFixed(1)
      } apart, still inside each other's boxes`,
    );

    // And a pair further along, which moved but nothing like far enough. The
    // node ahead of them sits well clear so only the pile is in play.
    const later = afterOnePass([{ x: 900, y: 900 }, { x: 0, y: 0 }, {
      x: 0,
      y: 0,
    }]);
    assert(
      clears(later[1]!, later[2]!),
      `a later pair came out of the pass ${
        Math.hypot(later[1]!.x - later[2]!.x, later[1]!.y - later[2]!.y)
          .toFixed(1)
      } apart, still inside each other's boxes`,
    );

    // The fan is still deterministic, and it is still a fan: two piles at
    // different indices leave along different rays.
    assertEquals(afterOnePass([{ x: 0, y: 0 }, { x: 0, y: 0 }]), first);
  },
);

/** The layout as a comparable value: every keyframe's placements, in one
 *  string per node so a failure names the node that moved. */
function placements(doc: TimelineDocument): string[][] {
  return new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG).keyframes.map(
    (k) =>
      [...k.layout.entries()]
        .map(([id, p]) => `${id}:${p.x}:${p.y}`)
        .sort(),
  );
}

/** The same document with its observations stated in the opposite order. Same
 *  topology, same moments, different insertion order. */
function reordered(doc: TimelineDocument): TimelineDocument {
  const source = (doc as unknown as {
    recording: { sources: Array<{ observations: unknown[] }> };
  }).recording.sources[0]!;
  return {
    ...doc,
    recording: {
      sources: [{
        ...source,
        observations: [...source.observations].reverse(),
      }],
    },
  } as unknown as TimelineDocument;
}

layoutTest("the same document lays out identically every time", () => {
  // Half the contract the whole file is built on: no randomness and no wall
  // clock, so scrubbing forward and back visits the same pixels. Two runs of
  // one document is exactly what that catches and no more — a stray
  // `Math.random` or `Date.now` anywhere in the solve.
  const doc = () =>
    hubDoc([
      undefined,
      undefined,
      "tcp://198.51.100.4:9001",
      undefined,
      undefined,
    ]);
  assertEquals(placements(doc()), placements(doc()));
});

layoutTest(
  "the same topology lays out identically whatever order it was stated in",
  () => {
    // The other half, and the one two runs of one document cannot reach. The
    // solve walks nodes in array order and the separation force reads and writes
    // velocities in that order, so a tie broken by position in the array would
    // be perfectly repeatable and still wrong: the same graph, saved by two
    // authors who added their peers in different orders, would settle into two
    // different pictures. Every ordering-sensitive step is sorted for this
    // reason — the node ids, and the session ids a bundle's lanes are numbered
    // by — and this is what says so.
    const doc = hubDoc([
      undefined,
      "tcp://198.51.100.4:9001",
      undefined,
      "tcp://203.0.113.9:9001",
    ]);
    assertEquals(placements(doc), placements(reordered(doc)));
  },
);

// ──────────────── when each thing arrives, and when it leaves ────────────────

/** A document with a peer nothing announces beside peers that observations
 *  do, so both halves of the moment stream are in play. `timing` is stated
 *  where the test wants the declared entity to arrive and leave. */
function declaredAndObservedDoc(
  timing?: { start: number; duration: number },
): TimelineDocument {
  return {
    id: "declared-and-observed",
    duration: 2000,
    entities: {
      peers: {
        authored: {
          profile: "pancake",
          ...(timing !== undefined
            ? {
              timing: {
                start: { value: timing.start, explicit: true },
                duration: { value: timing.duration, explicit: true },
              },
            }
            : {}),
        },
      },
    },
    recording: {
      sources: [{
        id: "fixture",
        meta: { kind: "fixture" },
        observations: [
          {
            id: "j-carol",
            t: 0,
            kind: "peer-joined",
            peerId: "carol",
            profile: "pancake",
          },
          {
            id: "j-bob",
            t: 0,
            kind: "peer-joined",
            peerId: "bob",
            profile: "pancake",
          },
          {
            id: "o-s",
            t: 0,
            kind: "session-opened",
            sessionId: "s",
            a: attachedEndpoint("carol"),
            b: attachedEndpoint("bob"),
            codec: "syrup",
            captpVersion: "v1_0",
          },
        ],
      }],
    },
  } as unknown as TimelineDocument;
}

layoutTest("one moment is one keyframe", () => {
  // A keyframe list is one layout per moment. When the entities the document
  // declares were seeded as a keyframe of their own, a document that also
  // observed something at t=0 got two keyframes at that one moment: the
  // second read as the era in force and the first as the era before it, so at
  // t=0 the stage drew the seed and then slid into the real layout over the
  // whole transition window. Nothing had changed, and scrubbing back replayed
  // it every time.
  const system = new KeyframeLayoutSystem(declaredAndObservedDoc());
  const moments = system.keyframes.map((kf) => kf.t);
  assertEquals(
    moments.length,
    new Set(moments).size,
    `two keyframes at one moment: ${moments.join(", ")}`,
  );
});

layoutTest("nothing moves through a window in which nothing changed", () => {
  // The consequence, in the pixels. The window after t=0 is the transition
  // window, which is exactly where the duplicate moment was visible.
  const doc = declaredAndObservedDoc();
  const system = new KeyframeLayoutSystem(doc);
  const world = new World<Components>();
  materializeWorldAt(world, doc, 0);
  system.update(world, 0);
  const startOfWindow = new Map(
    [...world.with("peer", "position")].map((
      e,
    ) => [e.peer.id, { x: e.position.x, y: e.position.y }]),
  );
  system.update(world, DEFAULT_LAYOUT_CONFIG.transitionWindow / 2);
  for (const e of world.with("peer", "position")) {
    const was = startOfWindow.get(e.peer.id);
    assert(was !== undefined);
    assertEquals(
      { x: e.position.x, y: e.position.y },
      was,
      `${e.peer.id} drifted through a window in which nothing happened`,
    );
  }
});

layoutTest(
  "an entity only the document declares keeps to its own timing",
  () => {
    // Nothing announces an entity authored in Build, so its declared timing is
    // what says when it arrives and when it leaves — the same two moments an
    // observed entity's join and departure state. Seeded into every era
    // instead, it was a body in the solve before it existed, holding space
    // against peers that were standing there and taking none of its own when it
    // finally was.
    const doc = declaredAndObservedDoc({ start: 800, duration: 200 });
    const eras = new KeyframeLayoutSystem(doc).keyframes;
    const at = (t: number) =>
      [...eras].reverse().find((kf) => kf.t <= t)?.layout ?? new Map<
        string,
        Vec2
      >();
    assertEquals(
      at(0).has("authored"),
      false,
      "a peer timed to a later window held a place in the first era",
    );
    assertEquals(
      at(900).has("authored"),
      true,
      "a peer never arrived in the window its timing declares",
    );
    assertEquals(
      at(1100).has("authored"),
      false,
      "a peer outstayed the window its timing declares",
    );
  },
);

layoutTest(
  "settled update still lands a placement recompute",
  () => {
    // Past the transition window, `update` skips rewriting positions.
    // A pin must still land: recomputeForPlacement bumps the layout
    // generation so the next update cannot keep the pre-pin coords.
    const doc = TimelineDocument.parse({
      id: "settled-placement",
      duration: 5000,
      layoutMode: "authored",
      events: [
        {
          id: "a0",
          t: 0,
          kind: "peer-joined",
          peerId: "a",
          profile: "pancake",
          position: { x: 0, y: 0 },
        },
        {
          id: "b0",
          t: 0,
          kind: "peer-joined",
          peerId: "b",
          profile: "goblins",
          position: { x: 100, y: 0 },
        },
      ],
    });
    const layout = new KeyframeLayoutSystem(doc);
    const world = new World<Components>() as GameWorld;
    materializeWorldAt(world, doc, 0);
    const settledT = DEFAULT_LAYOUT_CONFIG.transitionWindow + 50;
    layout.update(world, settledT);
    layout.update(world, settledT); // second call is the early-out
    const beforePos = [...world.with("peer", "position")].find((e) => e.peer.id === "a")!
      .position;
    const before = { x: beforePos.x, y: beforePos.y };
    doc.entities!.peers!.a!.position = { x: 40, y: 40 };
    layout.recomputeForPlacement();
    layout.update(world, settledT);
    const after = [...world.with("peer", "position")].find((e) => e.peer.id === "a")!
      .position;
    assertEquals(
      { x: after.x, y: after.y },
      { x: 40, y: 40 },
      "a settled early-out kept the pre-pin position after placement",
    );
    assert(
      before.x !== after.x || before.y !== after.y,
      "the peer was already at the pin, so this test proves nothing",
    );
  },
);
