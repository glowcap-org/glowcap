/**
 * Playback and builder intents the engine accepts.
 *
 * `EngineIntent` is drained at the start of each `tick()`.
 * `BuilderIntent` is the single mutation vocabulary for the builder UI:
 * the caller declares intent, `engine.dispatch` mints ids and stamps `t`.
 * Labels (`intent-labels.ts`) and no-op detection (`no-op-guards.ts`)
 * consume this module. They must not import the engine class to do it.
 */

import type { CaptpVersion, Codec, PeerProfile, SessionState, Transport } from "../schema/topology.ts";
import type { EndpointAttribution, SessionEndpoint, SessionSide } from "../schema/session-end.ts";
import type { MoveIntent, MoveSpanIntent } from "./authoring/moves.ts";
import type { PeerProperty, SessionProperty, SessionValue } from "./trajectory.ts";

export type EngineIntent =
	| { kind: "play" }
	| { kind: "pause" }
	| { kind: "toggle" }
	| { kind: "restart" }
	| { kind: "setSpeed"; speed: number }
	| { kind: "seekTo"; t: number }
	| { kind: "beginScrub" }
	| { kind: "endScrub" };

/**
 * Builder-level mutation intents. Routed through `engine.dispatch`,
 * the single mutation surface for the builder UI. Logging,
 * undo / redo, and any future "pipe to an external director" hook
 * one site. Intents are domain-shaped, not event-shaped (the
 * caller declares intent, `dispatch` mints ids + stamps `t`).
 */
export type BuilderIntent =
	| {
		kind: "add-peer";
		profile: PeerProfile;
		label?: string;
		position: { x: number; y: number };
		/** Optional user-supplied id. When provided and not colliding,
		 *  used verbatim. The auto-mint counter stays untouched. On
		 *  collision, the dispatch emits a `collision` engine error
		 *  and the doc rolls back via the snapshot/rollback path. */
		id?: string;
	}
	| {
		kind: "reposition-peer";
		peerId: string;
		position: { x: number; y: number };
	}
	| {
		/** Unpin: remove the authored position so the force layout
		 * places the peer again. The inverse of `reposition-peer`'s
		 * pin. */
		kind: "clear-peer-position";
		peerId: string;
	}
	| {
		/** Pin a session end nothing has attributed. `endpointId` is the
		 * `sessionId::side` stage id the end is drawn under. The position
		 * lands on the session that owns the end. */
		kind: "reposition-endpoint";
		endpointId: string;
		position: { x: number; y: number };
	}
	| {
		/** Unpin an end. The inverse of `reposition-endpoint`. */
		kind: "clear-endpoint-position";
		endpointId: string;
	}
	| {
		kind: "update-peer";
		peerId: string;
		patch: {
			label?: string;
			profile?: PeerProfile;
			designator?: string;
		};
	}
	| {
		/** Draw a session between two ends.
		 *
		 *  Each end is a `SessionEndpoint`, not a peer id, so every shape
		 *  a recording can hold is drawable: an end attached to a peer
		 *  (`attachedEndpoint("alice")`), and an end nothing has
		 *  attributed, carrying at most the name it claims
		 *  (`{ designator: "127.0.0.1:9000" }`). An authored end may name
		 *  a peer without saying what attributed it, in Build mode the
		 *  author is the authority, and there is no measurement to
		 *  report. */
		kind: "open-session";
		a: SessionEndpoint;
		b: SessionEndpoint;
		codec?: Codec;
		captpVersion?: CaptpVersion;
		initialState?: SessionState;
	}
	| {
		kind: "send-message";
		sessionId: string;
		from: string;
		to: string;
		label?: string;
		/** Milliseconds from current `clock.t` to delivery. Defaults
		 * to `DEFAULT_MESSAGE_FLIGHT_MS`. */
		flightMs?: number;
	}
	| { kind: "delete-peer"; peerId: string }
	| { kind: "delete-session"; sessionId: string }
	| { kind: "delete-message"; messageId: string }
	| {
		kind: "update-session";
		sessionId: string;
		patch: {
			codec?: Codec;
			captpVersion?: CaptpVersion;
			/** The netlayer the session runs over. `null` stops stating one,
			 * which is a state the document holds and not a missing value,
			 * a producer that reported no transport recorded exactly that. */
			transport?: Transport | null;
			/** A non-undefined value inserts a `session-state-changed`
			 * event at `clock.t`. Mutating `initialState` is its own
			 * thing, use that path if you need to edit the genesis.
			 *
			 * This IS `set-session-keyframe { property: "state" }` with
			 * the playhead for its `t`: one write, reached by a second
			 * name, sharing the write itself (`authoring/session.ts`) and
			 * the question of whether it changes anything
			 * (`no-op-guards.ts`). Prefer the keyframe intent, which says
			 * at which moment it means. */
			state?: SessionState;
		};
	}
	| {
		kind: "update-message";
		messageId: string;
		patch: {
			label?: string;
			/** Reassign the message to a different session. The target
			 * session's endpoints must match the message's
			 * `{from, to}` (in either order). The engine rejects the
			 * patch otherwise via the engine error channel. */
			sessionId?: string;
			/** When true, swap `from` and `to`. Only valid when the
			 * session's endpoints contain both peers (always true for
			 * existing messages on their existing session). */
			swapDirection?: true;
		};
	}
	| {
		/** Retime a peer or session span by naming the entity rather
		 * than an observation event (`MoveSpanIntent`). This is the
		 * timeline drag's write path for spans: it works identically
		 * for a loaded entity (whose observation events move to agree)
		 * and a freshly authored one (which has `entity.timing` and no
		 * events yet). Messages keep the event-shaped `move-event` status-allow: pending state or quoted runtime label
		 * below, since a message always has its sent observation. */
		kind: "move-entity-span";
		move: MoveSpanIntent;
	}
	| {
		/** Retime an event without changing its shape. Foundation for
		 * timeline-drag editing. The `move` payload is a tagged-union
		 * `MoveIntent` so each gesture (`translate` / `resize-start` /
		 * `resize-end`) declares exactly the inputs it needs, no
		 * booleans that flip the meaning of `newT` from "body anchor"
		 * to "left edge", no optional `arrivalT` whose presence implies
		 * a different write path.
		 *
		 * Validates against ordering constraints (peer-left after
		 * peer-joined, session-state-changed after session-opened,
		 * message-delivered after message-sent, etc.) and rejects
		 * invalid moves via the engine error channel. Auto-extends
		 * `doc.duration` if the new time(s) exceed the current end. */
		kind: "move-event";
		move: MoveIntent;
	}
	| {
		/** Opt-in end time for a peer, pins `timing.duration` so the
		 * peer's painted end lands at `t` (duration measured off the
		 * effective start). Use `clear-peer-end` to remove. Validated
		 * against ordering: `t` must be at or after the peer's painted
		 * start. Sessions whose containment requires the peer alive
		 * past `t` will clamp on the session-side, not here. */
		kind: "set-peer-end";
		peerId: string;
		t: number;
	}
	| {
		/** Storage-shaped counterpart to `set-peer-end`. Sets
		 *  `entity.timing.duration` directly to `duration` (must be
		 *  >= 0). Equivalent to `set-peer-end` at
		 *  `peerEffective(doc, peerId).start + duration` but
		 *  without the start lookup. Inspector dispatches this from
		 *  the duration row, `set-peer-end` stays for absolute-time
		 *  drag gestures. */
		kind: "set-peer-duration";
		peerId: string;
		duration: number;
	}
	| { kind: "clear-peer-end"; peerId: string }
	| {
		/** Convert a peer into an eternal-start peer: flips
		 *  `timing.start` implicit so it inherits the world's 0.
		 *  Identity stays in `doc.entities.peers[peerId]`, so the
		 *  world materializer keeps the peer alive from t=0,
		 *  mirrors `clear-peer-end`'s eternal-end semantic. No-op
		 *  when the start is already implicit. */
		kind: "clear-peer-start";
		peerId: string;
	}
	| {
		/** Author / re-anchor a peer's arrival time: pins
		 *  `timing.start` explicit at `t` (the inverse of
		 *  `clear-peer-start`). Identity (profile, label, position,
		 *  designator) comes from
		 *  `doc.entities.peers[peerId]`. The peer must already
		 *  be defined there. */
		kind: "set-peer-start";
		peerId: string;
		t: number;
	}
	| {
		/** Opt-in end time for a session, pins `timing.duration` so
		 * the session's painted end lands at `t` (duration measured
		 * off the effective start). Use `clear-session-end` to remove.
		 * Validated against ordering: `t` must be at or after the
		 * session's painted start. Endpoint peers leaving earlier status-allow: event or source ordering
		 * clamp the painted end without rewriting the stored intent. */
		kind: "set-session-end";
		sessionId: string;
		t: number;
	}
	| {
		/** Storage-shaped counterpart to `set-session-end`. Sets
		 *  duration directly. The inspector duration row dispatches
		 *  this. */
		kind: "set-session-duration";
		sessionId: string;
		duration: number;
	}
	| { kind: "clear-session-end"; sessionId: string }
	| {
		/** State one of the session's temporal properties from `t`
		 *  onward: a lifecycle change, or one end attaching to a peer.
		 *  Addressed by property because a session has a trajectory per
		 *  property (`trajectory.ts`), which is the shape the peer lane's
		 *  `set-peer-update` already has. Distinct from
		 *  `update-session { state }`, which keys off `clock.t`. */
		kind: "set-session-keyframe";
		sessionId: string;
		property: SessionProperty;
		t: number;
		/** What the property takes at `t`, in its own value channel: a
		 *  lifecycle word, or the pair an end attaches by. A picker offering
		 *  one word may hand over the word (`SessionValue` admits both), and
		 *  the property's `parse` is the one door either way. */
		value: SessionValue;
	}
	| {
		/** Stop stating one property at exactly `t`. No-op when it stated
		 *  nothing. Row 0 (the value the session is born with) is not a
		 *  moment, `set-session-initial-state` and
		 *  `update-session-endpoint` edit that. */
		kind: "remove-session-keyframe";
		sessionId: string;
		property: SessionProperty;
		t: number;
	}
	| {
		/** Edit row 0 of the state trajectory. The session's genesis
		 *  `initialState`. */
		kind: "set-session-initial-state";
		sessionId: string;
		state: SessionState;
	}
	| {
		/** Edit one end of a session as it is born: what it claims to be,
		 *  the peer it attaches to, and what attributed it. `null` clears
		 *  a field, so detaching an end is `{ peer: null }` and the end
		 *  goes loose. Row 0 of that end's trajectory. A later attachment
		 *  is a moment, through `set-session-keyframe`. */
		kind: "update-session-endpoint";
		sessionId: string;
		side: SessionSide;
		patch: {
			peer?: string | null;
			designator?: string | null;
			attributedBy?: EndpointAttribution | null;
		};
	}
	| {
		/** State one of the peer's temporal properties from `t` onward.
		 *  The peer sibling of `set-session-keyframe`, addressed by
		 *  property because a peer has a trajectory per property
		 *  (`trajectory.ts`). The value it JOINED with is
		 *  `update-peer`, the way a session's genesis state is
		 *  `set-session-initial-state`. */
		kind: "set-peer-update";
		peerId: string;
		t: number;
		property: PeerProperty;
		value: string;
	}
	| {
		/** Stop stating one property at exactly `t`. No-op when it
		 *  stated nothing. The value the peer arrived with is not a
		 *  moment. Edit it with `update-peer`. */
		kind: "remove-peer-update";
		peerId: string;
		t: number;
		property: PeerProperty;
	}
	| {
		/** Session counterparts to `set-peer-start` / `clear-peer-
		 *  start`. Implicit (cleared) start cascades to
		 *  `max(peerA.effectiveStart, peerB.effectiveStart)`, the
		 *  session "appears" when both endpoints exist. Explicit
		 *  start must respect that lower bound. */
		kind: "set-session-start";
		sessionId: string;
		t: number;
	}
	| { kind: "clear-session-start"; sessionId: string }
	| {
		/** Message counterparts. Implicit (cleared) start
		 *  cascades to `session.effectiveStart`. Explicit start
		 *  must lie within `[session.effectiveStart,
		 *  session.effectiveEnd]`. */
		kind: "set-message-start";
		messageId: string;
		t: number;
	}
	| { kind: "clear-message-start"; messageId: string }
	| {
		/** Set the message's arrival time. Mutates entity.timing.duration
		 *  so the message lands at `t`. Validated against the message's
		 *  own start and the carrying session's effective end. */
		kind: "set-message-end";
		messageId: string;
		t: number;
	}
	| {
		/** Storage-shaped counterpart to `set-message-end`. Sets
		 *  flight duration directly. The inspector duration row
		 *  dispatches this. */
		kind: "set-message-duration";
		messageId: string;
		duration: number;
	}
	| {
		/** Set the per-category row
		 * order on `TimelineDocument.rowOrder`. Listed entity ids
		 * render first in the given order. Entities not listed fall
		 * after by the renderer's default sort (first-event-t).
		 * Empty `order` clears the override for that category. */
		kind: "reorder-row";
		category: "peers" | "sessions" | "messages";
		order: string[];
	}
	| {
		/** Set an entity's per-row stage-visibility mode. Four states:
		 *
		 *   visible:  body + label both on stage (default)
		 *   label:    body on stage, label hidden
		 *   body:     body hidden, label still on stage
		 *   both:     body + label both hidden
		 *
		 * Three doc fields back this: `rowHidden` (both), `rowLabelHidden`
		 * (label), `rowBodyHidden` (body). An id is in at most one
		 * array at a time. The mutator clears it from the other two
		 * when transitioning. Parallels the category-level
		 * `StageVisibility` toggles in the Layers panel, same Adobe
		 * / Macromedia idiom, with the extra label vs body axis
		 * stage entities can carry. */
		kind: "set-row-vis-mode";
		category: "peers" | "sessions" | "messages";
		id: string;
		mode: "visible" | "label" | "body" | "both";
	}
	| {
		/** Set every entity in the category to a single visibility
		 * mode. Overrides any per-entity state for the category
		 * (lossy, the user explicitly opts into this
		 * convenience: "set all peers to this mode right now"
		 * trumps the per-entity preferences). All four modes are
		 * exposed so the category gutter eyeball can cycle through
		 * the same vocabulary as the per-row one. */
		kind: "set-category-vis-mode";
		category: "peers" | "sessions" | "messages";
		mode: "visible" | "label" | "body" | "both";
	}
	| {
		/** Set every entity across ALL THREE categories to a single
		 * visibility mode. Same opt-in / lossy semantics as
		 * `set-category-vis-mode`, used by the "all rows" master
		 * toggle in the Timeline control row. */
		kind: "set-all-vis-mode";
		mode: "visible" | "label" | "body" | "both";
	}
	| {
		/** Re-key a peer. Rewrites every reference site in the doc
		 *  (entities map, session endpoints, message endpoints, row
		 *  ordering / visibility, all matching events). Rejects on
		 *  collision (IDE-style: the user's gesture is blocked and an
		 *  error surfaces via `engine.validate` or the error channel). */
		kind: "rename-peer";
		oldId: string;
		newId: string;
	}
	| {
		/** Re-key a session. Rewrites entity-map, message references,
		 *  row state, and matching events. Collision-rejecting. */
		kind: "rename-session";
		oldId: string;
		newId: string;
	}
	| {
		/** Re-key a message. Rewrites entity-map, message-sent /
		 *  message-delivered events, row state. Collision-rejecting. */
		kind: "rename-message";
		oldId: string;
		newId: string;
	};

/** Default ms a builder-authored message spends in flight when the
 * caller doesn't specify. Chosen so the message-in-flight marker
 * is visible long enough to read at normal playback speed. */
export const DEFAULT_MESSAGE_FLIGHT_MS = 500;
