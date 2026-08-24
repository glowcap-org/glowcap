/**
 * How Build-mode Inspector verbs become engine intents.
 *
 * `bindings.ts` is the contract the Inspector renders against. This
 * module is the App's fulfillment of that contract: each field is one
 * `engine.dispatch`, plus the rename/delete paths that also re-anchor
 * or clear the App's selection.
 */

import type { Engine } from "../../engine/engine.ts";
import type { StageSelection } from "../../render/types.ts";
import type { EditorBindings } from "./bindings.ts";

export function bindBuilderEditor(
	engine: Engine,
	hooks: {
		onEntityRenamed: (
			kind: "peer" | "session" | "message",
			oldId: string,
			newId: string,
		) => void;
		onClearStoreSelection: () => void;
	},
): EditorBindings {
	const { onEntityRenamed, onClearStoreSelection } = hooks;
	return {
		onUpdatePeer: (peerId, patch) => engine.dispatch({ kind: "update-peer", peerId, patch }),
		onRepositionPeer: (peerId, position) => engine.dispatch({ kind: "reposition-peer", peerId, position }),
		onUnpinPeer: (peerId) => engine.dispatch({ kind: "clear-peer-position", peerId }),
		onRepositionEndpoint: (endpointId, position) =>
			engine.dispatch({
				kind: "reposition-endpoint",
				endpointId,
				position,
			}),
		onUnpinEndpoint: (endpointId) => engine.dispatch({ kind: "clear-endpoint-position", endpointId }),
		onUpdateSession: (sessionId, patch) => engine.dispatch({ kind: "update-session", sessionId, patch }),
		onUpdateMessage: (messageId, patch) => engine.dispatch({ kind: "update-message", messageId, patch }),
		onMoveEvent: (move) => engine.dispatch({ kind: "move-event", move }),
		onMoveEntitySpan: (move) => engine.dispatch({ kind: "move-entity-span", move }),
		onSetPeerDuration: (peerId, duration) => engine.dispatch({ kind: "set-peer-duration", peerId, duration }),
		onClearPeerEnd: (peerId) => engine.dispatch({ kind: "clear-peer-end", peerId }),
		onSetPeerStart: (peerId, t) => engine.dispatch({ kind: "set-peer-start", peerId, t }),
		onClearPeerStart: (peerId) => engine.dispatch({ kind: "clear-peer-start", peerId }),
		onSetSessionStart: (sessionId, t) => engine.dispatch({ kind: "set-session-start", sessionId, t }),
		onClearSessionStart: (sessionId) => engine.dispatch({ kind: "clear-session-start", sessionId }),
		onSetMessageStart: (messageId, t) => engine.dispatch({ kind: "set-message-start", messageId, t }),
		onClearMessageStart: (messageId) => engine.dispatch({ kind: "clear-message-start", messageId }),
		onSetMessageDuration: (messageId, duration) =>
			engine.dispatch({
				kind: "set-message-duration",
				messageId,
				duration,
			}),
		onSetSessionDuration: (sessionId, duration) =>
			engine.dispatch({
				kind: "set-session-duration",
				sessionId,
				duration,
			}),
		onClearSessionEnd: (sessionId) => engine.dispatch({ kind: "clear-session-end", sessionId }),
		onSetSessionKeyframe: (sessionId, property, t, value) =>
			engine.dispatch({
				kind: "set-session-keyframe",
				sessionId,
				property,
				t,
				value,
			}),
		onRemoveSessionKeyframe: (sessionId, property, t) =>
			engine.dispatch({
				kind: "remove-session-keyframe",
				sessionId,
				property,
				t,
			}),
		onUpdateSessionEndpoint: (sessionId, side, patch) =>
			engine.dispatch({
				kind: "update-session-endpoint",
				sessionId,
				side,
				patch,
			}),
		onSetPeerUpdate: (peerId, t, property, value) =>
			engine.dispatch({
				kind: "set-peer-update",
				peerId,
				t,
				property,
				value,
			}),
		onRemovePeerUpdate: (peerId, t, property) =>
			engine.dispatch({
				kind: "remove-peer-update",
				peerId,
				t,
				property,
			}),
		onSetSessionInitialState: (sessionId, state) =>
			engine.dispatch({
				kind: "set-session-initial-state",
				sessionId,
				state,
			}),
		beginEdit: (label) => engine.beginTransaction(label),
		endEdit: () => engine.endTransaction(),
		validateRename: (kind, oldId, newId) => engine.validate({ kind: `rename-${kind}`, oldId, newId }),
		onRename: (kind, oldId, newId) => {
			// Pre-flight so we don't go through dispatch's bus path
			// for the inline-shown case. The Inspector renders the
			// returned error via <FieldError>; no toast.
			const v = engine.validate({ kind: `rename-${kind}`, oldId, newId });
			if (!v.ok) return v;
			engine.dispatch({ kind: `rename-${kind}`, oldId, newId });
			// Re-anchor the selection at the new id so the Inspector
			// keeps tracking the entity post-rename.
			onEntityRenamed(kind, oldId, newId);
			return v;
		},
		onDelete: (selection: StageSelection) => {
			if (!selection) return;
			// An unattributed end is not deletable: it is one of the two ends
			// its session HAS, so removing it would leave a session with one.
			// Deleting the session takes it, which is the act the user means.
			if (selection.kind === "endpoint") return;
			if (selection.kind === "peer") {
				engine.dispatch({ kind: "delete-peer", peerId: selection.id });
			} else if (selection.kind === "session") {
				engine.dispatch({
					kind: "delete-session",
					sessionId: selection.id,
				});
			} else {
				engine.dispatch({
					kind: "delete-message",
					messageId: selection.id,
				});
			}
			onClearStoreSelection();
		},
	};
}
