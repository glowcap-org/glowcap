/**
 * Mint a new peer, session, or message from a builder intent.
 *
 * `engine.dispatch` still owns snapshot, undo, and rollback. Intent
 * routing lives in `dispatch.ts`. This module owns the create cases:
 * collide-or-mint an id, write identity into `doc.entities`, and commit
 * so the playable range covers the new mark.
 * Reposition still refreshes the stage on Engine; its document pin
 * write lives in `placement.ts`. Update, delete, and retiming already
 * delegate into `authoring/`.
 */

import { nodeKindOf } from "../../schema/session-end.ts";
import type { CaptpVersion, Codec, SessionState } from "../../schema/topology.ts";
import { collisionError, notFoundError, validationError } from "../errors.ts";
import { defineMessage, definePeer, defineSession } from "../entities.ts";
import { type BuilderIntent, DEFAULT_MESSAGE_FLIGHT_MS } from "../intents.ts";
import { explicitBound, implicitBound } from "../temporal/bound.ts";
import type { TimeSpan } from "../temporal/time-span.ts";
import type { AuthoringContext } from "./context.ts";
import { commitEntityAuthoring } from "./events.ts";

/** Defaults for an `open-session` intent that didn't pin them. */
const DEFAULT_SESSION_CODEC: Codec = "capnp";
const DEFAULT_SESSION_CAPTP: CaptpVersion = "v1_0";
const DEFAULT_SESSION_STATE: SessionState = "open";

export function spawnPeer(
	ctx: AuthoringContext,
	intent: Extract<BuilderIntent, { kind: "add-peer" }>,
): string | undefined {
	// User-supplied id wins over the auto-mint. Collision-rejecting
	// — emit `collisionError` and short-circuit (the doc is
	// untouched at this point so no rollback needed). Matches the
	// `rename-*` paths' UX.
	let peerId: string;
	if (intent.id !== undefined && intent.id.length > 0) {
		if (ctx.doc.entities?.peers?.[intent.id] !== undefined) {
			ctx.emitError(collisionError("peer", intent.id));
			return undefined;
		}
		peerId = intent.id;
	} else {
		peerId = `peer-${ctx.mintId()}`;
	}
	// Identity → entities map. The event payload below
	// carries the same attrs so external consumers reading
	// the recording stream still see them; render-time
	// lookups prefer `doc.entities` so identity stays the
	// source of truth.
	// Seed timing alongside identity. Start = now (authoring t);
	// duration implicit ("alive until something says otherwise").
	// See docs/data-model.md — entity.timing is the display
	// source-of-truth.
	const peerTiming: TimeSpan = {
		start: explicitBound(ctx.clock.t),
		duration: implicitBound(0),
	};
	definePeer(ctx.doc, peerId, {
		profile: intent.profile,
		label: intent.label ?? peerId,
		position: intent.position,
		timing: peerTiming,
	});
	commitEntityAuthoring(ctx, ctx.clock.t);
	return peerId;
}

export function spawnSession(
	ctx: AuthoringContext,
	intent: Extract<BuilderIntent, { kind: "open-session" }>,
): string | undefined {
	// An end that names a peer has to name one the document declares.
	// The check is here rather than in the tool that asked because it is
	// a fact about sessions, and every caller answers to it.
	//
	// A stage id for an unattributed end is the case worth naming: a
	// reader who drags a session onto one is asking for two sessions to
	// share that end, and the answer is that they cannot. Two ends
	// claiming one address may be one host twice or an impostor beside
	// an honest one, and nothing has proved which — so a shared node
	// would be this app asserting they are the same party. The node that
	// IS shared between sessions is the peer, and attributing the end is
	// how it becomes one.
	for (const end of [intent.a, intent.b]) {
		const peer = end.peer;
		if (peer === undefined) continue;
		if (ctx.doc.entities?.peers?.[peer] !== undefined) continue;
		ctx.emitError(
			nodeKindOf(peer) === "endpoint"
				? validationError(
					"A session cannot be opened onto an end nothing has attributed.",
					"Attribute that end to a peer first, then open the session to the peer.",
				)
				: notFoundError("peer", peer),
		);
		return undefined;
	}
	const sessionId = `session-${ctx.mintId()}`;
	const codec = intent.codec ?? DEFAULT_SESSION_CODEC;
	const captpVersion = intent.captpVersion ?? DEFAULT_SESSION_CAPTP;
	const initialState = intent.initialState ?? DEFAULT_SESSION_STATE;
	// Identity belongs to the entity definition; Build mode does not invent a
	// capture observation for a direct document edit.
	const sessionTiming: TimeSpan = {
		start: explicitBound(ctx.clock.t),
		duration: implicitBound(0),
	};
	defineSession(ctx.doc, sessionId, {
		a: intent.a,
		b: intent.b,
		codec,
		captpVersion,
		initialState,
		timing: sessionTiming,
	});
	commitEntityAuthoring(ctx, ctx.clock.t);
	return sessionId;
}

export function spawnMessage(
	ctx: AuthoringContext,
	intent: Extract<BuilderIntent, { kind: "send-message" }>,
): string | undefined {
	const messageId = `msg-${ctx.mintId()}`;
	const flight = intent.flightMs ?? DEFAULT_MESSAGE_FLIGHT_MS;
	const sentT = ctx.clock.t;
	const arrivalT = sentT + flight;
	// Identity → entities map first (see `defineMessage`).
	// Messages: duration is ALWAYS explicit (flight time is a
	// semantic property, not inherited).
	const messageTiming: TimeSpan = {
		start: explicitBound(sentT),
		duration: explicitBound(flight),
	};
	defineMessage(ctx.doc, messageId, {
		sessionId: intent.sessionId,
		from: intent.from,
		to: intent.to,
		...(intent.label !== undefined ? { label: intent.label } : {}),
		// Flight time IS timing.duration; no separate flightMs field.
		timing: messageTiming,
	});
	commitEntityAuthoring(ctx, arrivalT);
	return messageId;
}
