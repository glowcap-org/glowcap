/**
 * Computing and sealing layout eras.
 *
 * An era is one topology along the timeline and the arrangement solved for it.
 * This module owns that list: which moments get an era, what problem each one
 * answers, when a prior arrangement can be reused, and — once the list is
 * known — where the picture actually is when each era begins (`sealEras`).
 * `KeyframeLayoutSystem` asks for the list and writes positions at `t`.
 *
 * `force-layout.ts` owns the anneal itself; `stage-topology.ts` owns who
 * stands at a moment. Cost, reuse, and why the era count stays unbounded
 * are recorded on `KeyframeLayoutSystem` and in `docs/era-collapse-plan.md`.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { claimsOnStage, sessionEnds } from "../claims.ts";
import type { Vec2 } from "../world.ts";
import { bundleIndices } from "../session-geometry.ts";
import { type EasingFn, smoothstep } from "../easing.ts";
import { authoredPins } from "../event-helpers.ts";
import { placeClaims, planClaimPlacements } from "./claim-placement.ts";
import { runForce } from "./force-layout.ts";
import { type NodeFootprint, nodeFootprints } from "./node-footprint.ts";
import { linksStandingAt, nodesStandingAt, topologyChanges } from "./stage-topology.ts";

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

export type Keyframe = Era & {
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
export function layoutInputSignature(
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
export function sealEras(eras: readonly Era[], config: LayoutConfig): Keyframe[] {
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

export function computeKeyframes(
  doc: TimelineDocument,
  config: LayoutConfig,
  claimed: ReadonlyMap<string, string>,
  /** Passed through to the per-topology arm for arrangement reuse. */
  previous?: readonly Keyframe[],
): Keyframe[] {
  return sealEras(computeEras(doc, config, claimed, previous), config);
}

export function computeEras(
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

/** Latest keyframe with `t_kf ≤ t`, or undefined if none. */
export function findActiveKeyframe(
  keyframes: readonly Keyframe[],
  t: number,
): { keyframe: Keyframe; index: number } | undefined {
  for (let i = keyframes.length - 1; i >= 0; i--) {
    const keyframe = keyframes[i];
    if (keyframe && keyframe.t <= t) return { keyframe, index: i };
  }
  return undefined;
}
