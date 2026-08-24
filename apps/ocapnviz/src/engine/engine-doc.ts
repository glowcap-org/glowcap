/**
 * Document-facing Engine methods: entity authoring, row order, visibility,
 * and what the document says about itself.
 *
 * Each method is the public door onto an operation that already lives in
 * `authoring/`, `visibility.ts`, or `document-fields.ts`. The Engine subclass
 * adds the runtime loop, placement, paste, and undo; this class does not
 * know about those.
 */

import type { EndpointAttribution, SessionSide } from "../schema/session-end.ts";
import type { CaptpVersion, Codec, PeerProfile, SessionState, Transport } from "../schema/topology.ts";
import { type ClipboardPayload } from "./schema/clipboard.ts";
import { extractClipboardPayload, type Selection } from "./schema/extract.ts";
import {
	documentDurationFloor as durationFloorOf,
	writeDocumentDuration,
	writeDocumentModified,
	writeMetadataField,
	writeOpeningView,
} from "./document-fields.ts";
import { clampReasonFor, effectiveOfEntity, intrinsicOfEntity } from "./temporal/doc-resolver.ts";
import type { PeerProperty, SessionProperty, SessionValue } from "./trajectory.ts";
import type { TimelineDocument, TimelineEvent } from "./timeline.ts";
import {
	allVisModeOnDoc,
	categoryVisModeOnDoc,
	effectiveRowVisMode as effectiveRowVisModeOnDoc,
	rowVisModeOnDoc,
	setAllVisModeOnDoc,
	setCategoryVisModeOnDoc,
	setRowVisModeOnDoc,
} from "./visibility.ts";
import type { AuthoringContext } from "./authoring/context.ts";
import { applyAuthored as applyAuthoredOnCtx } from "./authoring/events.ts";
import { moveEvent as moveEventOnCtx, type MoveIntent } from "./authoring/moves.ts";
import {
	clearPeerEnd as clearPeerEndOnCtx,
	clearPeerStart as clearPeerStartOnCtx,
	deletePeer as deletePeerOnCtx,
	removePeerUpdate as removePeerUpdateOnCtx,
	setPeerDuration as setPeerDurationOnCtx,
	setPeerEnd as setPeerEndOnCtx,
	setPeerStart as setPeerStartOnCtx,
	setPeerUpdate as setPeerUpdateOnCtx,
	updatePeer as updatePeerOnCtx,
} from "./authoring/peer.ts";
import { reorderRow as reorderRowOnCtx } from "./authoring/rows.ts";
import {
	clearSessionEnd as clearSessionEndOnCtx,
	clearSessionStart as clearSessionStartOnCtx,
	deleteSession as deleteSessionOnCtx,
	removeSessionKeyframe as removeSessionKeyframeOnCtx,
	setSessionDuration as setSessionDurationOnCtx,
	setSessionEnd as setSessionEndOnCtx,
	setSessionInitialState as setSessionInitialStateOnCtx,
	setSessionKeyframe as setSessionKeyframeOnCtx,
	setSessionStart as setSessionStartOnCtx,
	updateSession as updateSessionOnCtx,
	updateSessionEndpoint as updateSessionEndpointOnCtx,
} from "./authoring/session.ts";
import {
	clearMessageStart as clearMessageStartOnCtx,
	deleteMessage as deleteMessageOnCtx,
	setMessageDuration as setMessageDurationOnCtx,
	setMessageEnd as setMessageEndOnCtx,
	setMessageStart as setMessageStartOnCtx,
	updateMessage as updateMessageOnCtx,
} from "./authoring/message.ts";
export abstract class EngineDocApi {
	protected abstract get ctx(): AuthoringContext;
	protected abstract notify(docChanged?: boolean): void;
	abstract beginTransaction(label?: string): void;
	abstract endTransaction(): void;

	/** Append an event, preserving the sort-by-`t` invariant. Extends
	 * `doc.duration` if the event lands past the end (Flash-style: the
	 * timeline grows as you draw past it). Re-seeks so the change
	 * folds in immediately even when paused. Tests stub this directly,
	 * which is why the public surface stays even though the engine
	 * routes through `ctx` everywhere else. */
	applyAuthored(event: TimelineEvent): void {
		applyAuthoredOnCtx(this.ctx, event);
	}

	/**
	 * Remove a peer and everything that depends on it. Cascades:
	 * the peer's own `peer-joined` / `peer-left` events, every
	 * session whose endpoints include the peer (which in turn
	 * cascades to that session's messages), and any message where
	 * the peer is the sender or receiver. The whole cascade lands
	 * as one undo step.
	 */
	deletePeer(peerId: string): void {
		deletePeerOnCtx(this.ctx, peerId);
	}

	deleteSession(sessionId: string): void {
		deleteSessionOnCtx(this.ctx, sessionId);
	}

	deleteMessage(messageId: string): void {
		deleteMessageOnCtx(this.ctx, messageId);
	}

	/** Extract a `ClipboardPayload` from the current doc + a selection.
	 *  Pure read — no engine state change. Caller (UI) holds the
	 *  payload between copy and paste; the engine doesn't carry
	 *  clipboard state. */
	extractPayload(selection: Selection): ClipboardPayload {
		return extractClipboardPayload(this.ctx.doc, selection);
	}

	/** Patch session-level fields.
	 *
	 * - `codec` / `captpVersion` rewrite the `session-opened` event in
	 *   place — these are fundamental to the session's identity, not
	 *   things that change mid-life.
	 * - `state` is timeline-shaped: a non-undefined value inserts a
	 *   `session-state-changed` event at `clock.t` (Flash convention —
	 *   the playhead is where you author). If you want to fix the
	 *   genesis state, edit `initialState` directly on the
	 *   `session-opened` event via a future intent; this path won't
	 *   touch it.
	 */
	updateSession(
		sessionId: string,
		patch: {
			codec?: Codec;
			captpVersion?: CaptpVersion;
			transport?: Transport | null;
			state?: SessionState;
		},
	): void {
		updateSessionOnCtx(this.ctx, sessionId, patch);
	}

	updateMessage(
		messageId: string,
		patch: {
			label?: string;
			sessionId?: string;
			swapDirection?: true;
		},
	): void {
		updateMessageOnCtx(this.ctx, messageId, patch);
	}

	/**
	 * Retime an event in place. `message-sent` is pair-aware: moving
	 * one also moves its paired `message-delivered` so the flight
	 * duration is preserved (the whole message slides as a rigid
	 * unit). The `resize-end` move kind drives the arrival
	 * independently — that's the "drag the right edge" gesture in
	 * the timeline.
	 *
	 * Validates against the doc's pair / ordering constraints. On
	 * rejection, logs a warning and leaves the doc unchanged. The
	 * intent layer's `#isNoOpIntent` already short-circuits "moving
	 * to the same time"; rejections here are real conflicts.
	 *
	 * Extends `doc.duration` when the new time(s) exceed the current
	 * end (Flash convention — same as `applyAuthored`).
	 */
	moveEvent(move: MoveIntent): void {
		moveEventOnCtx(this.ctx, move);
	}

	/** Patch peer-level fields on a `peer-joined` event in place.
	 * `peerId` (key) and `position` (own entry point) are excluded.
	 * Re-seeks so the world rebuilds from the mutated doc — one
	 * mutation site, small cost. */
	updatePeer(
		peerId: string,
		patch: {
			label?: string;
			profile?: PeerProfile;
			designator?: string;
		},
	): void {
		updatePeerOnCtx(this.ctx, peerId, patch);
	}

	/** Set the per-category timeline row order. Listed entity ids
	 * render first in the given order; unlisted entities fall after
	 * by the renderer's default sort (first-event-t). Empty `order`
	 * clears the override for that category. When all categories
	 * are cleared, `rowOrder` itself is removed so docs without any
	 * reorders round-trip without a `rowOrder: {}` clutter field. */
	reorderRow(
		category: "peers" | "sessions" | "messages",
		order: string[],
	): void {
		reorderRowOnCtx(this.ctx, category, order);
	}

	/** Effective start time for an entity, resolving the
	 * implicit-vs-explicit cascade through its context:
	 *
	 *   - World context (root) — start `0`, end `doc.duration`.
	 *   - Peer.context = world. Implicit start = 0.
	 *   - Session.context = both endpoint peers. Implicit start
	 *     = `max(peerA.effectiveStart, peerB.effectiveStart)` —
	 *     the session can't exist until BOTH endpoints exist.
	 *   - Message.context = its session. Implicit start =
	 *     `session.effectiveStart`.
	 *
	 * Explicit values (a creation event in `events`) always win;
	 * absent values inherit from the context up the chain. */
	// Engine-level effective range. Reads from `entity.timing` via
	// the doc-resolver. The engine's constructor calls
	// `projectFromObservations` so every entity is guaranteed to
	// have timing populated.
	effectiveStart(
		category: "peers" | "sessions" | "messages",
		id: string,
	): number {
		return effectiveOfEntity(this.ctx.doc, category, id).start;
	}
	effectiveEnd(
		category: "peers" | "sessions" | "messages",
		id: string,
	): number {
		// doc-resolver returns Infinity for implicit-end peers (world
		// is unbounded). Callers expect `doc.duration` as the visible
		// ceiling — clamp here so the timeline-bounded UI keeps
		// working without a separate "visible end" pass.
		const end = effectiveOfEntity(this.ctx.doc, category, id).end;
		return Number.isFinite(end) ? end : this.ctx.doc.duration;
	}

	/** Intrinsic start — the entity's stored intent after resolving
	 * implicit sides through inheritance, BUT before clamping into
	 * the parent context. Differs from `effectiveStart` only when a
	 * parent context has squeezed the value. */
	intrinsicStart(
		category: "peers" | "sessions" | "messages",
		id: string,
	): number {
		return intrinsicOfEntity(this.ctx.doc, category, id).start;
	}
	intrinsicEnd(
		category: "peers" | "sessions" | "messages",
		id: string,
	): number {
		const end = intrinsicOfEntity(this.ctx.doc, category, id).end;
		return Number.isFinite(end) ? end : this.ctx.doc.duration;
	}

	/** When intrinsic ≠ effective on a side, names the ancestor
	 * that's clamping. Null when the value passes through unchanged.
	 * For peers (parent = unbounded world), always null. */
	clampReason(
		category: "peers" | "sessions" | "messages",
		id: string,
		side: "start" | "end",
	): string | null {
		return clampReasonFor(this.ctx.doc, category, id, side);
	}

	setPeerEnd(peerId: string, t: number): void {
		setPeerEndOnCtx(this.ctx, peerId, t);
	}

	setPeerDuration(peerId: string, duration: number): void {
		setPeerDurationOnCtx(this.ctx, peerId, duration);
	}

	clearPeerEnd(peerId: string): void {
		clearPeerEndOnCtx(this.ctx, peerId);
	}

	setPeerStart(peerId: string, t: number): void {
		setPeerStartOnCtx(this.ctx, peerId, t);
	}

	clearPeerStart(peerId: string): void {
		clearPeerStartOnCtx(this.ctx, peerId);
	}

	/** State one of the peer's temporal properties from `t` onward.
	 *  Inspector trajectory-row edit primitive, and the peer sibling
	 *  of `setSessionKeyframe`. */
	setPeerUpdate(
		peerId: string,
		t: number,
		property: PeerProperty,
		value: string,
	): void {
		setPeerUpdateOnCtx(this.ctx, peerId, t, property, value);
	}

	/** Stop stating one property at exactly `t`. No-op when it stated
	 *  nothing. */
	removePeerUpdate(peerId: string, t: number, property: PeerProperty): void {
		removePeerUpdateOnCtx(this.ctx, peerId, t, property);
	}

	/** Set the session's start: pins `timing.start` explicit at `t`.
	 * Identity from `doc.entities.sessions[sessionId]`. Validates
	 * against the cascade lower bound: `t >= max(peerA.effectiveStart,
	 * peerB.effectiveStart)` — a session can't predate either
	 * endpoint. Mirrors `setPeerStart` for the session level. */
	setSessionStart(sessionId: string, t: number): void {
		setSessionStartOnCtx(this.ctx, sessionId, t);
	}

	clearSessionStart(sessionId: string): void {
		clearSessionStartOnCtx(this.ctx, sessionId);
	}

	setMessageStart(messageId: string, t: number): void {
		setMessageStartOnCtx(this.ctx, messageId, t);
	}

	clearMessageStart(messageId: string): void {
		clearMessageStartOnCtx(this.ctx, messageId);
	}

	setMessageEnd(messageId: string, arrivalT: number): void {
		setMessageEndOnCtx(this.ctx, messageId, arrivalT);
	}

	setMessageDuration(messageId: string, duration: number): void {
		setMessageDurationOnCtx(this.ctx, messageId, duration);
	}

	/** Session counterpart to `setPeerEnd` — pins `timing.duration`
	 * so the session's painted end lands at `t`. Validated against
	 * the painted start (close cannot precede open). */
	setSessionEnd(sessionId: string, t: number): void {
		setSessionEndOnCtx(this.ctx, sessionId, t);
	}

	setSessionDuration(sessionId: string, duration: number): void {
		setSessionDurationOnCtx(this.ctx, sessionId, duration);
	}

	clearSessionEnd(sessionId: string): void {
		clearSessionEndOnCtx(this.ctx, sessionId);
	}

	/** State one of the session's temporal properties from `t` onward —
	 *  a lifecycle change, or one end attaching to a peer. Inspector
	 *  trajectory-row edit primitive, and the session sibling of
	 *  `setPeerUpdate`. */
	setSessionKeyframe(
		sessionId: string,
		property: SessionProperty,
		t: number,
		value: SessionValue,
	): void {
		setSessionKeyframeOnCtx(this.ctx, sessionId, property, t, value);
	}

	/** Stop stating one property at exactly `t`. No-op when it stated
	 *  nothing there. */
	removeSessionKeyframe(
		sessionId: string,
		property: SessionProperty,
		t: number,
	): void {
		removeSessionKeyframeOnCtx(this.ctx, sessionId, property, t);
	}

	/** Edit the session's genesis `initialState` (row 0 of the state
	 *  trajectory — the value the session is born with). */
	setSessionInitialState(sessionId: string, state: SessionState): void {
		setSessionInitialStateOnCtx(this.ctx, sessionId, state);
	}

	/** Edit one end of a session as it is born: its claim, the peer it
	 *  attaches to, and what attributed it. `null` clears a field, so
	 *  `{ peer: null }` leaves the end loose. */
	updateSessionEndpoint(
		sessionId: string,
		side: SessionSide,
		patch: {
			peer?: string | null;
			designator?: string | null;
			attributedBy?: EndpointAttribution | null;
		},
	): void {
		updateSessionEndpointOnCtx(this.ctx, sessionId, side, patch);
	}

	/** Set an entity's per-row stage-visibility mode (four states:
	 * visible / label-hidden / body-hidden / both-hidden). The
	 * three doc arrays (`rowHidden`, `rowLabelHidden`, `rowBodyHidden`)
	 * are mutually exclusive — `setRowVisMode` removes the id from
	 * all three first, then writes it into the bucket for the
	 * target mode. "visible" is the absence-from-all case.
	 *
	 * Empty buckets collapse to `undefined` per category so docs
	 * without any hides round-trip clean. */
	setRowVisMode(
		category: "peers" | "sessions" | "messages",
		id: string,
		mode: "visible" | "label" | "body" | "both",
	): void {
		setRowVisModeOnDoc(
			this.ctx.doc as TimelineDocument,
			category,
			id,
			mode,
		);
		// Same React-subscriber notification as `reorderRow` — without
		// it the gutter eyeball glyph waits for the next clock tick to
		// repaint, even though the Stage updates same-frame.
		this.notify();
	}

	/** Set the category-level visibility flag. INDEPENDENT of per-
	 * entity flags: this writes a single doc field on the category,
	 * doesn't touch entities. Render-time composition (see
	 * `effectiveRowVisMode`) is the only place where the cascade
	 * `all → category → entity` is resolved, so cycling category back
	 * to `visible` reveals whatever the entities were independently
	 * configured for. */
	setCategoryVisMode(
		category: "peers" | "sessions" | "messages",
		mode: "visible" | "label" | "body" | "both",
	): void {
		if (
			setCategoryVisModeOnDoc(
				this.ctx.doc as TimelineDocument,
				category,
				mode,
			)
		) {
			this.notify();
		}
	}

	/** Set the all-rows visibility flag. INDEPENDENT of per-category
	 * and per-entity flags — same cascade rationale as
	 * `setCategoryVisMode`. */
	setAllVisMode(mode: "visible" | "label" | "body" | "both"): void {
		if (setAllVisModeOnDoc(this.ctx.doc as TimelineDocument, mode)) {
			this.notify();
		}
	}

	// Document identity (title, duration, opening view, modified stamp)
	// is written in `./document-fields.ts`. These methods are the door:
	// they notify, and duration also brackets undo.

	/** Set the document's title, or clear it when the text is blank. */
	setDocumentTitle(title: string): void {
		if (writeMetadataField(this.ctx.doc, "dct:title", title)) this.notify();
	}

	/** Set the document's description, or clear it when the text is blank. */
	setDocumentDescription(description: string): void {
		if (writeMetadataField(this.ctx.doc, "dct:description", description)) {
			this.notify();
		}
	}

	/** Set who the document is by, or clear it when the text is blank. */
	setDocumentCreator(creator: string): void {
		if (writeMetadataField(this.ctx.doc, "dct:creator", creator)) {
			this.notify();
		}
	}

	noteDocumentModified(now: string): void {
		writeDocumentModified(this.ctx.doc, now);
		this.notify();
	}

	setDocumentDuration(duration: number): void {
		if (
			writeDocumentDuration(this.ctx.doc, this.ctx.clock, duration, {
				begin: (label) => this.beginTransaction(label),
				end: () => this.endTransaction(),
			})
		) {
			this.notify();
		}
	}

	documentDurationFloor(): number {
		return durationFloorOf(this.ctx.doc);
	}

	setOpeningView(
		view: { zoom: number; center: { x: number; y: number } } | undefined,
	): void {
		if (writeOpeningView(this.ctx.doc, view)) this.notify();
	}

	/** Per-entity stored mode. UI consumers cycling the entity
	 * eyeball read this directly; render-time cascade lives in
	 * `effectiveRowVisMode`. */
	rowVisMode(
		category: "peers" | "sessions" | "messages",
		id: string,
	): "visible" | "label" | "body" | "both" {
		return rowVisModeOnDoc(this.ctx.doc, category, id);
	}

	/** Stored category flag. NOT a roll-up of entity flags. */
	categoryVisMode(
		category: "peers" | "sessions" | "messages",
	): "visible" | "label" | "body" | "both" {
		return categoryVisModeOnDoc(this.ctx.doc, category);
	}

	/** Stored all-rows flag. NOT a roll-up of category flags. */
	allVisMode(): "visible" | "label" | "body" | "both" {
		return allVisModeOnDoc(this.ctx.doc);
	}

	/** Effective per-entity visibility for rendering: composes the
	 * `all → category → entity` cascade. The cascade-bug fix replaces
	 * `effectiveRowVisMode` in `./visibility.ts` only — this method
	 * stays a one-line delegate. */
	effectiveRowVisMode(
		category: "peers" | "sessions" | "messages",
		id: string,
	): "visible" | "label" | "body" | "both" {
		return effectiveRowVisModeOnDoc(this.ctx.doc, category, id);
	}
}
