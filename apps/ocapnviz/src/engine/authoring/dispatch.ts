/**
 * How a `BuilderIntent` becomes a document mutation.
 *
 * `Engine.dispatch` still owns snapshot, undo, and rollback. This module
 * owns the routing: spawn, entity authoring, visibility, rename, and the
 * four placement commands that must refresh the stage the same frame.
 * Those four stay a narrow host because a pin is not a ctx write — it
 * recomputes layout and re-runs messages so in-flight dots follow the
 * dragged wire.
 */

import type { BuilderIntent } from "../intents.ts";
import { setAllVisModeOnDoc, setCategoryVisModeOnDoc, setRowVisModeOnDoc } from "../visibility.ts";
import type { TimelineDocument } from "../timeline.ts";
import { rekeyEntity } from "./identity.ts";
import type { AuthoringContext } from "./context.ts";
import { moveEntitySpan, moveEvent } from "./moves.ts";
import {
	clearPeerEnd,
	clearPeerStart,
	deletePeer,
	removePeerUpdate,
	setPeerDuration,
	setPeerEnd,
	setPeerStart,
	setPeerUpdate,
	updatePeer,
} from "./peer.ts";
import { reorderRow } from "./rows.ts";
import {
	clearSessionEnd,
	clearSessionStart,
	deleteSession,
	removeSessionKeyframe,
	setSessionDuration,
	setSessionEnd,
	setSessionInitialState,
	setSessionKeyframe,
	setSessionStart,
	updateSession,
	updateSessionEndpoint,
} from "./session.ts";
import {
	clearMessageStart,
	deleteMessage,
	setMessageDuration,
	setMessageEnd,
	setMessageStart,
	updateMessage,
} from "./message.ts";
import { spawnMessage, spawnPeer, spawnSession } from "./spawn.ts";

/**
 * Placement is Engine-owned: a pin write must recompute layout and
 * refresh in-flight messages this frame. Every other intent is a ctx op.
 */
export type PlacementCommands = {
	repositionPeer(peerId: string, position: { x: number; y: number }): void;
	clearPeerPosition(peerId: string): void;
	repositionEndpoint(
		endpointId: string,
		position: { x: number; y: number },
	): void;
	clearEndpointPosition(endpointId: string): void;
};

export function applyBuilderIntent(
	ctx: AuthoringContext,
	intent: BuilderIntent,
	pins: PlacementCommands,
): string | undefined {
	switch (intent.kind) {
		case "add-peer":
			return spawnPeer(ctx, intent);
		case "reposition-peer":
			pins.repositionPeer(intent.peerId, intent.position);
			return undefined;
		case "clear-peer-position":
			pins.clearPeerPosition(intent.peerId);
			return undefined;
		case "reposition-endpoint":
			pins.repositionEndpoint(intent.endpointId, intent.position);
			return undefined;
		case "clear-endpoint-position":
			pins.clearEndpointPosition(intent.endpointId);
			return undefined;
		case "update-peer":
			updatePeer(ctx, intent.peerId, intent.patch);
			return undefined;
		case "open-session":
			return spawnSession(ctx, intent);
		case "send-message":
			return spawnMessage(ctx, intent);
		case "delete-peer":
			deletePeer(ctx, intent.peerId);
			return undefined;
		case "delete-session":
			deleteSession(ctx, intent.sessionId);
			return undefined;
		case "delete-message":
			deleteMessage(ctx, intent.messageId);
			return undefined;
		case "update-session":
			updateSession(ctx, intent.sessionId, intent.patch);
			return undefined;
		case "update-message":
			updateMessage(ctx, intent.messageId, intent.patch);
			return undefined;
		case "move-event":
			moveEvent(ctx, intent.move);
			return undefined;
		case "move-entity-span":
			moveEntitySpan(ctx, intent.move);
			return undefined;
		case "set-peer-end":
			setPeerEnd(ctx, intent.peerId, intent.t);
			return undefined;
		case "set-peer-duration":
			setPeerDuration(ctx, intent.peerId, intent.duration);
			return undefined;
		case "clear-peer-end":
			clearPeerEnd(ctx, intent.peerId);
			return undefined;
		case "set-peer-start":
			setPeerStart(ctx, intent.peerId, intent.t);
			return undefined;
		case "set-peer-update":
			setPeerUpdate(
				ctx,
				intent.peerId,
				intent.t,
				intent.property,
				intent.value,
			);
			return undefined;
		case "remove-peer-update":
			removePeerUpdate(ctx, intent.peerId, intent.t, intent.property);
			return undefined;
		case "clear-peer-start":
			clearPeerStart(ctx, intent.peerId);
			return undefined;
		case "set-session-start":
			setSessionStart(ctx, intent.sessionId, intent.t);
			return undefined;
		case "clear-session-start":
			clearSessionStart(ctx, intent.sessionId);
			return undefined;
		case "set-message-start":
			setMessageStart(ctx, intent.messageId, intent.t);
			return undefined;
		case "clear-message-start":
			clearMessageStart(ctx, intent.messageId);
			return undefined;
		case "set-message-end":
			setMessageEnd(ctx, intent.messageId, intent.t);
			return undefined;
		case "set-message-duration":
			setMessageDuration(ctx, intent.messageId, intent.duration);
			return undefined;
		case "set-session-end":
			setSessionEnd(ctx, intent.sessionId, intent.t);
			return undefined;
		case "set-session-duration":
			setSessionDuration(ctx, intent.sessionId, intent.duration);
			return undefined;
		case "clear-session-end":
			clearSessionEnd(ctx, intent.sessionId);
			return undefined;
		case "set-session-keyframe":
			setSessionKeyframe(
				ctx,
				intent.sessionId,
				intent.property,
				intent.t,
				intent.value,
			);
			return undefined;
		case "remove-session-keyframe":
			removeSessionKeyframe(
				ctx,
				intent.sessionId,
				intent.property,
				intent.t,
			);
			return undefined;
		case "set-session-initial-state":
			setSessionInitialState(ctx, intent.sessionId, intent.state);
			return undefined;
		case "update-session-endpoint":
			updateSessionEndpoint(
				ctx,
				intent.sessionId,
				intent.side,
				intent.patch,
			);
			return undefined;
		case "reorder-row":
			reorderRow(ctx, intent.category, intent.order);
			return undefined;
		case "set-row-vis-mode":
			setRowVisModeOnDoc(
				ctx.doc as TimelineDocument,
				intent.category,
				intent.id,
				intent.mode,
			);
			ctx.notify();
			return undefined;
		case "set-category-vis-mode":
			if (
				setCategoryVisModeOnDoc(
					ctx.doc as TimelineDocument,
					intent.category,
					intent.mode,
				)
			) {
				ctx.notify();
			}
			return undefined;
		case "set-all-vis-mode":
			if (setAllVisModeOnDoc(ctx.doc as TimelineDocument, intent.mode)) {
				ctx.notify();
			}
			return undefined;
		case "rename-peer":
		case "rename-session":
		case "rename-message": {
			// Rejection on collision surfaces through the error
			// channel; the dispatch atomic-rollback path keeps the
			// doc untouched so the UI's pre-flight `validate` and the
			// actual mutation agree.
			const category = intent.kind === "rename-peer"
				? "peer"
				: intent.kind === "rename-session"
				? "session"
				: "message";
			const result = rekeyEntity(
				ctx,
				category,
				intent.oldId,
				intent.newId,
			);
			if (!result.ok) ctx.emitError(result.error);
			return undefined;
		}
	}
}
