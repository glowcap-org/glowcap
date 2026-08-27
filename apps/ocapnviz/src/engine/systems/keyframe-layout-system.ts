import type { TimelineDocument } from "../timeline.ts";
import { claimedPeerByEnd } from "../claims.ts";
import type { GameWorld } from "../world.ts";
import {
	computeEras,
	computeKeyframes,
	DEFAULT_LAYOUT_CONFIG,
	findActiveKeyframe,
	type Keyframe,
	type LayoutConfig,
	layoutInputSignature,
	sealEras,
} from "./layout-eras.ts";

/**
 * KeyframeLayoutSystem — node positions as a pure function of `t`.
 *
 * Nodes here are peers and session ends alike. An end whose `peer` field is
 * absent is LOOSE: nothing proved who is on it, so `endpointNodeId` gives it a
 * node of its own keyed by `sessionId::side`, its stage id. A loose end that
 * `engine/claims.ts` resolves to a peer is a CLAIM about that peer, and
 * `claim-placement.ts` decides where it sits. Throughout this file "claim"
 * means that end, never the designator string it carries.
 *
 * `layout-eras.ts` owns the era list and seals each one's start arrangement.
 * `force-layout.ts` owns the anneal; `stage-topology.ts` owns who stands at a
 * moment. This class asks for the list and writes each node's position as an
 * eased lerp between the surrounding keyframes. Scrubbing forward and back
 * visits identical positions because there is no integration history.
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
 * that is derived rather than chosen (`docs/era-collapse.md`).
 */

export { DEFAULT_LAYOUT_CONFIG, type LayoutConfig, type LayoutMode } from "./layout-eras.ts";

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
		const place = (
			id: string,
			position: { x: number; y: number },
		): void => {
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
