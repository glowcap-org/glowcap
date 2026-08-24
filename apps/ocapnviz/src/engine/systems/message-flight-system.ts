import { findSession, type GameWorld } from "../world.ts";
import { type EasingFn, smoothstep } from "../easing.ts";
import { bezierAt, type FrameGeometry, temporalArcAmount } from "../session-geometry.ts";

/**
 * MessageFlightSystem — position messages-in-flight along their
 * session edge as an eased lerp from sender to receiver. Pure
 * function of `t`; scrubbing forward and back hits identical
 * positions.
 *
 * Two layers of geometry compose to keep dense traffic legible:
 *
 *   1. The session edge follows a quadratic Bezier curve when the
 *      same peer-pair carries multiple sessions, so each session
 *      reads as its own line. Curves come from `frameGeometry.sessionCurves`,
 *      built once per stage pass from `drawnSessionCurve`.
 *   2. Messages whose flight intervals overlap on the SAME session
 *      get **different progress curves** instead of the same
 *      linear ramp — the same mirror-image arcs that session
 *      bundles use in space, applied to the time dimension. At
 *      any moment in flight, time-bundle siblings sit at different
 *      positions *along* the session spine. Endpoints converge at
 *      the peers (`sin(πk)` taper, same as spatial bundles).
 *
 * Bundle math lives in `session-geometry`; this system only
 * applies it. Messages are positioned **exactly on the session
 * spine** — no extra perpendicular splay. Differentiation comes
 * from when along the spine, not where off of it.
 *
 * Peer positions are handled by `KeyframeLayoutSystem`.
 */

export type MessageFlightConfig = {
	easing: EasingFn;
};

export const DEFAULT_MESSAGE_FLIGHT_CONFIG: MessageFlightConfig = {
	easing: smoothstep,
};

export class MessageFlightSystem {
	readonly config: MessageFlightConfig;

	constructor(config: MessageFlightConfig = DEFAULT_MESSAGE_FLIGHT_CONFIG) {
		this.config = config;
	}

	/** `geometry` is the frame's one claim/bundle resolution — the same maps
	 *  the renderer draws edges from. A dot follows the wire its session is
	 *  drawn as, so it cannot rebuild those tables on its own. */
	update(world: GameWorld, simT: number, geometry: FrameGeometry): void {
		const { sessionCurves, timeBundles } = geometry;
		for (const e of world.with("messageInFlight", "position")) {
			const m = e.messageInFlight;
			const session = findSession(world, m.sessionId);
			const curve = sessionCurves.get(m.sessionId);
			// Without the session entity (or its curve) we can't locate
			// the spine. Skipping keeps the dot at its last position for
			// one frame if the session was just closed at this tick.
			if (!session || !curve) continue;

			const span = Math.max(1, m.arrivalT - m.sentT);
			const kLinear = (simT - m.sentT) / span;
			const kEased = this.config.easing(kLinear);
			const tBundle = timeBundles.get(m.id);
			const arc = tBundle ? temporalArcAmount(tBundle.index, tBundle.size) : 0;
			// Apply the time-arc on top of the eased progress. Same
			// `sin(πk)` taper as the spatial bundle: convergence at the
			// peers, max spread at the chord midpoint.
			const kArced = kEased + arc * Math.sin(Math.PI * kEased);
			// Clamp defensively — `MAX_TEMPORAL_ARC = 0.35` keeps us
			// well inside [0, 1], but bounds-checking costs nothing.
			const kClamped = kArced < 0 ? 0 : kArced > 1 ? 1 : kArced;
			// The session curve always parametrizes a→b, so a message going the
			// other way needs the parameter reversed for k=0 to land at its OWN
			// sender rather than at the curve's `a`.
			//
			// Which way is asked of BOTH ends by name, and neither is assumed to
			// be the matchable one: `from` and `to` name peers, while an end
			// nothing has attributed sits at a node id that is not a peer's. A
			// test for `from === endpoints.a` alone read a non-match as "travels
			// b→a", so every message on a session whose `a` was loose flew
			// backwards. Nothing in the model says which side can be loose, so
			// nothing here may assume it either. A message that matches neither
			// end takes the curve's own direction rather than the reverse.
			const towardA = m.from === session.endpoints.b ||
				m.to === session.endpoints.a;
			const kCurve = towardA ? 1 - kClamped : kClamped;
			const spine = bezierAt(curve, kCurve);

			// In-place mutation — same rationale as KeyframeLayoutSystem:
			// position is owned by the entity, readers sample it
			// synchronously in the same frame, and the new {x, y}
			// allocation per message per tick was visible GC pressure
			// during long-playback profiles.
			e.position.x = spine.x;
			e.position.y = spine.y;
		}
	}
}
