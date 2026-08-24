/**
 * The Inspector's editor contract. App provides this only in Build.
 * `beginEdit`/`endEdit` brackets a focus session so a typing burst
 * collapses to one undo step.
 */

import type { StageSelection } from "../../render/types.ts";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/moves.ts";
import type { EngineResult } from "../../engine/errors.ts";
import type { CaptpVersion, Codec, PeerProfile, SessionState, Transport } from "../../schema/topology.ts";
import type { EndpointAttribution, SessionSide } from "../../schema/session-end.ts";
import type { PeerProperty, SessionProperty, SessionValue } from "../../engine/trajectory.ts";

/** When set, the Details section renders writable fields and the
 * delete affordance. App provides this only in build mode.
 * `beginEdit`/`endEdit` brackets a focus session so a typing burst
 * collapses to one undo step; the label becomes the action name in
 * the undo tooltip. `onDelete` cascades through the engine
 * (deleting a peer removes its sessions and their messages). */
export type EditorBindings = {
	onUpdatePeer: (
		peerId: string,
		patch: {
			label?: string;
			profile?: PeerProfile;
			designator?: string;
		},
	) => void;
	/** Reposition (= pin) a peer from the inspector's coordinate
	 * fields — same intent the stage drag dispatches. */
	onRepositionPeer: (
		peerId: string,
		position: { x: number; y: number },
	) => void;
	/** Unpin a peer: drop its authored position so the force layout
	 * places it again — the inverse of drag-to-pin. */
	onUnpinPeer: (peerId: string) => void;
	/** Pin a session end nothing has attributed, by its `sessionId::side`
	 * stage id. The endpoint sibling of `onRepositionPeer`, separate
	 * because the position lands on the session that owns the end. */
	onRepositionEndpoint: (
		endpointId: string,
		position: { x: number; y: number },
	) => void;
	/** Unpin a session end. */
	onUnpinEndpoint: (endpointId: string) => void;
	onUpdateSession: (
		sessionId: string,
		patch: {
			codec?: Codec;
			captpVersion?: CaptpVersion;
			/** The netlayer the session runs over; `null` stops stating one. */
			transport?: Transport | null;
			state?: SessionState;
		},
	) => void;
	onUpdateMessage: (
		messageId: string,
		patch: {
			label?: string;
			sessionId?: string;
			swapDirection?: true;
		},
	) => void;
	/** Retime a single event. Pass a tagged-union `MoveIntent` so each
	 *  gesture (`translate` body slide, `resize-start` left edge,
	 *  `resize-end` message right edge) declares exactly the inputs
	 *  it needs. */
	onMoveEvent: (move: MoveIntent) => void;
	/** Retime a peer or session span addressed by entity — the write
	 *  path for spans with no anchor observation event (freshly
	 *  authored entities), and the timeline drag's dispatch for them. */
	onMoveEntitySpan: (move: MoveSpanIntent) => void;
	/** Storage-shaped peer duration edit. Inspector dispatches this
	 *  directly; the eternal-peer case stays a real option —
	 *  `onClearPeerEnd` removes the `peer-left` event entirely.
	 *  Absolute-time end edits flow through `move-event` (drag) or
	 *  the `set-peer-end` intent on the engine directly. */
	onSetPeerDuration: (peerId: string, duration: number) => void;
	onClearPeerEnd: (peerId: string) => void;
	/** Opt-in START time for a peer — mirror of the end-time
	 * pair. `onClearPeerStart` makes the peer eternal-start
	 * (no `peer-joined` event; identity stays in
	 * `doc.entities.peers`). `onSetPeerStart` re-anchors a start
	 * time, reading identity from the entities map. */
	onSetPeerStart: (peerId: string, t: number) => void;
	onClearPeerStart: (peerId: string) => void;
	/** Storage-shaped session duration edit. `onClearSessionEnd`
	 *  removes the `session-closed` event (eternal-session). */
	onSetSessionDuration: (sessionId: string, duration: number) => void;
	onClearSessionEnd: (sessionId: string) => void;
	/** Session-trajectory edits, addressed by property the way the peer
	 *  pair below is: a session's lifecycle and each of its two ends
	 *  change over time, and each moment is one property taking a value
	 *  at one `t`. The property set lives in `engine/trajectory.ts`, so
	 *  a fourth session property needs nothing here.
	 *
	 *  Row 0 is the value the session is BORN with, and it is not a
	 *  moment: `onSetSessionInitialState` edits the genesis state, and
	 *  `onUpdateSessionEndpoint` the genesis end — including detaching
	 *  it, which no moment can say. */
	onSetSessionKeyframe: (
		sessionId: string,
		property: SessionProperty,
		t: number,
		/** What the property takes at `t`, in its own value channel — one
		 *  word, or the pair an end attaches by. */
		value: SessionValue,
	) => void;
	onRemoveSessionKeyframe: (
		sessionId: string,
		property: SessionProperty,
		t: number,
	) => void;
	onSetSessionInitialState: (sessionId: string, state: SessionState) => void;
	onUpdateSessionEndpoint: (
		sessionId: string,
		side: SessionSide,
		patch: {
			/** The peer this end attaches to; `null` detaches it and the
			 *  end goes loose. */
			peer?: string | null;
			/** What the end claims to be; `null` drops the claim. */
			designator?: string | null;
			/** What backed the claim; `null` means nothing did. */
			attributedBy?: EndpointAttribution | null;
		},
	) => void;
	/** Peer-trajectory edits, the peer sibling of the state
	 *  trajectory. What a peer ARRIVES with is `onUpdatePeer` — a
	 *  session's genesis state in peer form; each later moment states
	 *  one property at its own `t`, addressed here the way state
	 *  keyframes are addressed above. The property set lives in
	 *  `engine/trajectory.ts`, so a second temporal peer property
	 *  needs nothing here. */
	onSetPeerUpdate: (
		peerId: string,
		t: number,
		property: PeerProperty,
		value: string,
	) => void;
	onRemovePeerUpdate: (
		peerId: string,
		t: number,
		property: PeerProperty,
	) => void;
	/** Session start / message start counterparts of the peer
	 *  start pair. Clearing a session start makes its effective
	 *  start cascade to `max(peerA.effectiveStart,
	 *  peerB.effectiveStart)`; clearing a message start cascades
	 *  to its session's effective start. */
	onSetSessionStart: (sessionId: string, t: number) => void;
	onClearSessionStart: (sessionId: string) => void;
	onSetMessageStart: (messageId: string, t: number) => void;
	onClearMessageStart: (messageId: string) => void;
	/** Storage-shaped message flight duration edit. */
	onSetMessageDuration: (messageId: string, duration: number) => void;
	beginEdit: (label: string) => void;
	endEdit: () => void;
	onDelete: (selection: StageSelection) => void;
	/** Pre-flight collision check for the Inspector ID cell. Pure
	 *  read; no state change. Inspector calls this on blur before
	 *  dispatching `onRename` so the user sees the collision message
	 *  inline rather than via the global error bus. */
	validateRename: (
		kind: "peer" | "session" | "message",
		oldId: string,
		newId: string,
	) => EngineResult<void>;
	/** Commit a rename. Cascades the new id through every reference
	 *  site (entities map, cross-category endpoints, events,
	 *  rowOrder / rowHidden lists) in one engine transaction —
	 *  one undo step. Returns the result so the Inspector can show
	 *  a collision message inline on the (rare) race where validate
	 *  passed but dispatch racing rejected. App-side handler also
	 *  re-anchors the selection at the new id so the Inspector
	 *  keeps tracking the entity post-rename. */
	onRename: (
		kind: "peer" | "session" | "message",
		oldId: string,
		newId: string,
	) => EngineResult<void>;
};
