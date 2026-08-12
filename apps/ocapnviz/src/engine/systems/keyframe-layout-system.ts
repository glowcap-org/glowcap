import {
  forceCenter,
  forceLink,
  forceManyBody,
  forceSimulation,
  forceX,
  forceY,
  type SimulationLinkDatum,
  type SimulationNodeDatum,
} from "d3-force";
import {
  endpointNodeId,
  endpointStageId,
  parseEndpointStageId,
  SESSION_SIDES,
} from "../../schema/topology.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { containsTime } from "../temporal/range.ts";
import { peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import {
  claimedPeerByEnd,
  claimsOnStage,
  endpointClaims,
  sessionEnds,
} from "../claims.ts";
import type { GameWorld, Vec2 } from "../world.ts";
import {
  bezierAt,
  bundleIndices,
  curveBetween,
  type SessionBundleEntry,
} from "../session-geometry.ts";
import { type EasingFn, smoothstep } from "../easing.ts";
import {
  endpointLabelText,
  NODE_LABEL,
  NODE_LABEL_GAP_PX,
  peerLabelText,
  pillSize,
} from "../../render/stage-labels.ts";
import { authoredPins } from "../event-helpers.ts";

/**
 * KeyframeLayoutSystem — node positions as a pure function of `t`.
 *
 * Nodes here are peers and session ends alike. An end whose `peer` field is
 * absent is LOOSE: nothing proved who is on it, so `endpointNodeId` gives it a
 * node of its own keyed by `sessionId::side`, its stage id. A loose end that
 * `engine/claims.ts` resolves to a peer is a CLAIM about that peer, and
 * `CLAIM_LEAN` decides where it sits. Throughout this file "claim" means that
 * end, never the designator string it carries.
 *
 * Precomputes one d3-force convergence per distinct topology at
 * construction, stores them as keyframes, then at runtime writes
 * each peer's position as an eased lerp between the surrounding
 * keyframes. Scrubbing forward and back visits identical positions
 * because there is no integration history.
 *
 * Cost: one convergence per era, and an era per moment the topology changes.
 * A loaded document has a handful; a live feed has as many as the connection
 * has been up for, because every session that opens and closes is two moments.
 * A recompute reuses the arrangement it already holds for every era whose
 * problem is unchanged, which is what keeps an append from re-annealing the
 * whole timeline: sixty reconnects against a three-peer room cost 4.7 seconds
 * of solving without that reuse and 194 ms with it, measured on one machine, so
 * read the ratio rather than the numbers.
 *
 * The era count itself still grows with the connection, and every recompute
 * re-walks the whole timeline to key each era even when every one of them is
 * reused, so per-recompute work grows with uptime. About 5 ms at 243 eras.
 * `recomputeForPlacement` tries each era's prior layout as an equilibrium
 * before annealing, so a drag pays `runForce` only for eras the pin actually
 * disturbs. Passing the previous list alone is not enough: a moved pin changes
 * that era's problem key, and problem-key reuse would miss.
 *
 * A topology that is replaced before its own arrival can finish being shown is
 * still given a keyframe. The runtime does not jump through it: each era eases
 * from where the picture actually was when the era began rather than from the
 * previous era's arrangement, so an era that had two milliseconds contributes
 * two milliseconds' worth. `Keyframe.start` owns that, and
 * `era-reuse.test.ts` holds the excursion across a reconnect under a tenth of a
 * node's width. What remains is the cost of the extra keyframe, not a visible
 * jump. Two bounds for "too short to keep" were tried and both were wrong:
 * one frame is not a fixed number of simulated milliseconds because the clock
 * scales by playback speed, and the transition window deletes eras a document
 * legitimately states 100 ms apart. It stays unbounded until there is a bound
 * that is derived rather than chosen.
 */

type Layout = Map<string, Vec2>;
/**
 * One converged arrangement, and the solver problem it came from.
 *
 * The key rides along because what the solver is asked at one moment cannot be
 * changed by anything that happens later. So a recompute over a document that
 * only gained observations at the end can hand back the arrangement it already
 * holds for every moment whose problem is unchanged, instead of re-annealing the
 * whole timeline.
 *
 * It is not a claim that the arrangement is the one a cold solve would produce.
 * `recomputeForPlacement` deliberately keeps an era's existing arrangement when a
 * pin lands within epsilon of where that era already had the peer, because
 * re-annealing would settle a different basin and move every free peer to
 * announce a pin that changed nothing. That arrangement is stamped with its
 * problem and reused from then on, so a document grown by dragging can hold an
 * arrangement a freshly loaded copy of the same document would not. That
 * placement history is the older decision and this one preserves it; what
 * neither of them is, is a pure function of the document alone.
 */
/**
 * One era before the walk has worked out what it eases from: a moment, the
 * arrangement solved for it, and the problem that arrangement answers.
 *
 * Everything that produces eras produces these, and `sealEras` is the only way
 * to get a `Keyframe` out of them. That is deliberate. `start` is a property of
 * an era's position in the LIST rather than of the era itself, so a site
 * building one by hand cannot know it — and a site that guessed it wrong made
 * every era it touched snap instead of ease, which is a defect no type caught
 * while the field was simply there to be set.
 */
type Era = {
  t: number;
  layout: Layout;
  problem: string;
};

type Keyframe = Era & {
  /**
   * Where the picture actually is when this era begins, which is what its ease
   * starts from.
   *
   * Not the previous era's arrangement. That is the same thing whenever the
   * previous era had a full transition window to finish in, and wrong when it did
   * not: an era replaced two milliseconds after it arrived was never approached,
   * so easing from it puts every node somewhere it has never been, in one frame.
   * A room reconnecting every few seconds read as the whole room being thrown and
   * pulled back, on the period of the reconnect.
   *
   * Derived by walking the eras in order, because it is a pure function of the
   * list: each era's start is the previous era's start eased toward the previous
   * era's arrangement by as much time as that era actually had. Doing it there
   * rather than in `update` is what keeps the runtime at one lerp per node —
   * reconstructing the chain per frame is O(eras) per node, and on a document
   * whose eras all sit closer together than the window that is every era, every
   * frame.
   */
  readonly start: Layout;
};

/**
 * The problem key of a mode that solves once over the whole document.
 *
 * `static-union` and `authored` produce a single keyframe rather than one per
 * era, so there is no per-moment problem to compare and nothing for the reuse
 * above to match against. Naming that rather than inventing a key keeps a
 * single-keyframe mode from ever appearing to have reusable eras.
 */
const SINGLE_KEYFRAME = "(single)";

type SimNode = SimulationNodeDatum & { id: string };
type SimLink = SimulationLinkDatum<SimNode> & { id: string };

/**
 * Layout-recompute policy.
 *
 *   "per-topology"  Every distinct topology along the timeline gets
 *                   its own d3-force convergence. Peers lerp between
 *                   keyframes when the topology changes — visually
 *                   honest about reconfiguration, but peers move.
 *
 *   "static-union"  One d3-force convergence at engine construction
 *                   over the *union* of every peer and session that
 *                   ever exists. Peers stay put for the entire
 *                   scenario; new sessions just appear as edges
 *                   between already-positioned nodes.
 *
 *   "authored"      Honors the `position` field on each peer-joined
 *                   event verbatim; no d3-force runs. Used when a
 *                   fixture has placed every peer explicitly.
 *                   Peers without an authored position land at the
 *                   origin (caller is expected to provide them).
 *
 * In both force modes an authored position is a PIN: the peer sits
 * at exactly that position in every keyframe (fixed `fx`/`fy` in
 * the simulation) while its links still pull neighbors into place
 * around it. Default is "per-topology" — fixtures that prefer
 * stillness opt in via `layoutMode: "static-union"`.
 */
export type LayoutMode = "per-topology" | "static-union" | "authored";

export type LayoutConfig = {
  mode: LayoutMode;
  chargeStrength: number;
  linkDistance: number;
  linkStrength: number;
  /**
   * Empty space kept around everything a node draws, in world units. The
   * solver separates footprints (`nodeFootprint`) grown by this much, so it
   * is the daylight a reader sees between one node's label and the next
   * node's body rather than a radius around a point.
   */
  nodeSpacing: number;
  iterations: number;
  centerStrength: number;
  /** Milliseconds over which a topology change interpolates. */
  transitionWindow: number;
  /** Easing curve applied to the transition progress. */
  easing: EasingFn;
};

export const DEFAULT_LAYOUT_CONFIG: LayoutConfig = {
  mode: "per-topology",
  // Tuned so a small graph (3-5 peers) fills the canvas comfortably
  // at default zoom rather than huddling around the centroid. Edges are long
  // enough that their `codec · captp` chips never abut a node.
  chargeStrength: -3600,
  linkDistance: 520,
  linkStrength: 0.4,
  // Ninety leaves two bare bodies 240 apart, a node's width of daylight
  // either side of the 60 between their edges. A node wearing a label needs
  // more room than that in one axis and no more in the other, which is what
  // makes the separation a box rather than a circle.
  nodeSpacing: 90,
  iterations: 500,
  centerStrength: 0.02,
  transitionWindow: 600,
  easing: smoothstep,
};

// ───────────────────── what a node occupies ─────────────────────

/**
 * Half a node's body, in world units. It mirrors `NODE_RADIUS` in
 * `src/render/draw-helpers.ts`, which is the authority for what is drawn;
 * `keyframe-layout-system.test.ts` reads that one and asserts the two agree,
 * so the mirror cannot drift silently. It is a mirror rather than an import
 * because `draw-helpers.ts` reads `session-geometry.ts`, which the renderer
 * also reaches this file through; the label's own sizes have no such problem
 * and are imported from the leaf `render/stage-labels.ts`.
 */
const NODE_HALF_WIDTH = 30;

/**
 * What one node covers on the canvas, as an axis-aligned box around its
 * position: half the width of the widest thing drawn there, and how far the
 * drawing reaches above and below the point itself.
 *
 * Asymmetric because the label hangs below the body, which is the whole
 * reason a circle was the wrong model. Two nodes side by side must clear each
 * other's labels; two nodes stacked need only the body-to-label gap, and a
 * circle wide enough for the first spends that width on the second as well.
 *
 * World units at 100% zoom, which is where it matches the drawing. A label
 * holds a fixed screen size as the stage zooms while this box does not, so
 * zooming out grows every label against a graph that stays the size it was
 * solved at. One solve cannot answer every zoom; `render/stage-labels.ts`
 * carries that tension and bounds how wide the worst label gets.
 */
export type NodeFootprint = {
  halfWidth: number;
  above: number;
  below: number;
};

/**
 * The box a node with this label covers. `mono` picks the family the label is
 * drawn in: a designator is a wire identifier and renders monospaced, a peer's
 * display name renders proportionally.
 */
export function nodeFootprint(label: string, mono: boolean): NodeFootprint {
  const pill = pillSize(label.length, NODE_LABEL, mono);
  return {
    halfWidth: Math.max(NODE_HALF_WIDTH, pill.width / 2),
    above: NODE_HALF_WIDTH,
    below: NODE_HALF_WIDTH + NODE_LABEL_GAP_PX + pill.height,
  };
}

/** The footprint of a node the document says nothing about, which is a bare
 *  body. Used for a node that reaches the solver without a label of its own. */
const BARE_FOOTPRINT: NodeFootprint = {
  halfWidth: NODE_HALF_WIDTH,
  above: NODE_HALF_WIDTH,
  below: NODE_HALF_WIDTH,
};

/**
 * Region centroids in render-space coordinates (arbitrary units,
 * not lat/lon). Tags mirror the upstream timeline-source's region
 * vocabulary so the renderer places peers whose id begins with
 * `<region>-` (e.g.
 * `us-east-alice`) on a left-to-right Mercator-ish layout. Lookup
 * is longest-prefix match — `us-east-alice` resolves to `us-east`,
 * `us-alice` falls back to the `us` continental rollup, `alice`
 * lands on `default` (origin).
 */
const REGION_CENTROIDS: Record<string, Vec2> = {
  "us-west": { x: -560, y: -40 },
  "us-east": { x: -380, y: -30 },
  "sa-east": { x: -260, y: 260 },
  "eu-west": { x: 20, y: -200 },
  "eu-central": { x: 100, y: -180 },
  "ap-southeast": { x: 480, y: 40 },
  "ap-northeast": { x: 520, y: -80 },
  "us": { x: -480, y: -60 },
  "na": { x: -480, y: -60 },
  "sa": { x: -260, y: 260 },
  "eu": { x: 60, y: -180 },
  "af": { x: 80, y: 160 },
  "ap": { x: 480, y: -20 },
  "as": { x: 480, y: -20 },
  "oc": { x: 540, y: 280 },
  "default": { x: 0, y: 0 },
};

/**
 * Per-region pull strength. Strong enough to keep peers inside
 * their cluster, weak enough that link forces can still bend the
 * cluster toward partners.
 */
const REGION_PULL_STRENGTH = 0.35;

/**
 * How far along its own session's edge a claim sits, measured from the far end
 * of that session toward the peer the claim names.
 *
 * The drawn edge ends AT the claim, because the claim is the node that end of
 * the session sits on. So what a reader sees is a wire stopping in open space
 * beside somebody rather than a wire reaching them, which is what an unbacked
 * claim amounts to. When attribution lands the end is gone and the edge
 * terminates on the peer, with nothing else in the picture moving, because the
 * session was solved to that peer all along.
 *
 * Two thirds rather than half or three quarters, and the bundled recordings
 * say why. On every session edge they settle, two thirds leaves at least a
 * node's width of daylight between the claim's body and the peer's, and still
 * lands the claim near enough to read as being about that peer rather than as
 * a node standing on its own. Half puts the claim mid-edge, where it reads as
 * a waypoint between two peers rather than as something about one of them.
 * Three quarters brings the claim's own selection ring within a third of a
 * node of the peer's on the shortest of those edges, so picking one of the two
 * would draw a ring all but touching the other. `claim-placement.test.ts`
 * measures those readings over the shipped recordings, so a fixture that moved
 * its peers, or a layout that settled them differently, would take the
 * argument with it.
 *
 * Several claims about one peer need no arrangement, up to a point: each rides
 * its own session's edge, so claims arriving from different peers separate
 * without anything counting them. Claims riding parallel sessions between the
 * SAME pair describe one segment and land on one point; `claim-placement.test`
 * pins that boundary rather than working around it.
 *
 * Exported because the placement tests read it: where a claim sits is asserted
 * as this fraction, so retuning it moves one number, and the daylight that
 * fraction buys is measured against the recordings rather than restated here.
 */
export const CLAIM_LEAN = 2 / 3;

/**
 * Where a claim sits: on the curve its session would take if it reached the
 * peer it names, `CLAIM_LEAN` of the way along.
 *
 * On the curve, not on the chord between them. Sessions sharing a pair fan
 * out into arcs, and a claim rides that fan (`bundleIndices`), so a claim
 * placed on the straight line sat off its own arc — and the edge drawn to it
 * then curved somewhere else again, because a different endpoint is a
 * different chord. Placing it here and drawing the same curve's prefix makes
 * the two agree by construction: the truncated arc ENDS where the claim is.
 */
function claimLeanTo(
  fromId: string,
  from: Vec2,
  towardId: string,
  toward: Vec2,
  bundle: SessionBundleEntry,
): Vec2 {
  return bezierAt(
    curveBetween(fromId, from, towardId, toward, bundle),
    CLAIM_LEAN,
  );
}

/**
 * Longest-prefix region tag for a peer id, or `"default"` if no
 * recognized prefix matches. Two-segment prefixes win over one-
 * segment ones (case-insensitive).
 */
function parseRegion(peerId: string): string {
  const lower = peerId.toLowerCase();
  const parts = lower.split("-");
  if (parts.length >= 3) {
    const two = `${parts[0]}-${parts[1]}`;
    if (two in REGION_CENTROIDS) return two;
  }
  if (parts.length >= 2 && parts[0]! in REGION_CENTROIDS) {
    return parts[0]!;
  }
  return "default";
}

/** Centroid for a peer's region; `(0, 0)` if no prefix matches. */
function regionCentroid(peerId: string): Vec2 {
  return REGION_CENTROIDS[parseRegion(peerId)] ?? REGION_CENTROIDS.default!;
}

export class KeyframeLayoutSystem {
  readonly config: LayoutConfig;
  #doc: TimelineDocument;
  #keyframes: Keyframe[];
  #claims: Map<string, string>;
  /** What the keyframes were last derived from, so a recompute over unchanged
   *  inputs can decline to re-anneal. See `layoutInputSignature`. */
  #inputSignature: string;
  /** Bumped on every recompute so a settled early-out cannot skip a
   *  placement write after the layout maps changed underfoot. */
  #layoutGen = 0;
  /** Keyframe whose progress-1 write has already landed for `#layoutGen`. */
  #settledKeyframe: Keyframe | null = null;
  #settledGen = -1;

  constructor(
    doc: TimelineDocument,
    config: LayoutConfig = DEFAULT_LAYOUT_CONFIG,
  ) {
    this.config = config;
    this.#doc = doc;
    this.#claims = claimedPeerByEnd(doc);
    this.#inputSignature = layoutInputSignature(doc, this.#claims);
    this.#keyframes = computeKeyframes(doc, config, this.#claims);
  }

  /** Read-only keyframes view; tests use this. */
  get keyframes(): readonly Keyframe[] {
    return this.#keyframes;
  }

  /**
   * The peer each claiming end names, for whoever else needs the answer.
   *
   * The renderer needs it every frame and the placement needs it every
   * recompute, and the two must be the same map or an end is drawn as a claim
   * in a lane nothing leaned it into. It is derived here rather than per frame
   * because it is a fact about the document: it changes when the document
   * changes, which is exactly when the keyframes are recomputed.
   */
  get claims(): ReadonlyMap<string, string> {
    return this.#claims;
  }

  /**
   * Point the layout at a replacement doc. The engine re-derives
   * its doc whenever projection touches it (`projectFromObservations`
   * returns a fresh object); the layout must follow, or every
   * doc-reading recompute (pins, topology eras) keeps consulting
   * the abandoned object. Does not recompute — the swap itself
   * changes no observable state, and the callers that mutate the
   * doc afterward already own the recompute.
   */
  rebind(doc: TimelineDocument): void {
    this.#doc = doc;
  }

  /**
   * Recompute keyframes from the (now-grown) recording layer.
   *
   * Live mode appends observations to a `TimelineDocument` after the
   * engine has already constructed its layout. Without recompute,
   * later peers and sessions never make it into a keyframe and so
   * land at their seed position forever. Engine calls this when
   * `drainEvents` applies an observation whose kind changes topology.
   *
   * Cost: one convergence per era whose problem changed, and none for the eras
   * it did not, which is what keeps an append from re-annealing the timeline it
   * already solved. Scrubbing back and forth still visits identical positions,
   * because the keyframes are still a function of `t`.
   */
  recompute(): void {
    const claims = claimedPeerByEnd(this.#doc);
    const signature = layoutInputSignature(this.#doc, claims);
    // Nothing the solver reads has moved, so the layout it would produce is the
    // one already held — at the price of a solve per era, and at the risk of
    // landing in a different basin and moving every free peer to say so. A
    // caller cannot be expected to know which document changes reach the
    // solver; the layout does, so the decision lives here.
    if (signature === this.#inputSignature) return;
    this.#inputSignature = signature;
    this.#claims = claims;
    this.#keyframes = computeKeyframes(
      this.#doc,
      this.config,
      this.#claims,
      this.#keyframes,
    );
    this.#layoutGen += 1;
  }

  /**
   * Recompute for a placement edit, reusing every era whose
   * equilibrium the edit did not disturb. The force layout is
   * multi-stable: re-annealing from scratch with a changed
   * constraint can settle a DIFFERENT basin, visibly re-arranging
   * free peers even when the pin sits exactly where the era already
   * had the peer (measured at hundreds of world units on the
   * bundled fixtures). But a pin within epsilon of the era's
   * current position changes nothing the simulation balances — the
   * existing layout is still an equilibrium of the pinned system —
   * so that era keeps its layout verbatim (with the pinned entry
   * snapped to the exact pin). An era the edit genuinely disturbs
   * recomputes cold, the canonical derivation: the peer moves and
   * its neighbors re-balance, which is the response a drag wants.
   * This rule is only sound for a pin being ADDED or MOVED — it
   * compares current pins against the current arrangement. A pin
   * REMOVAL must recompute cold (`recompute()`): the old layout was
   * an equilibrium of the pinned system, not necessarily of the
   * free one, and cold is still exactly right for the pin-here /
   * unpin round trip because the deterministic derivation
   * reproduces the pre-pin layout bit for bit when the pin never
   * moved.
   */
  recomputeForPlacement(): void {
    // Keyed by `t` because a keyframe list holds one layout per moment; two
    // at the same `t` would drop one silently here.
    const prevByT = new Map(this.#keyframes.map((kf) => [kf.t, kf.layout]));
    this.#claims = claimedPeerByEnd(this.#doc);
    this.#inputSignature = layoutInputSignature(this.#doc, this.#claims);
    // Equilibrium is checked inside `computeEras` *before* `runForce`, so an
    // undisturbed era never pays the anneal. The post-hoc throwaway path that
    // used to live here cold-solved every era first.
    this.#keyframes = sealEras(
      computeEras(
        this.#doc,
        this.config,
        this.#claims,
        this.#keyframes,
        prevByT,
      ),
      this.config,
    );
    this.#layoutGen += 1;
  }

  /**
   * Drop the settled early-out. Required after the world is rebuilt
   * (`#resetWorld` / seek) or gains nodes (materialize topology change):
   * the skip assumes entity positions already match the targets, and a
   * fresh world does not.
   */
  invalidateSettled(): void {
    this.#settledKeyframe = null;
  }

  update(world: GameWorld, t: number): void {
    const active = findActiveKeyframe(this.#keyframes, t);
    if (!active) return;
    const window = this.config.transitionWindow;
    const since = t - active.keyframe.t;
    const raw = window <= 0 ? 1 : Math.min(1, since / window);
    const progress = this.config.easing(raw);
    // Once the era has finished easing, positions already equal the
    // targets. Skip the per-node write until the active keyframe or the
    // layout generation changes (seek into the window, recompute, pin),
    // or until `invalidateSettled` runs after the world is rebuilt.
    if (progress >= 1) {
      if (
        this.#settledKeyframe === active.keyframe &&
        this.#settledGen === this.#layoutGen
      ) {
        return;
      }
      this.#settledKeyframe = active.keyframe;
      this.#settledGen = this.#layoutGen;
    } else {
      this.#settledKeyframe = null;
    }
    // The arrangement this era eases FROM is the one the picture actually holds
    // when the era begins, worked out for every era at construction. Reading it
    // rather than reconstructing it keeps this at one lerp per node however
    // densely a document's eras sit.
    const from = active.keyframe.start;
    const target = active.keyframe.layout;

    // Every node the layout produced a position for, not only the peers.
    // Peers alone is not enough: a loose end holds a place too, whether the
    // solver gave it one or `placeClaims` did, and an end that never gets
    // written sits at the origin with its edge drawn there.
    const place = (id: string, position: { x: number; y: number }): void => {
      const to = target.get(id);
      if (to === undefined) return;
      // A node this era's start had no place for appears at its own target
      // rather than easing in from wherever something else left off.
      const at = from.get(id) ?? to;
      // Mutate in place rather than allocating a new {x, y} per node per
      // frame. The position component is owned by the entity; readers
      // (renderers, hit tests) sample it synchronously in the same frame,
      // so in-place mutation is safe and saves one object allocation per
      // node per tick.
      position.x = at.x + (to.x - at.x) * progress;
      position.y = at.y + (to.y - at.y) * progress;
    };

    for (const e of world.with("peer", "position")) {
      place(e.peer.id, e.position);
    }
    for (const e of world.with("endpoint", "position")) {
      place(e.endpoint.id, e.position);
    }
  }
}

/**
 * Everything `computeKeyframes` reads, as one comparable value.
 *
 * Built from the same functions the computation itself uses, so it cannot fall
 * out of step with them: an input added there and not here would have to be
 * added to a call that is already on this line.
 *
 * It exists because a recompute is expensive and the force solver is
 * multi-stable, so re-annealing on a document change that touches none of these
 * both costs a solve and can settle a different basin — free peers visibly
 * jumping while a reader watches and does nothing. A live feed makes that
 * constant: every message that arrives is a document change, and none of them
 * is a layout change.
 *
 * The effective ranges are in it because an era's membership is asked of them
 * (`nodesStandingAt`, `linksStandingAt`), and they do not follow from the
 * moments. An Inspector edit that ends a peer at t=1000 rewrites its stored
 * timing and moves no observation, so every other part of this key is unchanged
 * while the peer has stopped standing anywhere past that moment. Without the
 * ranges the recompute declined, and the peer stayed a body in every later era's
 * solve — pushing the arrangement around from a place the stage draws nothing.
 *
 * Messages are the obvious absence and the reason this is here. Session state
 * and payloads are absent for the same reason: the solver never reads them.
 */
function layoutInputSignature(
  doc: TimelineDocument,
  claimed: ReadonlyMap<string, string>,
): string {
  const parts: string[] = [];
  for (const change of topologyChanges(doc)) {
    parts.push(
      change.kind === "session-in"
        ? `${change.t}|${change.kind}|${change.sessionId}|${change.a}|${change.b}`
        : change.kind === "session-out"
        ? `${change.t}|${change.kind}|${change.sessionId}`
        : `${change.t}|${change.kind}|${change.peerId}`,
    );
  }
  parts.push("#footprints");
  for (const [node, box] of [...nodeFootprints(doc)].sort()) {
    parts.push(`${node}|${box.halfWidth}|${box.above}|${box.below}`);
  }
  parts.push("#pins");
  for (const [node, at] of [...authoredPins(doc)].sort()) {
    parts.push(`${node}|${at.x}|${at.y}`);
  }
  parts.push("#claims");
  for (const [end, peer] of [...claimed].sort()) parts.push(`${end}|${peer}`);
  // The two questions an era's membership is asked of, in the same order every
  // run so one document keys one way.
  parts.push("#ranges");
  for (const peerId of Object.keys(doc.entities?.peers ?? {}).sort()) {
    const r = peerEffective(doc, peerId);
    parts.push(`${peerId}|${r.start}|${r.end}`);
  }
  for (const sessionId of Object.keys(doc.entities?.sessions ?? {}).sort()) {
    const r = sessionEffective(doc, sessionId);
    parts.push(`${sessionId}|${r.start}|${r.end}`);
  }
  return parts.join("\n");
}

/**
 * Give every era the arrangement the picture holds when it begins, which is the
 * one thing an era cannot know about itself.
 *
 * The only producer of a `Keyframe`. Anything that changes which layout an era
 * carries — a fresh derivation, or a placement edit swapping a reused
 * arrangement back in — passes back through here, because moving a layout moves
 * what the era AFTER it eases from as well.
 *
 * A node absent from the running arrangement but present in an era appears at
 * that era's own place for it, rather than easing in from wherever the previous
 * era happened to leave a different node.
 */
function sealEras(eras: readonly Era[], config: LayoutConfig): Keyframe[] {
  const window = config.transitionWindow;
  const sealed: Keyframe[] = [];
  for (let k = 0; k < eras.length; k++) {
    const era = eras[k]!;
    if (k === 0) {
      // Nothing preceded the first era, so the picture opens on it.
      sealed.push({ ...era, start: era.layout });
      continue;
    }
    // The sealed previous era, because its own start is half of this answer.
    const before = sealed[k - 1]!;
    const ranFor = era.t - before.t;
    const p = config.easing(window <= 0 ? 1 : Math.min(1, ranFor / window));
    const start: Layout = new Map();
    for (const [id, target] of before.layout) {
      const from = before.start.get(id);
      start.set(
        id,
        from === undefined ? target : {
          x: from.x + (target.x - from.x) * p,
          y: from.y + (target.y - from.y) * p,
        },
      );
    }
    sealed.push({ ...era, start });
  }
  return sealed;
}

function computeKeyframes(
  doc: TimelineDocument,
  config: LayoutConfig,
  claimed: ReadonlyMap<string, string>,
  /** Passed through to the per-topology arm for arrangement reuse. */
  previous?: readonly Keyframe[],
): Keyframe[] {
  return sealEras(computeEras(doc, config, claimed, previous), config);
}

function computeEras(
  doc: TimelineDocument,
  config: LayoutConfig,
  claimed: ReadonlyMap<string, string>,
  previous?: readonly Era[],
  /**
   * Placement-only: prior layouts keyed by `t`, tried as equilibria before
   * `runForce`. Must not be passed for pin removal (`recompute()`): an
   * unpinned body can still look like an equilibrium of the remaining pins.
   */
  placementPrevByT?: ReadonlyMap<number, Layout>,
): Era[] {
  switch (config.mode) {
    case "authored":
      return computeAuthoredEra(doc, claimed);
    case "static-union":
      return computeStaticUnionEra(doc, config, claimed);
    case "per-topology":
      return computePerTopologyEras(
        doc,
        config,
        claimed,
        previous,
        placementPrevByT,
      );
  }
}

/**
 * The box every node the document mentions covers, keyed by node id.
 *
 * Derived once per recompute and shared by every era, because a node's
 * footprint is a fact about the document rather than about one moment. A peer
 * measured by the WIDEST name the document ever gives it, rather than by the
 * name it wears at this keyframe's `t`, so that renaming a peer mid-timeline
 * moves nothing: a footprint that grew and shrank with the playhead would
 * shuffle the graph at a moment when no topology changed.
 *
 * A node the document says nothing about — one the solver reaches through a
 * link alone — takes the bare body, which is the smallest honest guess.
 *
 * Every caption is measured as the renderer will DRAW it, through the same
 * `peerLabelText` / `endpointLabelText` the renderer sets its text from. A
 * box reserved for the whole string while a shortened one is drawn is
 * daylight nobody can see, and the widest-name search has to run on the drawn
 * forms too: two names that both elide come out the same width, so the longer
 * raw string is not the wider label.
 */
function nodeFootprints(doc: TimelineDocument): Map<string, NodeFootprint> {
  const boxes = new Map<string, NodeFootprint>();
  for (const [peerId, def] of Object.entries(doc.entities?.peers ?? {})) {
    let widest = peerLabelText(def.label ?? peerId);
    for (const kf of def.keyframes?.label ?? []) {
      const drawn = peerLabelText(kf.value);
      if (drawn.length > widest.length) widest = drawn;
    }
    boxes.set(peerId, nodeFootprint(widest, false));
  }
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind !== "peer-joined") continue;
    if (boxes.has(ev.peerId)) continue; // entities entry won
    boxes.set(
      ev.peerId,
      nodeFootprint(peerLabelText(ev.label ?? ev.peerId), false),
    );
  }
  // An end that nothing has attributed wears its claim, or the plain word the
  // renderer shows for having no claim at all. Both ends of every session are
  // listed; the attributed ones never hold a stage id, so their entries are
  // never looked up.
  const claims = endpointClaims(doc);
  for (const sessionId of Object.keys(doc.entities?.sessions ?? {})) {
    for (const side of SESSION_SIDES) {
      const stageId = endpointStageId(sessionId, side);
      boxes.set(
        stageId,
        nodeFootprint(endpointLabelText(claims.get(stageId)), true),
      );
    }
  }
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind !== "session-opened") continue;
    for (const side of SESSION_SIDES) {
      const stageId = endpointStageId(ev.sessionId, side);
      if (boxes.has(stageId)) continue;
      boxes.set(
        stageId,
        nodeFootprint(endpointLabelText(claims.get(stageId)), true),
      );
    }
  }
  return boxes;
}

/** The segment one claim sits on: the node its session runs from, and the
 *  peer the claim names, which is where that session is solved to end. */
type ClaimSegment = { from: string; toward: string };

/**
 * Which of an era's claims ride an edge, and which edge each one rides. Every
 * layout mode asks here, so a claim is placed the same way whether its era was
 * solved or authored. The answer is a segment rather than a point because the
 * solve happens in between: this runs before the forces, `placeClaims` reads
 * the solved endpoints after.
 *
 * A claim earns a segment when two things hold, and is left to the ordinary
 * standalone placement when either fails:
 *
 *   - this era draws the claim and the peer it names, which is what
 *     `onStage` has already settled — an era that does not draw the peer has
 *     nothing to aim at;
 *   - the far end of its session has a place in this era to lean FROM,
 *     because a segment needs two ends.
 *
 * Whether the claim names anybody at all is not asked here. `engine/claims.ts`
 * settles that once for the whole document, including the two ends that
 * resolve to nobody — an ambiguous name, and a name its own session already
 * reaches — so the renderer draws exactly the ends this places.
 *
 * An authored pin is deliberately not one of them. Where the author put the
 * dot and what the session is solved against are separate questions, and
 * answering the second with the first would mean a nudge of a claim moved the
 * peers: the session's link would come off the peer and back onto the claim,
 * and everything that link was holding would drift. A pinned claim is planned
 * like any other, and `placeClaims` hands it the pin instead of the lean.
 */
function planClaimPlacements(
  nodes: ReadonlySet<string>,
  sessions: Iterable<{ a: string; b: string }>,
  onStage: ReadonlyMap<string, string>,
): Map<string, ClaimSegment> {
  const placements = new Map<string, ClaimSegment>();
  if (onStage.size === 0) return placements;

  // A stage id belongs to exactly one session, so one entry per end is
  // enough to find a claim's other end. Peers overwrite each other here and
  // that is fine: nothing ever looks a peer up.
  const otherEnd = new Map<string, string>();
  for (const s of sessions) {
    if (s.a === s.b) continue;
    otherEnd.set(s.a, s.b);
    otherEnd.set(s.b, s.a);
  }
  for (const [stageId, peerId] of onStage) {
    const other = otherEnd.get(stageId);
    if (other === undefined) continue;
    // A claim at the far end contributes the peer IT names, never its own
    // unsolved position, so the lookup is one step deep and never chases a
    // chain.
    const from = onStage.get(other) ?? other;
    if (from === peerId || !nodes.has(from)) continue;
    placements.set(stageId, { from, toward: peerId });
  }
  return placements;
}

/**
 * Give every planned claim its position: the author's, if the author placed
 * it, and otherwise the point `CLAIM_LEAN` of the way along its session's edge
 * from the far end toward the peer it names.
 *
 * After the solver rather than as a force, because the claim is not a body the
 * solve balances — a pull strong enough to look like this one is a pull strong
 * enough to distort what it is attached to.
 */
function placeClaims(
  layout: Layout,
  placements: ReadonlyMap<string, ClaimSegment>,
  pins: Layout,
  bundles: ReadonlyMap<string, SessionBundleEntry>,
): void {
  for (const [stageId, segment] of placements) {
    const pin = pins.get(stageId);
    if (pin) {
      layout.set(stageId, { x: pin.x, y: pin.y });
      continue;
    }
    const from = layout.get(segment.from);
    const toward = layout.get(segment.toward);
    // No edge to sit on, because this era placed neither end of the segment.
    // Only authored mode gets here: a solved era holds a position for every
    // node it did not lean. The claim keeps what it has, which in authored
    // mode is the same nothing any node the author skipped gets.
    if (!from || !toward) continue;
    // The claim's stage id names its own session, which is how its lane in
    // the fan is found; an era that somehow lost the row falls back to the
    // lone straight lane, which is what a singleton bundle already is.
    const at = parseEndpointStageId(stageId);
    const bundle = (at && bundles.get(at.sessionId)) ?? { index: 0, size: 1 };
    layout.set(
      stageId,
      claimLeanTo(segment.from, from, segment.toward, toward, bundle),
    );
  }
}

/** Placement-edit tolerance: covers float residue (the settled
 * lerp's `a + (b - a) * 1` is within ulps of `b`), far below any
 * deliberate coordinate edit. */
const PIN_EQUILIBRIUM_EPSILON = 1e-6;

/** If every pinned peer sits within epsilon of where `prev` already
 * has it, `prev` is still an equilibrium of the pinned system:
 * return it with pinned entries snapped to their exact pins.
 * Otherwise null — the edit genuinely disturbs this era.
 *
 * The caller has already proved the era's bodies are in `prev`, so the
 * reuse carries no stale members for those. Claims are refreshed by
 * `placeClaims` after a successful reuse. */
function reuseIfEquilibrium(
  prev: Layout,
  pins: Layout,
): Layout | null {
  for (const [id, pin] of pins) {
    const at = prev.get(id);
    if (!at) continue;
    if (
      Math.abs(at.x - pin.x) > PIN_EQUILIBRIUM_EPSILON ||
      Math.abs(at.y - pin.y) > PIN_EQUILIBRIUM_EPSILON
    ) {
      return null;
    }
  }
  const reused = new Map(prev);
  for (const [id, pin] of pins) {
    if (reused.has(id)) reused.set(id, { x: pin.x, y: pin.y });
  }
  return reused;
}

/**
 * A single era at t=0 reading each peer's authored `position`
 * field from its `peer-joined` event. No d3-force runs. A peer
 * without an authored position lands at the origin — the caller
 * (typically the builder) is expected to provide one whenever it
 * emits a `peer-joined` under `layoutMode: "authored"`.
 */
function computeAuthoredEra(
  doc: TimelineDocument,
  claimed: ReadonlyMap<string, string>,
): Era[] {
  const pins = authoredPins(doc);
  const layout: Layout = new Map(pins);
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    if (ev.kind !== "peer-joined") continue;
    if (layout.has(ev.peerId)) continue;
    layout.set(ev.peerId, { x: 0, y: 0 });
  }
  // A claim rides its session's edge here too, on the same segment rule the
  // solved modes use. An end the author has placed holds a pin and keeps it:
  // the author put it there, which is the whole contract of this mode. A
  // loose end that is not a claim has no authored position and no solver to
  // give it one, so it stays wherever the world minted it — authored mode
  // asks the author for every node's place, and that includes those.
  const nodes = new Set(layout.keys());
  for (const stageId of claimed.keys()) nodes.add(stageId);
  const onStage = claimsOnStage(claimed, nodes);
  placeClaims(
    layout,
    planClaimPlacements(nodes, sessionEnds(doc).values(), onStage),
    pins,
    bundleIndices(
      [...sessionEnds(doc)].map(([id, ends]) => ({
        id,
        a: onStage.get(ends.a) ?? ends.a,
        b: onStage.get(ends.b) ?? ends.b,
      })),
    ),
  );
  if (layout.size === 0) return [];
  return [{ t: 0, problem: SINGLE_KEYFRAME, layout }];
}

/** One thing arriving on stage or leaving it, at the moment it happens. */
type TopologyChange =
  | { t: number; kind: "peer-in"; peerId: string }
  | { t: number; kind: "peer-out"; peerId: string }
  | { t: number; kind: "session-in"; sessionId: string; a: string; b: string }
  | { t: number; kind: "session-out"; sessionId: string };

/**
 * Every moment the walk stops at, in time order.
 *
 * An entity arrives and departs once, and what states those two moments
 * depends on which kind of entity it is. An entity an observation ANNOUNCES is
 * stated by its observations: a join and the peer-left or peer-unobserved that
 * ends its row, an open and the close or session-unobserved that ends its own.
 * An entity only the DOCUMENT declares — one authored in Build, which simply
 * is — has no observations at all, so its declared timing states both. Without
 * that second half a Build-authored entity reached no era, so its position
 * fell back to the origin and every unattributed end piled on the same spot;
 * with it, an entity timed to a window arrives when the window opens and
 * leaves when it closes, exactly as an observed one does.
 *
 * One stream, so one moment cannot be reached twice. When the seed of the
 * declared entities was a keyframe of its own, a document that declared
 * anything and also observed something at t=0 got two keyframes at t=0, and
 * the stage then animated between them at a moment nothing had changed.
 */
function topologyChanges(doc: TimelineDocument): TopologyChange[] {
  const changes: TopologyChange[] = [];
  const announcedPeers = new Set<string>();
  const announcedSessions = new Set<string>();
  for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
    switch (ev.kind) {
      case "peer-joined":
        announcedPeers.add(ev.peerId);
        changes.push({ t: ev.t, kind: "peer-in", peerId: ev.peerId });
        break;
      case "peer-left":
      case "peer-unobserved":
        changes.push({ t: ev.t, kind: "peer-out", peerId: ev.peerId });
        break;
      case "session-opened":
        announcedSessions.add(ev.sessionId);
        changes.push({
          t: ev.t,
          kind: "session-in",
          sessionId: ev.sessionId,
          a: endpointNodeId(ev.sessionId, "a", ev.a),
          b: endpointNodeId(ev.sessionId, "b", ev.b),
        });
        break;
      case "session-closed":
      case "session-unobserved":
        changes.push({ t: ev.t, kind: "session-out", sessionId: ev.sessionId });
        break;
    }
  }
  for (const peerId of Object.keys(doc.entities?.peers ?? {})) {
    if (announcedPeers.has(peerId)) continue;
    const range = peerEffective(doc, peerId);
    changes.push({ t: range.start, kind: "peer-in", peerId });
    if (Number.isFinite(range.end)) {
      changes.push({ t: range.end, kind: "peer-out", peerId });
    }
  }
  for (const [sessionId, ends] of sessionEnds(doc)) {
    if (announcedSessions.has(sessionId)) continue;
    const range = sessionEffective(doc, sessionId);
    changes.push({
      t: range.start,
      kind: "session-in",
      sessionId,
      a: ends.a,
      b: ends.b,
    });
    if (Number.isFinite(range.end)) {
      changes.push({ t: range.end, kind: "session-out", sessionId });
    }
  }
  // By time, stably: the observations are already in order and the declared
  // entities are read in key order, so a document sorts one way every run.
  changes.sort((x, y) => x.t - y.t);
  return changes;
}

/**
 * Which of the sessions the walk has reached are on stage at `t`.
 *
 * Asked of the document's effective ranges, which is the same question
 * `materializeWorldAt` asks of every session before drawing it. It has to be
 * the same question: a session is one lane of its pair's bundle, so a session
 * the world draws and the layout does not means the two count that bundle
 * differently — and a claim placed on a lane of a two-lane bundle sits off the
 * arc drawn along a one-lane one. The observations say when the topology
 * changed; the ranges say what is standing there, and only one of them can be
 * the authority on the second question.
 */
function sessionsOnStageAt(
  doc: TimelineDocument,
  sessions: ReadonlyMap<string, { a: string; b: string }>,
  t: number,
): Array<{ id: string; a: string; b: string }> {
  const out: Array<{ id: string; a: string; b: string }> = [];
  for (const [id, ends] of sessions) {
    if (!containsTime(sessionEffective(doc, id), t)) continue;
    out.push({ id, a: ends.a, b: ends.b });
  }
  // In id order, for the same reason the node ids are sorted before they are
  // seeded: d3 accumulates link forces in array order, so a list in the order
  // the sessions happened to be stated would settle one document into two
  // pictures depending on which author added which session first.
  out.sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  return out;
}

/** One era per distinct topology along the timeline, in the order the
 *  moments happen. Authored positions pin their peers across every keyframe. */
function computePerTopologyEras(
  doc: TimelineDocument,
  config: LayoutConfig,
  claimed: ReadonlyMap<string, string>,
  /** The eras being replaced, whose arrangements can be reused for every
   *  moment whose problem is unchanged. Omitted for a first computation. */
  previous?: readonly Era[],
  /** Placement-only prior layouts; see `computeEras`. */
  placementPrevByT?: ReadonlyMap<number, Layout>,
): Era[] {
  const pins = authoredPins(doc);
  const boxes = nodeFootprints(doc);
  const allSessions = sessionEnds(doc);
  const changes = topologyChanges(doc);
  const eras: Era[] = [];
  const held = new Map<string, Layout>();
  for (const era of previous ?? []) {
    held.set(`${era.t}\u0003${era.problem}`, era.layout);
  }

  let lastProblem: string | null = null;
  let i = 0;
  while (i < changes.length) {
    const t = changes[i]!.t;
    // Everything that happens at one moment lands before the solve, so a
    // moment is one era at most.
    while (i < changes.length && changes[i]!.t === t) i++;

    const links = linksStandingAt(doc, changes, allSessions, t);
    const nodes = nodesStandingAt(doc, changes, links, t);
    const problem = solverProblemKey(nodes, links, pins, claimed, boxes);
    // Two moments presenting the solver the same problem are one era. `runForce`
    // is deterministic over what this key holds, so a second keyframe would be a
    // copy of the first with a transition between them, and the stage would ease
    // every node from a position to that same position.
    if (problem === lastProblem) continue;
    lastProblem = problem;
    const reused = held.get(`${t}\u0003${problem}`);
    if (reused) {
      eras.push({ t, problem, layout: reused });
      continue;
    }
    // A moved pin changes this era's problem key, so the held map misses even
    // when the prior arrangement is still an equilibrium (pin within epsilon
    // of where the era already had it, or the pin names a node this era does
    // not hold). Check that before annealing — the old placement path annealed
    // first and threw the result away.
    if (placementPrevByT) {
      const prev = placementPrevByT.get(t);
      if (prev) {
        const present = new Set(nodes);
        const onStage = claimsOnStage(claimed, present);
        const placements = planClaimPlacements(present, links, onStage);
        const bodies = nodes.filter((id) => !placements.has(id));
        if (bodies.every((id) => prev.has(id))) {
          const equilibrium = reuseIfEquilibrium(prev, pins);
          if (equilibrium) {
            placeClaims(
              equilibrium,
              placements,
              pins,
              bundleIndices(links.map((s) => ({
                id: s.id,
                a: onStage.get(s.a) ?? s.a,
                b: onStage.get(s.b) ?? s.b,
              }))),
            );
            eras.push({ t, problem, layout: equilibrium });
            continue;
          }
        }
      }
    }
    const layout = runForce(nodes, links, config, pins, claimed, boxes);
    // What this era eases from is `sealEras`'s business, once the list is known.
    eras.push({ t, problem, layout });
  }
  return eras;
}

/**
 * The session links standing at `t`.
 *
 * Two conditions, and both were in the old fold: the walk has to have reached
 * the session, and the session's own range has to hold `t`. Reached is what the
 * accumulating map used to carry, and it is not the same question as the range,
 * because a document whose observations have not been projected resolves a
 * session's start to an implicit zero — so a session opened at t=100 would
 * otherwise stand at t=0 as well, and the era before it would already show its
 * link.
 *
 * Derived from the moments rather than folded, so it stays a statement about
 * `t`: a session is reached once its own arrival moment is at or before `t`.
 */
function linksStandingAt(
  doc: TimelineDocument,
  changes: readonly TopologyChange[],
  allSessions: ReadonlyMap<string, { a: string; b: string }>,
  t: number,
): Array<{ id: string; a: string; b: string }> {
  const reached = new Map<string, { a: string; b: string }>();
  for (const change of changes) {
    if (change.t > t) break;
    if (change.kind !== "session-in") continue;
    const ends = allSessions.get(change.sessionId);
    if (ends !== undefined) reached.set(change.sessionId, ends);
  }
  return sessionsOnStageAt(doc, reached, t);
}

/**
 * The nodes standing at `t`, in the sorted order `runForce` wants.
 *
 * Asked of the document's effective ranges, for the same reason
 * `sessionsOnStageAt` asks them of the links: an era has to describe the moment
 * it is stamped at rather than everything that had happened by then.
 *
 * Not quite the same question, though, and the difference is a trade rather than
 * an oversight. This asks reached AND standing; the world asks only standing
 * (`world-materializer.ts`). So a peer whose authored timing starts before the
 * observation that announces it is on stage, with no entry in the era covering
 * that gap, and `update` leaves it wherever it was. Reached is what makes an
 * unprojected document behave, and the fold this replaced carried the same gap.
 *
 * It used to be a set folded forward across the walk, and a session's departure
 * did not remove the ends it had added — `peer-out` only reaches an id a
 * `peer-joined` or a declared peer named, and a loose end's stage id is neither.
 * So a session that opened and closed left its end in the node set of every
 * later era, as a free body with charge and a footprint, seeded at the origin
 * with nothing standing there. A live room that opens a session every few
 * seconds accumulated one such body per session for as long as anyone watched,
 * piling them at the center of the picture and pushing every real peer outward
 * a little further each time. Deriving the set from the moment is what makes an
 * era a statement about that moment, and it is also what lets two eras be
 * compared at all: while the set grew forever, no two of them were ever equal.
 */
function nodesStandingAt(
  doc: TimelineDocument,
  changes: readonly TopologyChange[],
  links: ReadonlyArray<{ id: string; a: string; b: string }>,
  t: number,
): string[] {
  const nodes = new Set<string>();
  for (const change of changes) {
    // Reached, then standing: the same two conditions the links answer to, and
    // for the same reason.
    if (change.t > t) break;
    if (change.kind !== "peer-in") continue;
    if (containsTime(peerEffective(doc, change.peerId), t)) {
      nodes.add(change.peerId);
    }
  }
  // An end of a session standing here stands here too, whether it names a peer
  // (in which case this is that peer, already counted) or nothing at all.
  for (const link of links) {
    nodes.add(link.a);
    nodes.add(link.b);
  }
  return [...nodes].sort();
}

/**
 * What the solver is being asked, as one comparable value.
 *
 * Everything `runForce` reads for this era: the nodes, the pairs they are linked
 * in, and per node the pin holding it, the peer it claims, and the box it
 * occupies. All of it, because the key is compared across computations as well
 * as within one — an era whose arrangement is reused has to be answering the
 * same question in every respect, and a pin cleared or a claim landing changes
 * the answer without changing the node set. Leaving those out reused a layout
 * that still held a peer at a pin nobody had asked for any more.
 *
 * The session ids are in it, and a first version left them out on the reasoning
 * that the solver reads one only through `bundleIndices`, to count how many
 * lanes a pair carries. That is half of what `bundleIndices` does: it sorts the
 * ids sharing a pair and indexes by position (`session-geometry.ts:119-125`), so
 * WHICH lane a claim rides depends on the ids of every session on that pair. Two
 * eras carrying the same pairs under different ids are therefore different
 * problems, and treating them as one left a claim leaning on the lane it had
 * while its arc was drawn along another.
 *
 * The pairs are listed rather than deduplicated for the same reason: a second
 * session between the same two nodes is a second lane.
 */
function solverProblemKey(
  nodes: readonly string[],
  links: ReadonlyArray<{ id: string; a: string; b: string }>,
  pins: Layout,
  claimed: ReadonlyMap<string, string>,
  boxes: ReadonlyMap<string, NodeFootprint>,
): string {
  const parts: string[] = [];
  for (const node of nodes) {
    const pin = pins.get(node);
    const box = boxes.get(node);
    parts.push(
      [
        node,
        pin === undefined ? "" : `${pin.x},${pin.y}`,
        claimed.get(node) ?? "",
        box === undefined ? "" : `${box.halfWidth},${box.above},${box.below}`,
      ].join("\u0000"),
    );
  }
  const wires = links
    .map((l) => `${l.a}\u0000${l.b}\u0000${l.id}`)
    .sort();
  return parts.join("\u0001") + "\u0002" + wires.join("\u0001");
}

/**
 * A single era at t=0 over the union of every peer and session
 * that ever exists in the document. Subsequent topology changes
 * (peer-left, session-closed) don't drop nodes from the layout —
 * the position stays reserved so the rest of the graph doesn't
 * shuffle when a peer leaves.
 */
function computeStaticUnionEra(
  doc: TimelineDocument,
  config: LayoutConfig,
  claimed: ReadonlyMap<string, string>,
): Era[] {
  const peers = new Set<string>();
  const sessions = new Map<string, { a: string; b: string }>();
  // Every arrival the timeline holds and no departure: the union is the point
  // of this mode. The same moments the per-topology walk steps through, read
  // for what they add rather than for when they add it — so an entity only
  // the document declares joins the union exactly as an observed one does.
  //
  // An unattributed end holds a place like a peer: it has a position, and it
  // is dragged and selected the way a peer is. Whether the solve pulls on the
  // end itself or on the peer its claim names is `runForce`'s question, asked
  // once there for every mode.
  for (const change of topologyChanges(doc)) {
    if (change.kind === "peer-in") peers.add(change.peerId);
    else if (change.kind === "session-in") {
      peers.add(change.a);
      peers.add(change.b);
      sessions.set(change.sessionId, { a: change.a, b: change.b });
    }
  }
  if (peers.size === 0) return [];
  const layout = runForce(
    [...peers].sort(),
    // Sorted for the reason `sessionsOnStageAt` sorts: link order is force
    // order, and the union should not depend on who was stated first.
    [...sessions.entries()]
      .map(([id, e]) => ({ id, a: e.a, b: e.b }))
      .sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0)),
    config,
    authoredPins(doc),
    claimed,
    nodeFootprints(doc),
  );
  return [{ t: 0, problem: SINGLE_KEYFRAME, layout }];
}

/**
 * One d3-force convergence for a topology snapshot. Determinism
 * comes from seeding positions on a unit ring in alphabetical id
 * order and running a fixed iteration count with no randomness.
 *
 * A peer in `pins` is a fixed node: `fx`/`fy` hold it at its
 * authored position through every tick (d3 resets a fixed node's
 * `x`/`y` to `fx`/`fy` after each integration step), while its
 * links and charge still push the free nodes into place around it.
 *
 * A claim is not one of the bodies solved here: its session's link is solved
 * as if the end were already at the peer it names, and `placeClaims` sits it
 * on the resulting edge afterwards (see `CLAIM_LEAN`). A loose end that is NOT
 * a claim — nothing named, or a name nobody on stage answers to — is an
 * ordinary body, solved with link, charge and collision like any peer.
 */
function runForce(
  peerIds: string[],
  sessionLinks: Array<{ id: string; a: string; b: string }>,
  config: LayoutConfig,
  pins: Layout,
  claimed: ReadonlyMap<string, string>,
  boxes: ReadonlyMap<string, NodeFootprint>,
): Layout {
  const layout: Layout = new Map();
  if (peerIds.length === 0) return layout;

  const present = new Set(peerIds);
  // Which of the document's claims this era can act on. The renderer asks the
  // same of the world at the playhead (`claimTargets`), so an end this era
  // leaned is an end the frame draws as a claim, and the lanes agree.
  const onStage = claimsOnStage(claimed, present);
  const placements = planClaimPlacements(present, sessionLinks, onStage);
  /** The node a claim's session is solved to, which is the peer it names.
   *  Every other id solves as itself. */
  const solvedNode = (id: string): string => placements.get(id)?.toward ?? id;

  // Bodies the force would solve (claims lean afterwards via placeClaims).
  const bodyIds = peerIds.filter((id) => !placements.has(id));

  // Every body is a pin: the arrangement is the pins, and `placeClaims` still
  // leans claims onto edges. Running the simulation would spend
  // `config.iterations` ticks moving nothing — the cost that made multi-select
  // drags on an all-pinned Build document (kids masterpiece and kin) stall.
  if (bodyIds.every((id) => pins.has(id))) {
    for (const id of bodyIds) {
      const pin = pins.get(id)!;
      layout.set(id, { x: pin.x, y: pin.y });
    }
    placeClaims(
      layout,
      placements,
      pins,
      bundleIndices(sessionLinks.map((s) => ({
        id: s.id,
        a: onStage.get(s.a) ?? s.a,
        b: onStage.get(s.b) ?? s.b,
      }))),
    );
    return layout;
  }

  const regionCounts = new Map<string, number>();
  // Track per-region seed index so multiple peers in the same
  // region don't start coincident on the centroid.
  const nodes: SimNode[] = bodyIds.map((id) => {
    const pin = pins.get(id);
    if (pin) {
      return { id, x: pin.x, y: pin.y, fx: pin.x, fy: pin.y, vx: 0, vy: 0 };
    }
    const region = parseRegion(id);
    const indexInRegion = regionCounts.get(region) ?? 0;
    regionCounts.set(region, indexInRegion + 1);
    // One step of the spiral is one node's own half-width plus the space
    // kept around it, so a region's seeds already stand about as far apart
    // as the separation force will insist on.
    const seed = regionAwareSeed(
      id,
      indexInRegion,
      NODE_HALF_WIDTH + config.nodeSpacing,
    );
    return { id, x: seed.x, y: seed.y, vx: 0, vy: 0 };
  });
  const nodeById = new Map(nodes.map((n) => [n.id, n]));

  // A claim's link is solved against the peer it names, so the edge pulls on
  // that peer exactly as it will once the claim is attributed. A link whose
  // two ends solve to the same node — a session claiming to be the peer at
  // its own other end — is dropped, the same as any self-link.
  const links: SimLink[] = sessionLinks.flatMap((s) => {
    const a = solvedNode(s.a);
    const b = solvedNode(s.b);
    if (a === b || !nodeById.has(a) || !nodeById.has(b)) return [];
    return [{ id: s.id, source: a, target: b }];
  });

  // Region anchors pull recognized prefixes toward their centroid;
  // unprefixed peers anchor at (0, 0), which the centerStrength
  // force already does, so the region anchor is a no-op for them.
  const sim = forceSimulation(nodes)
    .force("charge", forceManyBody().strength(config.chargeStrength))
    .force(
      "link",
      forceLink<SimNode, SimLink>(links)
        .id((d) => d.id)
        .distance(config.linkDistance)
        .strength(config.linkStrength),
    )
    .force(
      "footprints",
      forceFootprints(
        boxes,
        config.nodeSpacing,
        FOOTPRINT_SEPARATION_STRENGTH,
      ),
    )
    .force("center", forceCenter(0, 0))
    .force(
      "region-x",
      forceX<SimNode>((d) => regionCentroid(d.id).x).strength(
        REGION_PULL_STRENGTH,
      ),
    )
    .force(
      "region-y",
      forceY<SimNode>((d) => regionCentroid(d.id).y).strength(
        REGION_PULL_STRENGTH,
      ),
    )
    .force("x", forceX(0).strength(config.centerStrength))
    .force("y", forceY(0).strength(config.centerStrength))
    .stop();

  for (let i = 0; i < config.iterations; i++) sim.tick();

  for (const node of nodes) {
    // Pinned nodes read back their authored position EXACTLY:
    // d3's integration step assigns `x = fx` (no arithmetic), so
    // no float drift accumulates on a fixed node.
    layout.set(node.id, { x: node.x ?? 0, y: node.y ?? 0 });
  }
  // The same lanes the renderer will draw, from the same grouping, with each
  // claim standing for the peer it names.
  placeClaims(
    layout,
    placements,
    pins,
    bundleIndices(sessionLinks.map((s) => ({
      id: s.id,
      a: onStage.get(s.a) ?? s.a,
      b: onStage.get(s.b) ?? s.b,
    }))),
  );
  return layout;
}

/**
 * The angle between consecutive points of a phyllotaxis spiral, which is the
 * one angle that never lets a later point land on an earlier point's ray.
 */
const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

/**
 * Deterministic seed for one node: the `indexInRegion`-th point of a
 * phyllotaxis spiral around its region's centroid, stepping out by `spacing`
 * so a region of N nodes starts already spread over the disc N of them will
 * end up needing. Determinism in `(peerId, indexInRegion)` is required for
 * the "scrub forward and back visits the same pixels" contract.
 *
 * A spiral rather than a ring, because a ring has to choose a radius and a
 * count in advance and a spiral does not: the eighth node in a region lands
 * as far out as eight nodes need, without the first seven having been told
 * how many would follow.
 *
 * The seed decides more than where the solver starts. Every node with no
 * region prefix used to seed on the same point, so the whole graph began as
 * one pile and the arrangement the solver found was whatever its repulsion
 * happened to break that tie into. A peer's session ends came out at radii
 * between a fifth and a whole link distance from it, gathered to one side,
 * because nothing in the starting state distinguished one end from another.
 */
function regionAwareSeed(
  peerId: string,
  indexInRegion: number,
  spacing: number,
): Vec2 {
  const centroid = regionCentroid(peerId);
  const angle = indexInRegion * GOLDEN_ANGLE;
  const r = spacing * Math.sqrt(0.5 + indexInRegion);
  return {
    x: centroid.x + Math.cos(angle) * r,
    y: centroid.y + Math.sin(angle) * r,
  };
}

/**
 * A d3 force that keeps what each node DRAWS out of what every other node
 * draws: their footprints, grown by `padding` on every side, are pushed apart
 * until no two boxes overlap.
 *
 * A box rather than `forceCollide`'s circle because a label is wide and short
 * and hangs below the body it names. A circle big enough to clear a wide label
 * sideways clears it upward too, and spends that same width on an axis that
 * never needed it. That is the dense-middle, empty-margin picture: every node
 * demanding its widest dimension in every direction.
 *
 * The push runs along the line between the two nodes, and goes exactly as far
 * as the nearer edge of the box needs. Pushing instead along whichever axis
 * overlaps least — the textbook minimum-translation answer, and the cheaper
 * motion — settles each pair with one coordinate exactly equal, so a graph
 * comes out on a grid of shared columns and rows. Along the center line the
 * same boxes clear without that.
 *
 * Deterministic: one pass over the pairs in array order, arithmetic only.
 * A pinned node (`fx`/`fy` set) does not move, so its partner takes the whole
 * correction rather than half.
 *
 * Exported so `keyframe-layout-system.test.ts` can run one pass over a pile
 * with nothing else acting. Through a whole solve the charge would separate a
 * pile too, so a pile this force left alone would still come apart on screen
 * and the defect would be invisible.
 */
export function forceFootprints(
  boxes: ReadonlyMap<string, NodeFootprint>,
  padding: number,
  strength: number,
): { (): void; initialize(nodes: SimNode[]): void } {
  let nodes: SimNode[] = [];
  let mine: NodeFootprint[] = [];
  const force = (): void => {
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i]!;
      const ba = mine[i]!;
      const aFixed = a.fx !== undefined && a.fx !== null;
      // d3 integrates position as x + vx, so separate where the nodes are
      // about to be rather than where they were — the same prediction
      // `forceCollide` makes, and what keeps the push from oscillating.
      const ax = (a.x ?? 0) + (a.vx ?? 0);
      const ay = (a.y ?? 0) + (a.vy ?? 0);
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j]!;
        const bFixed = b.fx !== undefined && b.fx !== null;
        if (aFixed && bFixed) continue;
        const bb = mine[j]!;
        const bx = (b.x ?? 0) + (b.vx ?? 0);
        const by = (b.y ?? 0) + (b.vy ?? 0);
        let dx = ax - bx;
        let dy = ay - by;
        const needX = ba.halfWidth + bb.halfWidth + padding * 2;
        // Vertical extents are asymmetric, so how much room the pair needs
        // depends on which one is above: the upper one's label reaches down
        // toward the lower one's body.
        const upper = dy <= 0 ? ba : bb;
        const lower = dy <= 0 ? bb : ba;
        const needY = upper.below + lower.above + padding * 2;
        if (Math.abs(dx) >= needX || Math.abs(dy) >= needY) continue;
        const piled = dx === 0 && dy === 0;
        if (piled) {
          // Two nodes on the same point have no line to separate along. Send
          // them apart on a golden-angle ray indexed by position in the
          // array, which is id order, so a pile fans out and does it the same
          // way every run.
          //
          // The ray is the whole correction rather than a direction to grow:
          // it is scaled here to the distance along itself at which the
          // nearer box edge clears, and `push` below applies it whole. Growing
          // a separation of nothing is what a multiplier does with a pile,
          // which is nothing — and at index zero the ray runs along x, where
          // the multiplier came out exactly one and the pair never moved.
          const angle = i * GOLDEN_ANGLE;
          const ux = Math.cos(angle);
          const uy = Math.sin(angle);
          const reach = Math.min(
            ux === 0 ? Infinity : needX / Math.abs(ux),
            uy === 0 ? Infinity : needY / Math.abs(uy),
          );
          dx = ux * reach;
          dy = uy * reach;
        }
        // How far along their own center line the pair must move for the
        // nearer box edge to clear. The smaller factor is the nearer edge.
        const grow = Math.min(
          dx === 0 ? Infinity : needX / Math.abs(dx),
          dy === 0 ? Infinity : needY / Math.abs(dy),
        );
        const share = aFixed || bFixed ? 1 : 0.5;
        // A separated pair moves by the shortfall over the gap it already
        // has; a piled pair has no gap, so it moves by the whole ray.
        const push = (piled ? 1 : grow - 1) * strength * share;
        if (!aFixed) {
          a.vx = (a.vx ?? 0) + dx * push;
          a.vy = (a.vy ?? 0) + dy * push;
        }
        if (!bFixed) {
          b.vx = (b.vx ?? 0) - dx * push;
          b.vy = (b.vy ?? 0) - dy * push;
        }
      }
    }
  };
  force.initialize = (ns: SimNode[]): void => {
    nodes = ns;
    mine = ns.map((n) => boxes.get(n.id) ?? BARE_FOOTPRINT);
  };
  return force;
}

/** How much of a measured overlap one pass removes. Below one so a node
 *  caught between two others settles between them instead of ringing back
 *  and forth; the tick count is far more than enough to converge from here. */
const FOOTPRINT_SEPARATION_STRENGTH = 0.7;

/** Latest keyframe with `t_kf ≤ t`, or undefined if none. */
function findActiveKeyframe(
  keyframes: readonly Keyframe[],
  t: number,
): { keyframe: Keyframe; index: number } | undefined {
  for (let i = keyframes.length - 1; i >= 0; i--) {
    const keyframe = keyframes[i];
    if (keyframe && keyframe.t <= t) return { keyframe, index: i };
  }
  return undefined;
}
