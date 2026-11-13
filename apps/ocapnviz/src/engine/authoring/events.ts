/**
 * Insert and remove observations in the primary recording source.
 * Retime lives in [`moves.ts`](./moves.ts). Used by the higher-level
 * peer/session/message authoring modules.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf, primaryObservations } from "../temporal/recording-access.ts";
import type { TimeSpan } from "../temporal/time-span.ts";
import type { AuthoringContext } from "./context.ts";

/** Extend `doc.duration` (and the clock's bound) to cover `event`.
 * Internal. Every path that places an observation at a new time
 * calls this so the playable range always covers what the timeline
 * can paint. */
export function growDurationToFit(
	ctx: AuthoringContext,
	event: TimelineEvent,
): void {
	const need = event.kind === "message-sent" ? Math.max(event.t, event.arrivalT) : event.t;
	growDurationTo(ctx, need);
}

/** Extend `doc.duration` and the clock's bound to `to`, when `to` is past the
 * current end. */
function growDurationTo(ctx: AuthoringContext, to: number): void {
	if (to <= ctx.doc.duration) return;
	(ctx.doc as { duration: number }).duration = to;
	ctx.clock.setDuration(to);
}

/**
 * The last moment this document states anything at.
 *
 * `growDurationToFit` above asks this of one event. This asks it of the whole
 * document, and the two sit together so they cannot disagree about what counts.
 * It is the floor a duration may not go below: a timeline shorter than its own
 * last event hides that event behind an end the scrubber cannot travel past.
 *
 * Stated times, not effective ranges. An effective end is unbounded for anything
 * that never leaves, a peer that joins and stays runs to infinity, so a maximum
 * over those would answer infinity for most documents. What a duration has to
 * cover is where the marks are.
 *
 * Entity timing is read as well as observations, because a Build-authored entity
 * may state a window no observation mentions.
 */
export function latestStatedTime(doc: TimelineDocument): number {
	let latest = 0;
	for (const ev of observationsOf(doc)) {
		latest = Math.max(latest, ev.t);
		if (ev.kind === "message-sent") latest = Math.max(latest, ev.arrivalT);
	}
	for (const group of ["peers", "sessions", "messages"] as const) {
		for (const def of Object.values(doc.entities?.[group] ?? {})) {
			const timing = (def as { timing?: TimeSpan }).timing;
			if (!timing) continue;
			const start = timing.start.value;
			const end = start + timing.duration.value;
			if (Number.isFinite(start)) latest = Math.max(latest, start);
			if (Number.isFinite(end)) latest = Math.max(latest, end);
		}
	}
	return latest;
}

/** Post-mutation orchestration for entity-shaped authoring edits
 *  (timing / keyframes mutated directly on doc.entities, no event
 *  inserted). Grows doc duration to cover the latest t the change
 *  reaches, recomputes the layout so new topology entries get a
 *  keyframe, and seeks to refresh the world. Use after any
 *  syncPeer* / syncSession* / syncMessage* helper. */
export function commitEntityAuthoring(
	ctx: AuthoringContext,
	growToT?: number,
): void {
	if (growToT !== undefined) growDurationTo(ctx, growToT);
	// Bump entities reference so downstream WeakMap caches (e.g. the
	// Scrubber lane-bundle cache) invalidate. Entity authoring mutates
	// `doc.entities` in place; without this swap, viewer caches keyed
	// on identity keep painting the pre-edit shape.
	bumpEntities(ctx);
	ctx.recomputeLayout();
	ctx.seekTo(ctx.clock.t);
}

/** Drop every observation `matches` claims. Returns how many went,
 *  so a caller can tell a real removal from a no-op. */
export function removeObservations(
	ctx: AuthoringContext,
	matches: (ev: TimelineEvent) => boolean,
): number {
	const events = primaryObservations(ctx.doc);
	let removed = 0;
	for (let i = events.length - 1; i >= 0; i--) {
		if (!matches(events[i]!)) continue;
		events.splice(i, 1);
		removed += 1;
	}
	return removed;
}

/** Put `event` in the observation stream at its sorted position,
 *  replacing whatever `matches` claims first. The one write behind
 *  every "a moment happened here" authoring op, a session's state
 *  change, a peer's update, so the two cannot drift in how the
 *  stream is kept sorted or how a moment at the same t is replaced.
 *  The stream stays sorted by `t`. The caller commits.
 *
 *  A replacement KEEPS the id of the moment it replaces: it is the
 *  same moment carrying a new value, and everything that addresses a
 *  moment addresses it by that id, the Inspector row's React key,
 *  the timeline's focus halo, an open drag. Minting a fresh id on
 *  each write tears the row out from under the user: typing one
 *  character into a trajectory row's value field remounted the input
 *  and took the focus with it. */
export function upsertObservation(
	ctx: AuthoringContext,
	matches: (ev: TimelineEvent) => boolean,
	event: TimelineEvent,
): void {
	const existingId = primaryObservations(ctx.doc).find(matches)?.id;
	removeObservations(ctx, matches);
	const events = primaryObservations(ctx.doc);
	if (existingId !== undefined) event = { ...event, id: existingId };
	let insertAt = events.length;
	for (let i = 0; i < events.length; i++) {
		if (events[i]!.t > event.t) {
			insertAt = i;
			break;
		}
	}
	events.splice(insertAt, 0, event);
}

/** Swap `doc.entities` for a shallow copy so downstream WeakMap
 *  caches keyed by its reference (e.g. the Scrubber lane-bundle
 *  cache) invalidate after in-place authoring mutations. */
export function bumpEntities(ctx: AuthoringContext): void {
	if (ctx.doc.entities !== undefined) {
		ctx.doc.entities = { ...ctx.doc.entities };
	}
}
