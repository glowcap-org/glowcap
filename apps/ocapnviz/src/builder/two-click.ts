/**
 * The two-click open-session and send-message tools.
 *
 * Stage pointer routing, pan vs select vs empty-canvas drop,
 * lives in `use-stage-build-gestures.ts`. This module is the
 * commit step: whether a node is a legal pick, and what the second
 * click writes.
 */

import type React from "react";
import type { Engine } from "../engine/engine.ts";
import { findNode } from "../engine/world.ts";
import type { AppAction } from "../state/app-state.ts";
import type { CaptpVersion, Codec, SessionState } from "../schema/topology.ts";
import {
	attachedEndpoint,
	endpointStageId,
	nodeKindOf,
	unattributedEndpoint,
	UNNAMED_END_LABEL,
} from "../schema/session-end.ts";
import { entityKey, type EntityRef, type EntityRefKey, type SelectionAction } from "../interactions/types.ts";
import { type NodeKind, toolAcceptsNode } from "../interactions/gesture-resolver.ts";
import { asOneEdit } from "./as-one-edit.ts";

/** Whether this id names an end nothing has attributed. `nodeKindOf` owns
 *  the question. This is its yes-or-no reading, for the places that only
 *  need the branch. */
function isLoose(nodeId: string): boolean {
	return nodeKindOf(nodeId) === "endpoint";
}

function singletonSet(entity: EntityRef): ReadonlySet<EntityRefKey> {
	return new Set([entityKey(entity)]);
}

/** Tool-options-bar values that affect the commit step of the
 *  two-click flow. Every field is optional, undefined means "use
 *  engine defaults" (capnp / v1_0 / open / DEFAULT_MESSAGE_FLIGHT_MS).
 *  The bar typically pre-fills the defaults visibly so the user
 *  sees what's about to happen, but the caller decides whether to
 *  forward them. */
export type TwoClickOptions = {
	// open-session
	codec?: Codec;
	captpVersion?: CaptpVersion;
	initialState?: SessionState;
	// send-message
	messageLabel?: string;
	/** Flight duration override in ms. Omit → engine default. */
	flightMs?: number;
};

/**
 * Whether the tool will act on `target`, given what it is already holding.
 *
 * THE question, asked once. `toolAcceptsNode` answers the half that depends
 * only on the tool and the kind of node, which is the whole answer for a
 * first pick. This adds the half that depends on the pick already armed, and
 * it needs the document: whether these two can carry a message between them
 * is a fact about the sessions they are on.
 *
 * The second pick has a rule of its own because an end nothing has attributed
 * can only talk on the session it is an end of. Two peers with no session
 * between them get one opened for the message. An end cannot take a second
 * session, so there is nowhere for a message to it from anywhere else to
 * ride. Without this the pointer read as an invitation over every node on the
 * stage and the commit then refused all but one of them.
 */
export function twoClickAccepts(
	engine: Engine,
	tool: "open-session" | "send-message",
	armedNodeId: string | null,
	target: { kind: NodeKind; id: string },
): "takes" | "refuses" {
	if (toolAcceptsNode(tool, target.kind) !== "takes") return "refuses";
	// Nothing armed yet, so this is the first pick and there is no partner to
	// be wrong for. Re-picking the armed node is the cancel gesture.
	if (armedNodeId === null || armedNodeId === target.id) return "takes";
	if (tool === "open-session") return "takes";
	// A message between two peers opens a session if they need one. With an
	// end nothing has attributed at either side, the only session that can
	// carry it is the one that end already belongs to.
	if (!isLoose(armedNodeId) && !isLoose(target.id)) return "takes";
	return findOpenSessionBetween(engine, armedNodeId, target.id) === null ? "refuses" : "takes";
}

/** Commit step of the two-click open-session / send-message tools.
 *
 * First click (no prior pick): arms the node, it lights up via the
 * selection ring while we wait for its partner.
 *
 * Re-click of the armed node: cancels.
 *
 * Click on a different node: dispatches the intent and resets the armed slot.
 * Send-message auto-opens a session first (in the same undo step) if the two
 * don't already share one, there's no way to author a free-floating message.
 *
 * A node here is a peer OR an unattributed session end, because a message can
 * be sent to an end nothing has attributed: that is what the wire looks like
 * before anything proves who answered, and a recording holds it. What an end
 * cannot do is join a SECOND session. Two ends claiming one address may be one
 * host twice or an impostor beside a real one, and nothing has proved
 * which. A node shared between sessions would be this app asserting they are
 * the same party. The node that IS shared across sessions is the peer, and
 * attribution is how an end becomes one. So a loose end can only talk on its
 * own session, and the auto-open below refuses rather than inventing a peer
 * out of a claim.
 *
 * Tool stays active after commit so chained authoring works
 * (build a star: pick first peer, click each leaf in turn). */
export function advanceTwoClick(
	engine: Engine,
	tool: "open-session" | "send-message",
	firstPickNodeId: string | null,
	clickedNodeId: string,
	dispatch: React.Dispatch<AppAction>,
	dispatchSelection: React.Dispatch<SelectionAction>,
	options?: TwoClickOptions,
): void {
	const clickedKind = nodeKindOf(clickedNodeId);
	if (firstPickNodeId === null) {
		dispatch({ type: "set-first-pick", nodeId: clickedNodeId });
		dispatchSelection({
			kind: "set-selection",
			entities: singletonSet({ kind: clickedKind, id: clickedNodeId }),
		});
		return;
	}
	if (firstPickNodeId === clickedNodeId) {
		dispatch({ type: "set-first-pick", nodeId: null });
		dispatchSelection({ kind: "clear-all" });
		return;
	}
	if (tool === "open-session") {
		// A new session mints its own two ends, so an existing end has nothing to
		// be here. The engine refuses it and says why. The rule is about
		// sessions, not about this tool, so it is stated once where sessions are
		// authored and every caller answers to the same one.
		const sessionId = engine.dispatch({
			kind: "open-session",
			// The two-click tool draws between two peers, so both ends are
			// attached. Authoring an end nothing has attributed is the
			// Inspector's `update-session-endpoint`, not a click on a peer.
			a: attachedEndpoint(firstPickNodeId),
			b: attachedEndpoint(clickedNodeId),
			...(options?.codec !== undefined ? { codec: options.codec } : {}),
			...(options?.captpVersion !== undefined ? { captpVersion: options.captpVersion } : {}),
			...(options?.initialState !== undefined ? { initialState: options.initialState } : {}),
		});
		dispatch({ type: "set-first-pick", nodeId: null });
		if (sessionId) {
			dispatchSelection({
				kind: "set-selection",
				entities: singletonSet({ kind: "session", id: sessionId }),
			});
		}
		return;
	}
	// send-message: auto-find a shared session, or open one first inside a
	// transaction so undo collapses to one step. The lookup is over stage
	// NODES, so an end nothing attributed is found on its own session exactly
	// as a peer is found on one it holds.
	const resolvedSessionId = findOpenSessionBetween(
		engine,
		firstPickNodeId,
		clickedNodeId,
	);
	// With no shared session this opens one, and that is where an end nothing
	// has attributed is turned away: it already belongs to a session, so the
	// open is refused and no message follows. An end can therefore carry
	// messages only on its own session, which is the whole of what it is an
	// end of.
	asOneEdit(engine, "Send message", () => {
		const sessionId = resolvedSessionId ?? engine.dispatch({
			kind: "open-session",
			a: attachedEndpoint(firstPickNodeId),
			b: attachedEndpoint(clickedNodeId),
			// Open-session options apply to the auto-opened session too,
			// user's intent for "what kind of session to use" is the same
			// whether they explicitly opened one or are sending a message
			// that opens one inline.
			...(options?.codec !== undefined ? { codec: options.codec } : {}),
			...(options?.captpVersion !== undefined ? { captpVersion: options.captpVersion } : {}),
			...(options?.initialState !== undefined ? { initialState: options.initialState } : {}),
		});
		if (sessionId) {
			engine.dispatch({
				kind: "send-message",
				sessionId,
				from: firstPickNodeId,
				to: clickedNodeId,
				...(options?.messageLabel !== undefined &&
						options.messageLabel.length > 0
					? { label: options.messageLabel }
					: {}),
				...(options?.flightMs !== undefined &&
						Number.isFinite(options.flightMs)
					? { flightMs: options.flightMs }
					: {}),
			});
		}
	});
	dispatch({ type: "set-first-pick", nodeId: null });
	// Keep the receiver selected so the user sees what they wired up;
	// the message itself is transient and would lose selection on
	// delivery anyway.
	dispatchSelection({
		kind: "set-selection",
		entities: singletonSet({ kind: clickedKind, id: clickedNodeId }),
	});
}

/**
 * Second click of Open Session, landing on empty canvas: open a session from
 * the armed peer to an end nothing has attributed, standing where the click
 * landed.
 *
 * This is the shape a recording holds when a peer dials out and nothing has
 * yet answered for who answered. The wire is real, and who is on the far
 * side of it is open. Build's claim is that every shape a recording can hold
 * can be authored, including this one, which is otherwise reachable only by
 * opening a session between two peers in the Inspector and then detaching an
 * end.
 *
 * It is the opposite of the refusal in `advanceTwoClick`, not an exception to
 * it: a session MINTS its own two ends, so a new end is exactly what it may
 * make, while an existing end already belongs to a session and may not be
 * taken by a second one.
 *
 * The click point becomes the end's pin, because the click is where the
 * author said to put it. Both writes are one transaction, so undo takes back
 * the session and its placement together.
 */
export function openSessionToNewEnd(
	engine: Engine,
	fromPeerId: string,
	at: { x: number; y: number },
	dispatch: React.Dispatch<AppAction>,
	dispatchSelection: React.Dispatch<SelectionAction>,
	options?: TwoClickOptions,
): void {
	let sessionId: string | undefined;
	asOneEdit(engine, "Open session", () => {
		sessionId = engine.dispatch({
			kind: "open-session",
			a: attachedEndpoint(fromPeerId),
			b: unattributedEndpoint(),
			...(options?.codec !== undefined ? { codec: options.codec } : {}),
			...(options?.captpVersion !== undefined ? { captpVersion: options.captpVersion } : {}),
			...(options?.initialState !== undefined ? { initialState: options.initialState } : {}),
		});
		if (sessionId !== undefined) {
			engine.dispatch({
				kind: "reposition-endpoint",
				endpointId: endpointStageId(sessionId, "b"),
				position: at,
			});
		}
	});
	dispatch({ type: "set-first-pick", nodeId: null });
	if (sessionId !== undefined) {
		dispatchSelection({
			kind: "set-selection",
			entities: singletonSet({ kind: "session", id: sessionId }),
		});
	}
}

/** Find an open session whose endpoints are exactly {a, b}, in
 * either order. Returns the session id or null. */
export function findOpenSessionBetween(
	engine: Engine,
	a: string,
	b: string,
): string | null {
	for (const s of engine.queries.sessions) {
		const { a: ea, b: eb } = s.endpoints;
		if ((ea === a && eb === b) || (ea === b && eb === a)) {
			return s.session.id;
		}
	}
	return null;
}

/** Label of the armed peer for the tool-hint banner. Falls back to
 * the id if the peer has no label set. Null when nothing's armed. */
export function armedNodeLabel(
	engine: Engine,
	nodeId: string | null,
): string | null {
	if (!nodeId) return null;
	const node = findNode(engine.world, nodeId);
	if (node === undefined) return nodeId;
	// A node, not a peer: the message tool arms an end nothing has attributed,
	// and such an end answers to the name it claims. Falling through to the
	// stage id would put `s1::b` in front of the reader, which names the slot
	// and not the thing standing in it.
	if ("peer" in node) return node.peer.label;
	return node.endpoint.designator ?? UNNAMED_END_LABEL;
}
