/**
 * Grows a hand-built corpus by a whole-number factor, for measuring how the
 * visualizer scales rather than how fast it is.
 *
 * Absolute milliseconds on one document say almost nothing: a profile of
 * `the-kids-masterpiece.json` puts every function in `src/` together at a
 * fraction of a percent, which rules out a hot function and rules nothing else
 * out. What a stutter needs is the SHAPE of the curve — four times the entities
 * costing four times the work is a renderer doing its job, and costing sixteen
 * times is a quadratic hiding under a small constant.
 *
 * So this keeps everything about the source document except how much of it there
 * is, and holds the stage area fixed. Density is the point: spreading the extra
 * entities over a proportionally larger stage would leave every neighbourhood
 * looking exactly as it did, and it is the neighbourhoods that do the expensive
 * work — labels dodging each other, edge chips walking their corridors, curves
 * bundling between the same pair of peers.
 *
 * Each factor is generated from a fixed seed, so a run is reproducible and two
 * runs of the same factor measure the same picture.
 *
 *   deno task stress-tests        # 4x, 8x, 16x, 32x, 64x
 */

type Timing = {
  start: { value: number; explicit: boolean };
  duration: { value: number; explicit: boolean };
};

type Doc = {
  id: string;
  metadata: Record<string, string>;
  provenance?: Record<string, unknown>;
  duration: number;
  entities: {
    peers: Record<
      string,
      {
        profile: string;
        label: string;
        position: { x: number; y: number };
        timing: Timing;
      }
    >;
    sessions: Record<
      string,
      {
        a: { peer: string };
        b: { peer: string };
        codec: string;
        captpVersion: string;
        initialState: string;
        timing: Timing;
      }
    >;
    messages: Record<
      string,
      { sessionId: string; from: string; to: string; timing: Timing }
    >;
  };
};

/** Mulberry32 — small, seeded, and good enough to place nodes with. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function stressTest(source: Doc, factor: number, seed = SEED): Doc {
  const rand = rng(seed);
  const pick = <T>(xs: readonly T[]): T =>
    xs[Math.floor(rand() * xs.length)] as T;

  const srcPeers = Object.values(source.entities.peers);
  const srcSessions = Object.values(source.entities.sessions);
  const srcMessages = Object.values(source.entities.messages);

  // The stage the source occupies, so the copies land in the same room.
  const xs = srcPeers.map((p) => p.position.x);
  const ys = srcPeers.map((p) => p.position.y);
  const box = {
    x0: Math.min(...xs),
    x1: Math.max(...xs),
    y0: Math.min(...ys),
    y1: Math.max(...ys),
  };

  const peers: Doc["entities"]["peers"] = {};
  const peerIds: string[] = [];
  const profiles = srcPeers.map((p) => p.profile);
  for (let i = 0; i < srcPeers.length * factor; i++) {
    const id = `peer-${i + 1}`;
    peerIds.push(id);
    peers[id] = {
      profile: pick(profiles),
      label: id,
      position: {
        x: box.x0 + rand() * (box.x1 - box.x0),
        y: box.y0 + rand() * (box.y1 - box.y0),
      },
      timing: {
        start: { value: 0, explicit: true },
        duration: { value: 0, explicit: false },
      },
    };
  }

  // Session starts are drawn from the source's own, so the arrival pattern over
  // the timeline keeps its shape — a stutter that only shows when a group lands
  // needs the groups.
  const starts = srcSessions.map((s) => s.timing.start.value);
  const sessions: Doc["entities"]["sessions"] = {};
  const sessionIds: string[] = [];
  for (let i = 0; i < srcSessions.length * factor; i++) {
    const id = `session-${i + 1}`;
    const a = pick(peerIds);
    let b = pick(peerIds);
    while (b === a) b = pick(peerIds);
    const shape = pick(srcSessions);
    sessionIds.push(id);
    sessions[id] = {
      a: { peer: a },
      b: { peer: b },
      // Both codecs and both versions, whatever the source happened to use.
      // The source is entirely capnp over 1.0, and a dashed wire is the
      // expensive one to draw — it is walked in 24 samples and stroked twice, so
      // a stress test made only of solid wires never reaches the path most
      // likely to give way. The state is left as the source set it, because a
      // session that is not open may not be drawn at all, and a stress test that
      // quietly stops drawing things is measuring less than it claims.
      codec: rand() < 0.5 ? "capnp" : "syrup",
      captpVersion: rand() < 0.5 ? "v1_0" : "next",
      initialState: shape.initialState,
      timing: {
        start: { value: pick(starts), explicit: true },
        duration: { value: 0, explicit: false },
      },
    };
  }

  // A message rides a session and names that session's own two peers, which the
  // source holds without exception and the picture depends on.
  const messages: Doc["entities"]["messages"] = {};
  for (let i = 0; i < srcMessages.length * factor; i++) {
    const id = `msg-${i + 1}`;
    const sessionId = pick(sessionIds);
    const session = sessions[sessionId]!;
    const forward = rand() < 0.5;
    const shape = pick(srcMessages);
    messages[id] = {
      sessionId,
      from: forward ? session.a.peer : session.b.peer,
      to: forward ? session.b.peer : session.a.peer,
      timing: {
        start: {
          value: Math.min(
            source.duration - 1,
            Math.max(0, session.timing.start.value + rand() * 600),
          ),
          explicit: true,
        },
        duration: { value: shape.timing.duration.value, explicit: true },
      },
    };
  }

  const nPeers = Object.keys(peers).length;
  const nSessions = Object.keys(sessions).length;
  const nMessages = Object.keys(messages).length;
  const total = nPeers + nSessions + nMessages;
  return {
    id: `stress-${factor}x`,
    metadata: {
      "dct:title": `Stress test ${factor}\u00d7 \u2014 ${total} entities`,
      "dct:description": `${nPeers} peers, ${nSessions} sessions and ` +
        `${nMessages} messages in flight over ` +
        `${(source.duration / 1000).toFixed(2)}s, which is ${source.id} at ` +
        `${factor}\u00d7 on the same patch of stage, with both codecs and both ` +
        `CapTP versions mixed through it so the dashed wires are drawn too. ` +
        `Fit it in view before ` +
        `judging anything, because off-screen entities are culled and an ` +
        `unfitted reading measures whatever happened to be visible. No real ` +
        `session is this crowded: the point is to find where the renderer ` +
        `gives way, and this one is two kids' afternoon in Build mode ` +
        `photocopied ${factor} times.`,
      "dct:creator": "pancake project",
      "dct:created": GENERATED_AT,
    },
    provenance: {
      "prov:wasGeneratedBy": "apps/ocapnviz/test-data/make-stress-tests.ts",
      "prov:wasDerivedFrom": [source.id],
      "prov:wasAttributedTo": source.metadata["dct:creator"] ??
        "pancake project",
      "prov:generatedAtTime": GENERATED_AT,
      "dct:source": "apps/ocapnviz/test-data/the-kids-masterpiece.json",
      "dct:identifier": `stress-${factor}x, seed 0x${SEED.toString(16)}`,
    },
    duration: source.duration,
    entities: { peers, sessions, messages },
  };
}

/** Stamped rather than read off a clock, so regenerating a factor rewrites the
 *  same bytes and `git status` stays quiet. */
const GENERATED_AT = "2026-08-06T00:00:00Z";
const SEED = 0x5eed;

/** What `deno task stress-tests` writes with no arguments. 4x is comfortable,
 *  8x is where a frame starts to cost real time, and 64x is past the ceiling. */
const STANDARD_FACTORS = [4, 8, 16, 32, 64] as const;

if (import.meta.main) {
  const factors = Deno.args.length > 0
    ? Deno.args.map(Number)
    : [...STANDARD_FACTORS];
  if (factors.some((f) => !Number.isInteger(f) || f < 2)) {
    console.error(
      "usage: make-stress-tests.ts [factor \u2026]   (whole, 2 or more)",
    );
    Deno.exit(2);
  }
  const here = new URL(".", import.meta.url).pathname;
  const source: Doc = JSON.parse(
    await Deno.readTextFile(`${here}the-kids-masterpiece.json`),
  );
  for (const factor of factors) {
    const doc = stressTest(source, factor);
    const path = `${here}stress-${factor}x.json`;
    await Deno.writeTextFile(path, `${JSON.stringify(doc, null, 2)}\n`);
    const n = Object.keys(doc.entities.peers).length +
      Object.keys(doc.entities.sessions).length +
      Object.keys(doc.entities.messages).length;
    const kb = (await Deno.stat(path)).size / 1024;
    console.log(
      `stress-${factor}x.json  ${String(n).padStart(6)} entities  ${
        kb.toFixed(0).padStart(5)
      }KB`,
    );
  }
}
