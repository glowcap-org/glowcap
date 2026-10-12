import { findNode, type GameWorld } from "./world.ts";
import { claimsOnStage } from "./claims.ts";
import type { TimelineEvent } from "./timeline.ts";

/**
 * Session-bundle geometry, when N sessions share the same peer
 * pair, they fan out as quadratic Bezier arcs around the straight
 * line so each is individually visible. Deterministic:
 * (canonical pair key, session id) seeds the offset, so the same
 * topology renders the same way every frame, across reloads, and
 * across processes.
 *
 * d3-shape has path generators (`linkHorizontal`, `arc`) but
 * outputs SVG strings. We render in PixiJS, so we keep just the
 * math. There's no edge-bundling primitive in core d3 that fits
 * the few-edges-per-pair case, research-grade algorithms (Holten,
 * force-directed bundling) are overkill here.
 *
 * One module owns: the bundle index, the Bezier curve, and the
 * per-curve evaluation/tangent helpers. Both edge rendering
 * (Stage) and message-in-flight positioning (message-flight-system)
 * read from the same source so an edge and a message on it stay
 * geometrically aligned to the pixel. That source is
 * `drawnSessionCurve` rather than `sessionCurve`: an edge whose far end is a
 * claim is the prefix of the lane to the peer it names, and a dot following
 * the other curve would fly beside its own wire.
 */

/** Bundle membership for one session: which slot of its peer-pair
 * group it occupies, out of how many. Index 0..size-1, stable. */
export type SessionBundleEntry = {
	index: number;
	size: number;
};

/**
 * One frame's claim resolution and the two bundle tables derived from it.
 *
 * Flight positioning and edge drawing must read the same maps, or a dot
 * leaves the wire it is meant to ride. The engine builds this once per
 * stage update. The Stage projects from it rather than rebuilding.
 */
export type FrameGeometry = {
	claimsToward: ReadonlyMap<string, string>;
	sessionBundles: ReadonlyMap<string, SessionBundleEntry>;
	/** Doc-stable simultaneity slots, memoized across playback and
	 *  mid-drag. Rebuilt on seek and when the document is marked dirty. */
	timeBundles: ReadonlyMap<string, SessionBundleEntry>;
	/** Per-session drawn curves for this stage pass, after layout has
	 *  placed nodes. Flight and edge drawing share one curve per session
	 *  so a dense wire is not re-derived once per in-flight message. */
	sessionCurves: ReadonlyMap<string, SessionCurve>;
};

export const EMPTY_FRAME_GEOMETRY: FrameGeometry = {
	claimsToward: new Map(),
	sessionBundles: new Map(),
	timeBundles: new Map(),
	sessionCurves: new Map(),
};

/** Perpendicular spacing between adjacent bundle slots, in world
 * units. Tuned so two sessions on the same pair clearly read as
 * separate, but a singleton session still feels like a direct line
 * to the eye. */
export const SESSION_BUNDLE_SPACING = 30;

/**
 * Each unattributed end this frame draws as a claim, and the peer it names.
 * An end nobody can resolve is absent, and stands for itself.
 *
 * Two questions, and neither is asked here. Which peer an end's claim names is
 * `engine/claims.ts`'s answer, settled once for the whole document and handed
 * in as `claimed`, so the renderer never resolves a claim the placement
 * refused. Whether both ends of that relationship are standing here is this
 * moment's own question, and it is asked of the world for the same reason the
 * layout asks it of an era's node set: an end leaning toward somebody the
 * stage is not drawing has nothing to lean at. Every peer the world holds
 * counts, hidden ones included, because the layout that placed these ends is
 * visibility-blind too, a claim on a peer the reader has hidden still reads
 * as a claim, sitting where the layout put it.
 *
 * A claim rides the same corridor as a real edge to the peer it names, the
 * layout sits it on that very line, so it collides with one and belongs in
 * the same fan. Grouping it there asserts nothing about who is on it: the
 * bundle is geometry, and the end is still drawn short of the peer, dashed,
 * and at half a peer's width. It also makes attribution continuous, because
 * the line then lengthens along the lane it already occupied rather than
 * jumping to another one.
 */
export function claimTargets(
	world: GameWorld,
	claimed: ReadonlyMap<string, string>,
): Map<string, string> {
	const present = new Set<string>();
	for (const e of world.with("peer")) present.add(e.peer.id);
	for (const e of world.with("endpoint")) present.add(e.endpoint.id);
	return claimsOnStage(claimed, present);
}

/** Compute bundle indices for every session in the world. Sessions
 * are grouped by canonical peer-pair key (sorted endpoint ids, with a claim
 * standing for the peer it names) so swapping `a` and `b` doesn't change the
 * grouping, then sorted within each group by session id for a stable index
 * assignment.
 *
 * `towards` is the frame's own `claimTargets`, passed in rather than rebuilt:
 * the caller needs the same map to draw each edge, and two maps built two ways
 * are two answers waiting to disagree. */
export function computeSessionBundles(
	world: GameWorld,
	towards: ReadonlyMap<string, string>,
): Map<string, SessionBundleEntry> {
	return bundleIndices(
		[...world.with("session", "endpoints")].map((e) => ({
			id: e.session.id,
			a: towards.get(e.endpoints.a) ?? e.endpoints.a,
			b: towards.get(e.endpoints.b) ?? e.endpoints.b,
		})),
	);
}

/**
 * Bundle slots for links already resolved to the nodes they run between,
 * a claim standing for the peer it names.
 *
 * The grouping itself, with no world to read, because the layout groups the
 * same links from the document while the renderer groups them from the world.
 * One of them deciding differently would put a claim in a lane its own arc
 * was not drawn in.
 */
export function bundleIndices(
	links: Iterable<{ id: string; a: string; b: string }>,
): Map<string, SessionBundleEntry> {
	const groups = new Map<string, string[]>();
	for (const link of links) {
		const key = pairKey(link.a, link.b);
		let list = groups.get(key);
		if (!list) {
			list = [];
			groups.set(key, list);
		}
		list.push(link.id);
	}
	const out = new Map<string, SessionBundleEntry>();
	for (const list of groups.values()) {
		list.sort();
		for (let i = 0; i < list.length; i++) {
			out.set(list[i]!, { index: i, size: list.length });
		}
	}
	return out;
}

/** Endpoints + Bezier control point for one session. `null` when
 * either peer is missing (e.g. mid-construction). */
export type SessionCurve = {
	ax: number;
	ay: number;
	bx: number;
	by: number;
	cx: number;
	cy: number;
};

/**
 * The curve a session's edge is drawn along.
 *
 * An end nothing has attributed but that names a peer the stage draws is
 * resolved to that peer, so the arc runs the lane a full session to that peer
 * would run, and is then cut at `lean`, where the claim itself was placed.
 * The cut end IS the claim's position, so the line reaches it exactly.
 *
 * Nothing draws the rest of the lane, and that is the decision rather than an
 * omission. The segment from `lean` to 1 is the distance an unbacked claim
 * cannot carry, and the picture says so by stopping short of the peer. A
 * reader takes the relationship from the direction the line points and from
 * the claim's smaller body beside it. Drawing that last segment as a fainter
 * continuation would say the same thing a second time, in a stroke that a
 * reader could mistake for a wire that exists.
 *
 * Both ends claiming is left on the straight reading between them: the two
 * claims were each placed against a different pair, so there is no one lane
 * for the pair to ride.
 */
export function drawnSessionCurve(
	world: GameWorld,
	endpointA: string,
	endpointB: string,
	bundle: SessionBundleEntry,
	towards: ReadonlyMap<string, string>,
	lean: number,
): SessionCurve | null {
	const aTo = towards.get(endpointA);
	const bTo = towards.get(endpointB);
	if ((aTo === undefined) === (bTo === undefined)) {
		return sessionCurve(world, endpointA, endpointB, bundle);
	}
	// Build from the end that is a peer, so `t` runs from it toward the claim
	// exactly as the placement's did.
	const fromId = aTo === undefined ? endpointA : endpointB;
	const towardId = (aTo ?? bTo)!;
	const from = findNode(world, fromId)?.position;
	const toward = findNode(world, towardId)?.position;
	const claimAt = findNode(world, aTo === undefined ? endpointB : endpointA)
		?.position;
	if (!from || !toward || !claimAt) return null;
	const trimmed = curvePrefix(
		curveBetween(fromId, from, towardId, toward, bundle),
		lean,
	);
	// Only while the claim is ON that lane. An author who drags one
	// pins it, and the layout hands a pinned claim its pin instead of the lean,
	// so the trimmed arc would stop short of the claim and the line would not
	// reach it. Asked of the position rather than of a mode,
	// because "is the node on this curve" is the thing that has to be true, and
	// a flag saying so is a second copy of it that can be wrong.
	const offLane = Math.hypot(trimmed.bx - claimAt.x, trimmed.by - claimAt.y);
	if (offLane > ON_LANE_EPSILON) {
		return sessionCurve(world, endpointA, endpointB, bundle);
	}
	return trimmed;
}

/** How far a claim may sit from the lane and still be drawn as riding it.
 *  Covers the float residue of evaluating the same curve twice. A drag moves
 *  it by whole pixels. */
const ON_LANE_EPSILON = 1e-6;

/** Compute the Bezier curve for one session given its bundle
 * entry. Endpoints come from live peer positions. The control
 * point is offset perpendicular to the straight `a→b` direction
 * by `2 × offset` (Bezier apex sits at half the control-point
 * distance from the chord midpoint). */
export function sessionCurve(
	world: GameWorld,
	endpointA: string,
	endpointB: string,
	bundle: SessionBundleEntry,
): SessionCurve | null {
	// `findNode`, not `findPeer`: one end may be a claim nobody attributed,
	// and a lookup that only knew peers returned nothing and dropped the whole
	// edge. The session and every message on it went undrawn.
	const a = findNode(world, endpointA)?.position;
	const b = findNode(world, endpointB)?.position;
	if (!a || !b) return null;
	return curveBetween(endpointA, a, endpointB, b, bundle);
}

/**
 * The same curve from positions the caller already holds.
 *
 * Split out because the layout needs it too: a claim sits ON the curve its
 * session would take if it reached the peer it names, and the layout is what
 * decides where it sits. Both sides must build the identical curve, so the
 * arithmetic has one home and the ids that canonicalize it are passed in
 * rather than re-derived.
 */
export function curveBetween(
	endpointA: string,
	a: { x: number; y: number },
	endpointB: string,
	b: { x: number; y: number },
	bundle: SessionBundleEntry,
): SessionCurve {
	// Canonicalize: swap into id order so the perpendicular
	// direction is independent of how the session-opened event
	// happened to list its endpoints.
	let ax = a.x, ay = a.y, bx = b.x, by = b.y;
	if (endpointB < endpointA) {
		ax = b.x;
		ay = b.y;
		bx = a.x;
		by = a.y;
	}
	const offset = bundleOffset(bundle.index, bundle.size);
	// Singleton bundles render as a straight line, control point
	// sits on the chord midpoint, the quadratic Bezier degenerates.
	if (offset === 0) {
		return {
			ax: a.x,
			ay: a.y,
			bx: b.x,
			by: b.y,
			cx: (a.x + b.x) / 2,
			cy: (a.y + b.y) / 2,
		};
	}
	const dx = bx - ax;
	const dy = by - ay;
	const len = Math.hypot(dx, dy);
	if (len === 0) {
		return {
			ax: a.x,
			ay: a.y,
			bx: b.x,
			by: b.y,
			cx: (a.x + b.x) / 2,
			cy: (a.y + b.y) / 2,
		};
	}
	const px = -dy / len;
	const py = dx / len;
	const mx = (ax + bx) / 2;
	const my = (ay + by) / 2;
	// 2 × offset because B(0.5) = 0.5 M + 0.5 C, to get an apex
	// displaced by `offset` from the midpoint, the control point
	// must be displaced by `2 × offset`.
	return {
		ax: a.x,
		ay: a.y,
		bx: b.x,
		by: b.y,
		cx: mx + px * offset * 2,
		cy: my + py * offset * 2,
	};
}

/** Signed perpendicular displacement of bundle slot `index` out of
 * `size`. Symmetric around zero: a 3-session bundle splays into
 * (-s, 0, +s). A 4-session bundle into (-1.5 s, -0.5 s, +0.5 s,
 * +1.5 s). A singleton is always 0. */
export function bundleOffset(index: number, size: number): number {
	if (size <= 1) return 0;
	return (index - (size - 1) / 2) * SESSION_BUNDLE_SPACING;
}

function lerp(
	a: { x: number; y: number },
	b: { x: number; y: number },
	t: number,
): { x: number; y: number } {
	return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
}

/**
 * The part of `curve` from its start up to `t`, as a curve in its own right.
 *
 * De Casteljau: a piece of a quadratic Bezier is another quadratic. A claim's
 * edge is drawn with this, so it runs along the very line its session would
 * take to the peer it names and simply stops before arriving, rather than
 * curving off to the claim's own position, which is a different chord and so
 * a different arc.
 *
 * A prefix rather than an arbitrary sub-segment, because a prefix is what the
 * one caller wants: `drawnSessionCurve` builds the lane FROM the end that is a
 * peer, so the cut is always at the far end. A session claimed at both ends
 * has no one lane to be a piece of, and is drawn on the straight reading
 * between the two claims instead.
 */
function curvePrefix(curve: SessionCurve, t: number): SessionCurve {
	// The first split point of de Casteljau is the prefix's control point; the
	// second is where the prefix ends, which is the curve sampled at `t`.
	const ctrl = lerp(
		{ x: curve.ax, y: curve.ay },
		{ x: curve.cx, y: curve.cy },
		t,
	);
	const end = bezierAt(curve, t);
	return {
		ax: curve.ax,
		ay: curve.ay,
		cx: ctrl.x,
		cy: ctrl.y,
		bx: end.x,
		by: end.y,
	};
}

/** Sample a quadratic Bezier at parameter `t ∈ [0, 1]`. */
export function bezierAt(
	curve: SessionCurve,
	t: number,
): { x: number; y: number } {
	const u = 1 - t;
	const u2 = u * u;
	const t2 = t * t;
	return {
		x: u2 * curve.ax + 2 * u * t * curve.cx + t2 * curve.bx,
		y: u2 * curve.ay + 2 * u * t * curve.cy + t2 * curve.by,
	};
}

/** Unit tangent at parameter `t`. For a degenerate (control =
 * midpoint, zero-length) curve, returns `{ dx: 0, dy: 0 }`. */
export function bezierTangent(
	curve: SessionCurve,
	t: number,
): { dx: number; dy: number } {
	const dx = 2 * (1 - t) * (curve.cx - curve.ax) +
		2 * t * (curve.bx - curve.cx);
	const dy = 2 * (1 - t) * (curve.cy - curve.ay) +
		2 * t * (curve.by - curve.cy);
	const len = Math.hypot(dx, dy);
	if (len === 0) return { dx: 0, dy: 0 };
	return { dx: dx / len, dy: dy / len };
}

function pairKey(a: string, b: string): string {
	return a < b ? `${a}|${b}` : `${b}|${a}`;
}

// ───────────────────── Message time-arc bundles ─────────────────────
//
// Same architectural trick as session bundles, applied to the time
// dimension. Two messages that **share session, sentT, and
// arrivalT** (i.e. simultaneous on the same wire) get
// **different progress curves** instead of the same linear ramp,
// so at any intermediate moment they're at different positions
// along the spine. If you plotted k(t) for each message, the
// curves would arc above and below the linear diagonal,
// mirror-image arcs in time, exactly the way session bundle edges
// arc above and below their chord in space. They depart together
// at the sender and arrive together at the receiver; only the
// trajectory between differs.
//
// Bundle criterion is strict (same sessionId, same sentT, same
// arrivalT). Looser criteria, e.g. time-overlap connected
// components, were tempting but cause new collisions for
// non-aligned overlaps: a message at kLinear=0.75 with arc and
// another at kLinear=0.25 with the mirror arc can land on the same
// kArced. Restricting to true simultaneity keeps the symmetry that
// makes the arcs predictable.

/** Maximum arc magnitude, how far a message's progress can deviate
 * from linear at the apex.
 *
 * Hard upper bound is `1/π ≈ 0.318`: the derivative of
 * `k + arc · sin(πk)` is `1 + arc · π · cos(πk)`, which goes
 * negative at the endpoints (`cos(πk) = ±1`) once `|arc| > 1/π`.
 * That makes kArced non-monotonic, negative-arc messages crawl
 * backwards at the sender (clamped to 0) and positive-arc messages
 * race ahead and park at the receiver. The dots visibly fail to
 * "depart and arrive together" even though the math intends them
 * to converge at kEased = 0 and kEased = 1.
 *
 * `0.25` keeps a comfortable margin: min endpoint velocity is
 * `1 - 0.25 · π ≈ 0.215`, so the slowest dot is always moving
 * (~22% of average speed at its slow end). Spread at apex is
 * still 50% of the spine, visibly distinct without breakage. */
export const MAX_TEMPORAL_ARC = 0.25;

/** Signed temporal-arc amount for slot `index` of a `size`-member
 * time-overlap bundle. Singleton → 0 (no arc). Multi-member →
 * spread across `[-MAX, +MAX]` regardless of size (adaptive
 * spacing, unlike the fixed-step session bundle), so a 2-message
 * bundle spreads as far as a 10-message bundle. The bigger one
 * just has more slots between the extremes. */
export function temporalArcAmount(index: number, size: number): number {
	if (size <= 1) return 0;
	return ((index / (size - 1)) - 0.5) * 2 * MAX_TEMPORAL_ARC;
}

/** Compute simultaneity bundle indices for every `message-sent`
 * event in the doc. A bundle = all messages on the same session
 * with the same `(sentT, arrivalT, from, to)` tuple. `from / to`
 * are in the key because opposite-direction pairs under mirror
 * arcs collide at the same spatial point (each "lagging" in its
 * own frame lands at the same curve parameter the other is
 * "ahead" at). Strict same-direction bundling keeps the symmetry
 * clean, opposite-direction simultaneous messages stay singletons
 * and just cross at midpoint, which is the right read anyway. */
export function computeMessageTimeBundles(
	events: readonly TimelineEvent[],
): Map<string, SessionBundleEntry> {
	const groups = new Map<string, string[]>();
	for (const ev of events) {
		if (ev.kind !== "message-sent") continue;
		const key = `${ev.sessionId}|${ev.t}|${ev.arrivalT}|${ev.from}→${ev.to}`;
		let list = groups.get(key);
		if (!list) {
			list = [];
			groups.set(key, list);
		}
		list.push(ev.messageId);
	}
	const out = new Map<string, SessionBundleEntry>();
	for (const list of groups.values()) {
		// Stable index = id sort within the simultaneity group.
		list.sort();
		for (let i = 0; i < list.length; i++) {
			out.set(list[i]!, { index: i, size: list.length });
		}
	}
	return out;
}
