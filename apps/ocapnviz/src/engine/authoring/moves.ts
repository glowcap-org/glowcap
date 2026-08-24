/**
 * Retime a mark or a span. The two addresses — an observation id
 * (`moveEvent`) and an entity (`moveEntitySpan`) — commit through
 * one back half so they cannot drift in what a finished gesture
 * writes. Insert and remove live in [`events.ts`](./events.ts).
 */

import { messageEffective, peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { setSpanEndAt, setSpanStartAt, translateSpan } from "../temporal/time-span.ts";
import { implicitBound } from "../temporal/bound.ts";
import { notFoundError, validationError } from "../errors.ts";
import type { AuthoringContext } from "./context.ts";
import { commitMoves, type MovePatch, occupiedMoment, type PlannedMove } from "./move-commit.ts";

/** Drag gesture against an event. Each variant encodes exactly the
 *  inputs that gesture needs — no booleans that "only matter for
 *  message-sent", no optional `arrivalT` that flips the meaning of
 *  `newT` from "body anchor" to "left edge". The engine narrows on
 *  `kind` to pick the right span-edge writer; an invalid pairing
 *  (e.g. `resize-end` on a peer event) is unrepresentable.
 *
 *  - `translate`: body slide. For message-sent the paired delivered
 *    auto-slides by the same dt (flight time preserved); for
 *    peer-joined and session-opened, every event scoped to the same
 *    entity slides by dt.
 *  - `resize-start`: left-edge resize. For peer-joined and
 *    session-opened, only the start moves and the paired close
 *    stays put. For message-sent, sent moves and arrival stays
 *    pinned.
 *  - `resize-end`: message-only — sent stays, arrival moves to
 *    `newArrivalT`. Span-shaped peers/sessions resize on the right
 *    by `translate`-ing the close event (peer-left, session-closed)
 *    directly, since the close event IS the right edge. */
export type MoveIntent =
	| { kind: "translate"; eventId: string; newT: number }
	| { kind: "resize-start"; eventId: string; newT: number }
	| { kind: "resize-end"; eventId: string; newArrivalT: number };

/** A span-shaped entity a timeline drag can retime — peer or session.
 *  Messages stay event-addressed: a message always has its
 *  `message-sent` observation, so the event path covers it. */
export type SpanRef = { kind: "peer" | "session"; id: string };

/** Drag gesture against an entity's span, addressed by the entity
 *  itself rather than an observation event. This is what makes a
 *  freshly authored entity — which has `entity.timing` but no
 *  observation events yet — retimeable exactly like a loaded one:
 *  the gesture names the span, and whatever observations exist are
 *  kept in sync as a consequence, not consulted as a precondition.
 *
 *  `newT` is the new time of the edge the gesture drives: the span
 *  start for `translate` and `resize-start`, the span end for
 *  `resize-end`. */
export type MoveSpanIntent = {
	kind: "translate" | "resize-start" | "resize-end";
	ref: SpanRef;
	newT: number;
};

/** Retime an event without changing its shape. Foundation for
 * timeline-drag editing.
 *
 * The render reads `entity.timing`, not the observation log, so
 * every gesture also writes `timing.start` / `timing.duration` (and
 * `keyframes.state` for session-state-changed pair-slides). Without
 * that dual-write the user drags the pill and nothing appears to
 * happen because the projected span stays put.
 *
 * Validates against ordering constraints (peer-left after
 * peer-joined, session-state-changed after session-opened,
 * message-delivered after message-sent, etc.) and rejects invalid
 * moves via the engine error channel. Auto-extends `doc.duration` if the
 * new time(s) exceed the current end. */
export function moveEvent(
	ctx: AuthoringContext,
	intent: MoveIntent,
): void {
	const events = primaryObservations(ctx.doc);
	const idx = events.findIndex((e) => e.id === intent.eventId);
	if (idx === -1) return;
	const ev = events[idx]!;
	// resize-end's anchor is `newArrivalT`; translate / resize-start
	// both work off `newT`. Resolve once for the validation gate.
	const anchorT = intent.kind === "resize-end" ? intent.newArrivalT : intent.newT;
	if (anchorT < 0) {
		ctx.emitError(validationError(
			`Event time (${anchorT}) is before the timeline start.`,
			"Drop the event at t ≥ 0.",
		));
		return;
	}

	// Build the move plan. Two pieces, paired so a future reader sees
	// them as one gesture:
	//   - `moves`: observation mutations (anchor + pair-slides).
	//   - `patches`: every entity-doc rewrite needed to keep the
	//     renderer's read of `entity.timing` / `entity.keyframes`
	//     agreeing with the gesture. Built from the pre-move state,
	//     applied after observations are mutated.
	// All patch computation reads pre-move effective ranges, so it
	// MUST happen before the observation-apply loop.
	const moves: PlannedMove[] = [];
	const patches: MovePatch[] = [];

	if (ev.kind === "message-sent") {
		let newT: number;
		let newArrivalT: number;
		if (intent.kind === "translate") {
			const dt = intent.newT - ev.t;
			newT = intent.newT;
			newArrivalT = ev.arrivalT + dt;
		} else if (intent.kind === "resize-start") {
			newT = intent.newT;
			newArrivalT = ev.arrivalT;
		} else {
			newT = ev.t;
			newArrivalT = intent.newArrivalT;
		}
		if (newArrivalT < newT) {
			ctx.emitError(validationError(
				`Arrival (${newArrivalT}) cannot precede the send (${newT}).`,
				"Move arrival after the send, or move the send earlier.",
			));
			return;
		}
		moves.push({ ev, newT, newArrivalT });
		const delivered = events.find(
			(e) => e.kind === "message-delivered" && e.messageId === ev.messageId,
		);
		if (delivered) moves.push({ ev: delivered, newT: newArrivalT });
		const def = ctx.doc.entities?.messages?.[ev.messageId];
		if (def?.timing) {
			const eff = messageEffective(ctx.doc, ev.messageId);
			// Translate dt is measured against the painted start, not the
			// observation's t — the two can differ after a storage-shaped
			// Inspector edit, and the pill must land where the gesture
			// dropped it. The observation itself still moves to `newT`.
			const span = intent.kind === "resize-start"
				? setSpanStartAt(def.timing, newT, eff.end)
				: intent.kind === "resize-end"
				? setSpanEndAt(eff.start, newArrivalT)
				: translateSpan(
					def.timing,
					newT - eff.start,
					eff.start,
					eff.end,
				);
			patches.push({
				kind: "message-timing",
				messageId: ev.messageId,
				span,
			});
		}
	} else if (ev.kind === "peer-joined") {
		if (intent.kind === "resize-end") {
			ctx.emitError(validationError(
				"Right-edge resize on peer-joined is not supported.",
				"Drag the peer-left event instead — it is the right edge.",
			));
			return;
		}
		const newT = intent.newT;
		const dt = newT - ev.t;
		moves.push({ ev, newT });
		if (intent.kind === "translate") {
			// The whole peer moves: its departure and every update keep
			// their spacing from the join, the way a session's state
			// changes ride along with it below. An update needs no keyframe
			// patch beside the move — the projection re-derives every
			// property's track from these observations on the next run.
			for (const e of events) {
				if (e === ev) continue;
				if (
					(e.kind === "peer-left" || e.kind === "peer-updated") &&
					e.peerId === ev.peerId
				) {
					moves.push({ ev: e, newT: e.t + dt });
				}
			}
		}
		const def = ctx.doc.entities?.peers?.[ev.peerId];
		if (def?.timing) {
			const eff = peerEffective(ctx.doc, ev.peerId);
			// Painted-start dt for the span patch; see the message branch.
			patches.push({
				kind: "peer-timing",
				peerId: ev.peerId,
				span: intent.kind === "resize-start" ? setSpanStartAt(def.timing, newT, eff.end) : translateSpan(
					def.timing,
					newT - eff.start,
					eff.start,
					eff.end,
				),
			});
		}
	} else if (ev.kind === "peer-left") {
		if (intent.kind !== "translate") {
			ctx.emitError(validationError(
				`Only translate is supported on peer-left.`,
				"Resize the peer from the left edge of its peer-joined event.",
			));
			return;
		}
		const newT = intent.newT;
		moves.push({ ev, newT });
		const def = ctx.doc.entities?.peers?.[ev.peerId];
		if (def?.timing) {
			const eff = peerEffective(ctx.doc, ev.peerId);
			patches.push({
				kind: "peer-timing",
				peerId: ev.peerId,
				span: setSpanEndAt(eff.start, newT),
			});
		}
	} else if (ev.kind === "session-opened") {
		if (intent.kind === "resize-end") {
			ctx.emitError(validationError(
				"Right-edge resize on session-opened is not supported.",
				"Drag the session-closed event instead — it is the right edge.",
			));
			return;
		}
		const newT = intent.newT;
		const dt = newT - ev.t;
		moves.push({ ev, newT });
		if (intent.kind === "translate") {
			// The whole session moves: its close and every moment on its
			// trajectory keep their spacing from the open. An endpoint
			// attribution needs no keyframe patch beside the move — the
			// projection re-derives that track from these observations on
			// the next run — while the state track is authored on the
			// definition and has to be moved there too.
			for (const e of events) {
				if (e === ev) continue;
				if (
					(e.kind === "session-closed" ||
						e.kind === "session-state-changed" ||
						e.kind === "session-endpoint-attributed") &&
					e.sessionId === ev.sessionId
				) {
					const slidT = e.t + dt;
					moves.push({ ev: e, newT: slidT });
					if (e.kind === "session-state-changed") {
						patches.push({
							kind: "session-keyframe-move",
							sessionId: e.sessionId,
							oldT: e.t,
							newT: slidT,
						});
					}
				}
			}
		}
		const def = ctx.doc.entities?.sessions?.[ev.sessionId];
		if (def?.timing) {
			const eff = sessionEffective(ctx.doc, ev.sessionId);
			// Painted-start dt for the span patch; see the message branch.
			patches.push({
				kind: "session-timing",
				sessionId: ev.sessionId,
				span: intent.kind === "resize-start" ? setSpanStartAt(def.timing, newT, eff.end) : translateSpan(
					def.timing,
					newT - eff.start,
					eff.start,
					eff.end,
				),
			});
		}
	} else if (ev.kind === "session-closed") {
		if (intent.kind !== "translate") {
			ctx.emitError(validationError(
				`Only translate is supported on session-closed.`,
				"Resize the session from the left edge of its session-opened event.",
			));
			return;
		}
		const newT = intent.newT;
		moves.push({ ev, newT });
		const def = ctx.doc.entities?.sessions?.[ev.sessionId];
		if (def?.timing) {
			const eff = sessionEffective(ctx.doc, ev.sessionId);
			patches.push({
				kind: "session-timing",
				sessionId: ev.sessionId,
				span: setSpanEndAt(eff.start, newT),
			});
		}
	} else if (ev.kind === "session-state-changed") {
		if (intent.kind !== "translate") {
			ctx.emitError(validationError(
				`Only translate is supported on session-state-changed.`,
				"Edge resizes apply to span boundaries, not interior keyframes.",
			));
			return;
		}
		const newT = intent.newT;
		if (occupiedMoment(ctx, ev, newT)) return;
		moves.push({ ev, newT });
		patches.push({
			kind: "session-keyframe-move",
			sessionId: ev.sessionId,
			oldT: ev.t,
			newT,
		});
	} else {
		if (intent.kind !== "translate") {
			ctx.emitError(validationError(
				`Only translate is supported on ${ev.kind}.`,
				"Edge resizes apply to peer / session / message events only.",
			));
			return;
		}
		if (occupiedMoment(ctx, ev, intent.newT)) return;
		moves.push({ ev, newT: intent.newT });
	}

	commitMoves(ctx, events, moves, patches);
}

/** Retime a peer or session span by naming the entity (see
 *  `MoveSpanIntent`). Anchored on the effective range — the same
 *  source of truth the timeline paints — so the gesture means "the
 *  edge you can see moves to `newT`". Observation events that exist
 *  for the entity move to agree; an entity with no observations yet
 *  (freshly authored) retimes through `entity.timing` alone.
 */
export function moveEntitySpan(
	ctx: AuthoringContext,
	intent: MoveSpanIntent,
): void {
	const { ref, newT } = intent;
	const events = primaryObservations(ctx.doc);
	const moves: PlannedMove[] = [];
	const patches: MovePatch[] = [];
	if (newT < 0) {
		ctx.emitError(validationError(
			`Event time (${newT}) is before the timeline start.`,
			"Drop the edge at t \u2265 0.",
		));
		return;
	}

	if (ref.kind === "peer") {
		const def = ctx.doc.entities?.peers?.[ref.id];
		if (!def) {
			ctx.emitError(notFoundError("peer", ref.id));
			return;
		}
		const timing = def.timing ?? {
			start: implicitBound(0),
			duration: implicitBound(0),
		};
		const eff = peerEffective(ctx.doc, ref.id);
		const joined = events.find(
			(e) => e.kind === "peer-joined" && e.peerId === ref.id,
		);
		const left = events.find(
			(e) => e.kind === "peer-left" && e.peerId === ref.id,
		);
		if (intent.kind === "resize-start") {
			if (Number.isFinite(eff.end) && newT > eff.end) {
				ctx.emitError(validationError(
					`Peer start (${newT}) is after its end (${eff.end}).`,
					"Move the start handle before the end.",
				));
				return;
			}
			if (joined) moves.push({ ev: joined, newT });
			patches.push({
				kind: "peer-timing",
				peerId: ref.id,
				span: setSpanStartAt(timing, newT, eff.end),
			});
		} else if (intent.kind === "resize-end") {
			if (newT < eff.start) {
				ctx.emitError(validationError(
					`Peer end (${newT}) is before its start (${eff.start}).`,
					"Move the end handle after the start.",
				));
				return;
			}
			if (left) moves.push({ ev: left, newT });
			patches.push({
				kind: "peer-timing",
				peerId: ref.id,
				span: setSpanEndAt(eff.start, newT),
			});
		} else {
			const dt = newT - eff.start;
			if (joined) moves.push({ ev: joined, newT });
			if (left && Number.isFinite(eff.end)) {
				moves.push({ ev: left, newT: eff.end + dt });
			}
			patches.push({
				kind: "peer-timing",
				peerId: ref.id,
				span: translateSpan(timing, dt, eff.start, eff.end),
			});
		}
	} else {
		const def = ctx.doc.entities?.sessions?.[ref.id];
		if (!def) {
			ctx.emitError(notFoundError("session", ref.id));
			return;
		}
		const timing = def.timing ?? {
			start: implicitBound(0),
			duration: implicitBound(0),
		};
		const eff = sessionEffective(ctx.doc, ref.id);
		const opened = events.find(
			(e) => e.kind === "session-opened" && e.sessionId === ref.id,
		);
		const closed = events.find(
			(e) => e.kind === "session-closed" && e.sessionId === ref.id,
		);
		if (intent.kind === "resize-start") {
			if (Number.isFinite(eff.end) && newT > eff.end) {
				ctx.emitError(validationError(
					`Session start (${newT}) is after its end (${eff.end}).`,
					"Move the start handle before the end.",
				));
				return;
			}
			if (opened) moves.push({ ev: opened, newT });
			patches.push({
				kind: "session-timing",
				sessionId: ref.id,
				span: setSpanStartAt(timing, newT, eff.end),
			});
		} else if (intent.kind === "resize-end") {
			if (newT < eff.start) {
				ctx.emitError(validationError(
					`Session end (${newT}) is before its start (${eff.start}).`,
					"Move the end handle after the start.",
				));
				return;
			}
			if (closed) moves.push({ ev: closed, newT });
			patches.push({
				kind: "session-timing",
				sessionId: ref.id,
				span: setSpanEndAt(eff.start, newT),
			});
		} else {
			const dt = newT - eff.start;
			if (opened) moves.push({ ev: opened, newT });
			for (const e of events) {
				if (e.kind === "session-closed" && e.sessionId === ref.id) {
					moves.push({ ev: e, newT: e.t + dt });
				}
				// Every moment on the session's trajectory rides along; see
				// the same slide in `moveEvent` for why only the state track
				// needs a patch beside the move.
				if (
					e.kind === "session-endpoint-attributed" &&
					e.sessionId === ref.id
				) {
					moves.push({ ev: e, newT: e.t + dt });
				}
				if (
					e.kind === "session-state-changed" && e.sessionId === ref.id
				) {
					const slidT = e.t + dt;
					moves.push({ ev: e, newT: slidT });
					patches.push({
						kind: "session-keyframe-move",
						sessionId: ref.id,
						oldT: e.t,
						newT: slidT,
					});
				}
			}
			patches.push({
				kind: "session-timing",
				sessionId: ref.id,
				span: translateSpan(timing, dt, eff.start, eff.end),
			});
		}
	}

	commitMoves(ctx, events, moves, patches);
}
