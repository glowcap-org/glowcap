/**
 * One d3-force convergence for a topology snapshot.
 *
 * `stage-topology.ts` owns who stands at a moment; `layout-eras.ts` owns the
 * era list and when to anneal. This module owns the anneal: region seeds,
 * charge/link/center, footprint separation, and
 * leaning claims onto the resulting edges. Determinism comes from seeding
 * in id order and running a fixed iteration count with no randomness.
 */

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
import { claimsOnStage } from "../claims.ts";
import { bundleIndices } from "../session-geometry.ts";
import type { Vec2 } from "../world.ts";
import { placeClaims, planClaimPlacements } from "./claim-placement.ts";
import { BARE_FOOTPRINT, NODE_HALF_WIDTH, type NodeFootprint } from "./node-footprint.ts";

type Layout = Map<string, Vec2>;

type SimNode = SimulationNodeDatum & { id: string };
type SimLink = SimulationLinkDatum<SimNode> & { id: string };

/** The fields `runForce` reads off the layout config. */
export type ForceLayoutConfig = {
  chargeStrength: number;
  linkDistance: number;
  linkStrength: number;
  nodeSpacing: number;
  iterations: number;
  centerStrength: number;
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
export function runForce(
  peerIds: string[],
  sessionLinks: Array<{ id: string; a: string; b: string }>,
  config: ForceLayoutConfig,
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
 * Exported so `keyframe-layout-test/separation.test.ts` can run one pass over a pile
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
