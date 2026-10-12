/**
 * Validate and commit a planned timeline move.
 *
 * `moves.ts` owns gesture planning. This module owns the shared back half so
 * event-addressed and entity-addressed gestures cannot drift in how they
 * validate ordering, mutate observations, patch authored entity state, or
 * refresh the render projection.
 */

import type { TimelineEvent } from "../timeline.ts";
import { checkDeliveredOrdering, checkMoveOrdering } from "../event-helpers.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { asAuthored, type TimeSpan } from "../temporal/time-span.ts";
import { validationError } from "../errors.ts";
import { SESSION_TRAJECTORY, sessionMomentOf } from "../trajectory.ts";
import type { AuthoringContext } from "./context.ts";
import { bumpEntities, growDurationToFit } from "./events.ts";

/** One observation mutation in a planned gesture. */
export type PlannedMove =
	& { ev: TimelineEvent; newT: number }
	& ({ newArrivalT?: number } | Record<string, never>);

/** Entity-doc rewrite paired with a planned observation move.
 *  Built from the pre-move doc so effective ranges still describe the
 *  gesture's "from" side, then applied after observation mutation. */
export type MovePatch =
	| { kind: "peer-timing"; peerId: string; span: TimeSpan }
	| { kind: "session-timing"; sessionId: string; span: TimeSpan }
	| { kind: "message-timing"; messageId: string; span: TimeSpan }
	| {
		kind: "session-keyframe-move";
		sessionId: string;
		oldT: number;
		newT: number;
	};

function applyPatch(ctx: AuthoringContext, patch: MovePatch): void {
	// `asAuthored`: a patched span is user intent, so it must not carry the
	// projection's derived marker. Otherwise projection could clobber the
	// gesture on the next tick.
	if (patch.kind === "peer-timing") {
		const def = ctx.doc.entities?.peers?.[patch.peerId];
		if (def) def.timing = asAuthored(patch.span);
		return;
	}
	if (patch.kind === "session-timing") {
		const def = ctx.doc.entities?.sessions?.[patch.sessionId];
		if (def) def.timing = asAuthored(patch.span);
		return;
	}
	if (patch.kind === "message-timing") {
		const def = ctx.doc.entities?.messages?.[patch.messageId];
		if (def) def.timing = asAuthored(patch.span);
		return;
	}

	const def = ctx.doc.entities?.sessions?.[patch.sessionId];
	const track = def?.keyframes?.state;
	if (!def || !track) return;
	const ki = track.findIndex((kf) => kf.t === patch.oldT);
	if (ki === -1) return;
	const next = [...track];
	const kf = next[ki]!;
	next.splice(ki, 1);
	let insertAt = next.length;
	for (let i = 0; i < next.length; i++) {
		if (next[i]!.t > patch.newT) {
			insertAt = i;
			break;
		}
	}
	next.splice(insertAt, 0, { t: patch.newT, value: kf.value });
	def.keyframes = { ...def.keyframes, state: next };
}

/** Whether moving `ev` to `newT` would land it where the same session
 *  property already states something, and if so, says so.
 *
 *  A keyframe track holds one value per instant. Silently merging here
 *  would make a drag delete the moment already at that instant. Refusing
 *  leaves the choice to the reader. A moment of another property remains
 *  valid because the tracks are independent. */
export function occupiedMoment(
	ctx: AuthoringContext,
	ev: TimelineEvent,
	newT: number,
): boolean {
	if (newT === ev.t) return false;
	const moment = sessionMomentOf(ev);
	if (moment === null) return false;
	const spec = SESSION_TRAJECTORY[moment.property];
	const clash = primaryObservations(ctx.doc).find((other) =>
		other.id !== ev.id && other.t === newT &&
		spec.read(other, moment.sessionId) !== null
	);
	if (clash === undefined) return false;
	ctx.emitError(validationError(
		`The session already states its ${spec.noun} at ${newT}.`,
		`Drop this one somewhere else, or clear the ${spec.noun} already there.`,
	));
	return true;
}

/** Validate and atomically apply one fully planned gesture. */
export function commitMoves(
	ctx: AuthoringContext,
	events: TimelineEvent[],
	moves: PlannedMove[],
	patches: MovePatch[],
): void {
	// Check against the finished gesture rather than its half-written state;
	// otherwise an entity dragged earlier can be refused by its own trailing
	// events before those events have moved.
	const planned = new Map(moves.map((m) => [m.ev.id, m.newT]));
	for (const m of moves) {
		if (m.newT < 0) {
			ctx.emitError(validationError(
				`Event time (${m.newT}) is before the timeline start.`,
				"Drop the event at t ≥ 0.",
			));
			return;
		}
		const orderErr = checkMoveOrdering(m.ev, m.newT, events, planned);
		if (orderErr) {
			ctx.emitError(orderErr);
			return;
		}
		if (m.ev.kind === "message-delivered") {
			const deliveredErr = checkDeliveredOrdering(
				events,
				m.ev.id,
				m.newT,
				planned,
			);
			if (deliveredErr) {
				ctx.emitError(deliveredErr);
				return;
			}
		}
	}

	for (const m of moves) {
		m.ev.t = m.newT;
		if (m.ev.kind === "message-sent" && m.newArrivalT !== undefined) {
			m.ev.arrivalT = m.newArrivalT;
		}
	}
	events.sort((a, b) => a.t - b.t);
	for (const m of moves) growDurationToFit(ctx, m.ev);
	// These patches were calculated before observation mutation, and keep the
	// authored spans and keyframes that rendering reads aligned with the log.
	for (const patch of patches) applyPatch(ctx, patch);

	// The lane-bundle cache keys on entities identity.
	bumpEntities(ctx);
	ctx.recomputeLayout();
	ctx.seekTo(ctx.clock.t);
}
