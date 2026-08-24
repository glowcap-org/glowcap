/**
 * `renderFrame` — per-tick world → scene-graph projection.
 *
 * The React host is `Stage.tsx`; the Pixi graph lives in
 * `use-stage-scene.ts`. This module is the world→sprite projection that
 * graph's ticker calls. Pure function: takes everything via
 * `RenderFrameArgs`, mutates the passed-in Pixi containers + sprite
 * Maps, returns void. No module-scope captures from the host.
 *
 * Per-entity sprite create/update lives in `./sprites/`. This module
 * owns visibility, z-order, the live-set sweep, and the call to each
 * kind's sync. Sprite shapes are an implementation detail of those
 * syncs — `Stage` allocates the Maps but never reaches into a sprite's
 * internals. `PeerActivity` is the one type external panels (Sidebar,
 * EntityChips) also need, and it lives in `./types.ts` where they read it.
 */

import type { Container } from "pixi.js";
import { entityKey, type EntityRefKey } from "../interactions/types.ts";
import type { Engine } from "../engine/engine.ts";
import { type SessionCurve } from "../engine/session-geometry.ts";
import type { EdgeStrokeBatch } from "./edge-stroke-batch.ts";
import type { ThemedColors } from "./palette.ts";
import {
	foldActivityByNode,
	type PeerActivity,
	type SelectMode,
	type StageHover,
	type StageSelection,
} from "./types.ts";
import { syncEdgeSprite } from "./sprites/edge.ts";
import { syncEndpointSprite } from "./sprites/endpoint.ts";
import { haloTierFor } from "./sprites/mark.ts";
import { syncMessageSprite } from "./sprites/message.ts";
import { syncPeerSprite } from "./sprites/peer.ts";
import type { EdgeSprite, EndpointSprite, MessageSprite, PeerSprite, StartNodeDrag } from "./sprites/types.ts";

export type RenderFrameArgs = {
	engine: Engine;
	edgeLayer: Container;
	peerLayer: Container;
	messageLayer: Container;
	/** Per-category label sublayers. Add a label to the matching
	 *  one so the parent-side z-stack (peer < session < message)
	 *  pins label layer-ordering to entity-layer ordering. */
	peerLabelLayer: Container;
	sessionLabelLayer: Container;
	messageLabelLayer: Container;
	peerSprites: Map<string, PeerSprite>;
	/** Keyed by endpoint stage id (`sessionId::side`), which cannot collide
	 *  with a peer id, so the two node maps stay disjoint by construction. */
	endpointSprites: Map<string, EndpointSprite>;
	edgeSprites: Map<string, EdgeSprite>;
	/** One Graphics for every session wire — see `edge-stroke-batch.ts`. */
	edgeStrokeBatch: EdgeStrokeBatch;
	messageSprites: Map<string, MessageSprite>;
	onSelect:
		| ((
			selection: StageSelection,
			opts?: { mode?: SelectMode },
		) => void)
		| undefined;
	/** THE selection — sole source of truth for the selected halo
	 * gate. Peers, sessions, and messages by entity key. */
	selection: ReadonlySet<EntityRefKey>;
	/** Anchor — the Inspector-follow entity (and range-extension
	 * pivot). Always inside `selection` when set. Used to paint
	 * an additional inner ring on the anchor's halo so the user
	 * can see WHICH selected entity the Inspector is tracking
	 * when more than one is selected. Single-select case looks
	 * the same as before — anchor + selection collapse. */
	anchor: EntityRefKey | null;
	/** Entities currently inside the in-flight marquee rect.
	 * Painted as a "would be selected" affordance — visually
	 * identical to hover. Empty when no drag is in flight. */
	previewSelection: ReadonlySet<EntityRefKey>;
	hover: StageHover;
	enterHover: (h: StageHover) => void;
	/** Race-safe: only clears if WE're the recorded hover. */
	leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void;
	colors: ThemedColors;
	/** `1 / viewport.scale.x` — applied to label containers so text
	 * stays at constant screen size while positions remain in world
	 * space. */
	counterScale: number;
	/** The camera scale itself, which the selection marks divide by so they hold
	 * one screen size at any zoom. Carried alongside its reciprocal rather than
	 * derived from it, because the two are wanted in different forms: a Pixi
	 * container takes the reciprocal as its own `scale`, and the draw helpers
	 * divide (`drawNodeHalo`, `drawArmedRing`). Deriving one from the other at a
	 * call site is where a second spelling of the camera would start. */
	scale: number;
	/** Sprite pointerdown signals the Stage's drag closure to claim
	 * the gesture. Args: which kind of node and its id, pointer id, cursor
	 * screen coords, the node's current world position.
	 *
	 * Both node kinds take a position an author can pin, so both drag; the
	 * kind rides along because the id alone cannot say which table holds
	 * that position. */
	startNodeDrag: StartNodeDrag;
	/** Which ends this frame draws as claims, and the peer each names —
	 * `engine.frameGeometry.claimsToward`. Passed in rather than derived
	 * here because the Stage's own overlays ask the same question of the
	 * same frame, and two answers would size a ring differently from the
	 * body it rings. */
	claimsToward: ReadonlyMap<string, string>;
	/** Per-session curves from the same `frameGeometry` flight used —
	 * rebuild here and a wire and its dots disagree. */
	sessionCurves: ReadonlyMap<string, SessionCurve>;
	/** Per-frame scratch buffers — owned by the Stage closure and
	 * cleared at the top of each `renderFrame` so the hot path
	 * doesn't allocate fresh `Map`/`Set` instances each tick. */
	scratchActivity: Map<string, PeerActivity>;
	scratchPeerIds: Set<string>;
	scratchEndpointIds: Set<string>;
	scratchSessionIds: Set<string>;
	scratchMessageIds: Set<string>;
};

/** Per-frame world → scene-graph projection. Sprites are created on
 * first sight, destroyed when their entity disappears; the scene
 * graph is materialized ECS, never authoritative. */
export function renderFrame(args: RenderFrameArgs): void {
	const {
		engine,
		edgeLayer,
		peerLayer,
		messageLayer,
		peerLabelLayer,
		sessionLabelLayer,
		messageLabelLayer,
		peerSprites,
		endpointSprites,
		edgeSprites,
		edgeStrokeBatch,
		messageSprites,
		onSelect,
		hover,
		enterHover,
		leaveHover,
		colors,
		counterScale,
		scale,
		startNodeDrag,
	} = args;

	// Selected = a member of `selection`. The Inspector-follow
	// `anchor` slot lives in the same store reducer and is kept
	// consistent with this set, so the visual answer is always
	// "what's in `selection`".
	const { selection, previewSelection, anchor } = args;
	const hoveredPeerId = hover?.kind === "peer" ? hover.id : null;
	const hoveredEndpointId = hover?.kind === "endpoint" ? hover.id : null;
	const hoveredSessionId = hover?.kind === "session" ? hover.id : null;
	const hoveredMessageId = hover?.kind === "message" ? hover.id : null;

	// Activity from in-flight messages, keyed by stage node id rather than by
	// peer: a message on a session whose far end nobody has attributed names
	// that end's stage id as its from or to. Both node kinds below read out of
	// this one map, and the Inspector's chip folds by the same rule.
	const activityByNode = foldActivityByNode(
		engine.queries.messagesInFlight,
		args.scratchActivity,
	);

	// Per-entity stage-visibility cascades `all → category → entity`
	// — `engine.effectiveRowVisMode(category, id)` owns the resolver.
	// This file used to reimplement the cascade locally (build Sets
	// from `engine.doc.rowHidden?.*`, compute per-category overrides,
	// run a `resolveMode` closure). The local copy was structurally
	// identical to the engine version, so any cascade-bug fix in the
	// engine wouldn't reach the Stage. Delegating keeps a single
	// source of truth. Mode `"body"` keeps the label and drops the
	// mark; sync* clears stroked Graphics so hidden bodies do not
	// retain tessellated GPU buffers.

	// Per-entity z-order falls out of iteration order: the engine's
	// `orderedPeers / orderedSessions / orderedMessages` return
	// entities in canonical draw order (Adobe / Flash convention:
	// top of Timeline gutter = on top of Stage). zIndex is just
	// `last - index`, so the first entity in the ordered list
	// paints last (highest z) and ends up on top. Pixi's
	// `sortableChildren` flag (set on the layers above) makes the
	// sort fire lazily — only when a zIndex actually changes.

	const livePeers = args.scratchPeerIds;
	livePeers.clear();
	const peers = engine.orderedPeers();
	const lastPeerIdx = peers.length - 1;
	for (let i = 0; i < peers.length; i++) {
		const e = peers[i]!;
		const peerMode = engine.effectiveRowVisMode("peers", e.peer.id);
		// `both` mode kills the sprite entirely; the other modes
		// keep the sprite around with per-axis `.visible` toggles
		// applied after `syncPeerSprite`.
		if (peerMode === "both") continue;
		livePeers.add(e.peer.id);
		const peerKey = entityKey({ kind: "peer", id: e.peer.id });
		syncPeerSprite(
			e,
			peerSprites,
			peerLayer,
			peerLabelLayer,
			colors,
			haloTierFor(selection, anchor, peerKey),
			hoveredPeerId === e.peer.id || previewSelection.has(peerKey),
			activityByNode.get(e.peer.id) ?? "idle",
			counterScale,
			scale,
			enterHover,
			leaveHover,
			startNodeDrag,
			peerMode !== "body",
		);
		const sprite = peerSprites.get(e.peer.id);
		if (sprite) {
			const z = lastPeerIdx - i;
			sprite.body.zIndex = z;
			sprite.label.zIndex = z;
			// Per-axis visibility from the cascaded mode resolved
			// above: `body` keeps the label but drops the node body;
			// `label` keeps the body but hides the floating name.
			sprite.body.visible = peerMode !== "body";
			sprite.label.visible = peerMode !== "label";
		}
	}
	for (const [id, sprite] of peerSprites) {
		if (!livePeers.has(id)) {
			sprite.body.destroy({ children: true });
			sprite.label.destroy({ children: true });
			peerSprites.delete(id);
		}
	}

	// Unattributed ends, drawn where a peer would be and into the same
	// layer: they occupy a peer's place, so they answer to the peer layer's
	// visibility and pointer gating. Their timeline row is their SESSION's,
	// because an end has no row of its own to hide.
	const liveEndpoints = args.scratchEndpointIds;
	liveEndpoints.clear();
	// Which ends are claims about somebody on stage, asked the way the layout
	// asked it: the document's own resolution, narrowed to what this moment
	// draws. The drawing has to agree with the placement — an end the layout sat
	// on an edge two thirds of the way to Alice is drawn as the lesser of the
	// two shapes, and one standing on its own is drawn at full weight — and it
	// is one map, because the same answer sizes the body, keys the bundle, and
	// cuts the wire below.
	const claimsToward = args.claimsToward;
	for (const e of engine.queries.endpoints) {
		const endpointMode = engine.effectiveRowVisMode(
			"sessions",
			e.endpoint.sessionId,
		);
		if (endpointMode === "both") continue;
		liveEndpoints.add(e.endpoint.id);
		const endpointKey = entityKey({ kind: "endpoint", id: e.endpoint.id });
		syncEndpointSprite(
			e,
			claimsToward.has(e.endpoint.id),
			endpointSprites,
			peerLayer,
			peerLabelLayer,
			colors,
			haloTierFor(selection, anchor, endpointKey),
			hoveredEndpointId === e.endpoint.id ||
				previewSelection.has(endpointKey),
			activityByNode.get(e.endpoint.id) ?? "idle",
			counterScale,
			scale,
			enterHover,
			leaveHover,
			startNodeDrag,
			endpointMode !== "body",
		);
		const sprite = endpointSprites.get(e.endpoint.id);
		if (sprite) {
			sprite.body.visible = endpointMode !== "body";
			sprite.label.visible = endpointMode !== "label";
		}
	}
	for (const [id, sprite] of endpointSprites) {
		if (!liveEndpoints.has(id)) {
			sprite.body.destroy({ children: true });
			sprite.label.destroy({ children: true });
			endpointSprites.delete(id);
		}
	}

	const liveSessions = args.scratchSessionIds;
	liveSessions.clear();
	// Curves from the frame geometry flight already used — edge
	// rendering and `MessageFlightSystem` share one table so a dot and
	// its wire track.
	const curves = args.sessionCurves;
	const sessions = engine.orderedSessions();
	const lastSessionIdx = sessions.length - 1;
	const strokeOrder: string[] = [];
	for (let i = 0; i < sessions.length; i++) {
		const e = sessions[i]!;
		const sessionMode = engine.effectiveRowVisMode(
			"sessions",
			e.session.id,
		);
		if (sessionMode === "both") continue;
		const curve = curves.get(e.session.id);
		// A session with no curve has nowhere to be drawn: an end of it names a
		// peer this moment does not hold, which an end that changed hands reaches
		// whenever the occupant it left is gone before the session is. So it is
		// marked live only from here, on the same test that mints its sprite. The
		// sweep below reads this set as "drawn this frame", so a session counted
		// live without a sprite would keep the LAST frame's line: a wire still
		// reaching a node nothing draws any more.
		if (!curve) continue;
		liveSessions.add(e.session.id);
		const sessionKey = entityKey({ kind: "session", id: e.session.id });
		const drawBody = sessionMode !== "body";
		syncEdgeSprite(
			e,
			curve,
			edgeSprites,
			edgeStrokeBatch,
			edgeLayer,
			sessionLabelLayer,
			onSelect,
			colors,
			haloTierFor(selection, anchor, sessionKey),
			hoveredSessionId === e.session.id ||
				previewSelection.has(sessionKey),
			counterScale,
			scale,
			enterHover,
			leaveHover,
			drawBody,
		);
		if (drawBody) strokeOrder.push(e.session.id);
		const sprite = edgeSprites.get(e.session.id);
		if (sprite) {
			const z = lastSessionIdx - i;
			sprite.hitArea.zIndex = z;
			sprite.label.zIndex = z;
			sprite.hitArea.visible = sessionMode !== "body";
			sprite.label.visible = sessionMode !== "label";
		}
	}
	for (const [id, sprite] of edgeSprites) {
		if (!liveSessions.has(id)) {
			edgeStrokeBatch.remove(id);
			sprite.hitArea.destroy({ children: true });
			sprite.label.destroy({ children: true });
			edgeSprites.delete(id);
		}
	}
	// Later strokes paint on top — reverse so high session z (drawn
	// first in `orderedSessions`) wins at crossings, matching hitArea
	// zIndex (`lastSessionIdx - i`).
	strokeOrder.reverse();
	edgeStrokeBatch.setOrder(strokeOrder);
	edgeStrokeBatch.flush();

	const liveMessages = args.scratchMessageIds;
	liveMessages.clear();
	const messages = engine.orderedMessages();
	const lastMessageIdx = messages.length - 1;
	for (let i = 0; i < messages.length; i++) {
		const e = messages[i]!;
		const messageMode = engine.effectiveRowVisMode(
			"messages",
			e.messageInFlight.id,
		);
		if (messageMode === "both") continue;
		liveMessages.add(e.messageInFlight.id);
		const messageKey = entityKey({
			kind: "message",
			id: e.messageInFlight.id,
		});
		syncMessageSprite(
			e,
			messageSprites,
			messageLayer,
			messageLabelLayer,
			onSelect,
			colors,
			haloTierFor(selection, anchor, messageKey),
			hoveredMessageId === e.messageInFlight.id ||
				previewSelection.has(messageKey),
			counterScale,
			scale,
			enterHover,
			leaveHover,
			messageMode !== "body",
		);
		const sprite = messageSprites.get(e.messageInFlight.id);
		if (sprite) {
			const z = lastMessageIdx - i;
			sprite.container.zIndex = z;
			sprite.label.zIndex = z;
			// Per-axis visibility from the cascaded `messageMode` —
			// same semantic as peers / sessions: `body` drops the
			// dot but keeps the label; `label` keeps the dot but
			// hides the floating name.
			sprite.container.visible = messageMode !== "body";
			sprite.label.visible = messageMode !== "label";
		}
	}
	for (const [id, sprite] of messageSprites) {
		if (!liveMessages.has(id)) {
			sprite.container.destroy({ children: true });
			sprite.label.destroy({ children: true });
			messageSprites.delete(id);
		}
	}
}
