import { nodeKindOf, parseEndpointStageId } from "../schema/topology.ts";
import { Clock } from "./clock.ts";
import {
  createWorld,
  type GameWorld,
  type MessageEntity,
  type PeerEntity,
  type Queries,
  queries,
  type SessionEntity,
} from "./world.ts";
import type {
  LayoutMode,
  MessageDefinition,
  PeerDefinition,
  SessionDefinition,
  TimelineDocument,
  TimelineEvent,
} from "./timeline.ts";
import type {
  CaptpVersion,
  Codec,
  EndpointAttribution,
  PeerProfile,
  SessionEndpoint,
  SessionSide,
  SessionState,
  Transport,
} from "../schema/topology.ts";
import { explicitBound, implicitBound } from "./temporal/bound.ts";
import type { TimeSpan } from "./temporal/time-span.ts";
import { materializeWorldAt } from "./systems/world-materializer.ts";
import {
  DEFAULT_LAYOUT_CONFIG,
  KeyframeLayoutSystem,
} from "./systems/keyframe-layout-system.ts";
import { MessageFlightSystem } from "./systems/animation-system.ts";
import { type DocSnapshot, History, snapshotsEqual } from "./history.ts";
import {
  collisionError,
  type EngineError,
  type EngineResult,
  err,
  internalError,
  notFoundError,
  ok,
  validationError,
} from "./errors.ts";
import {
  allVisModeOnDoc,
  categoryVisModeOnDoc,
  effectiveRowVisMode as effectiveRowVisModeOnDoc,
  rowVisModeOnDoc,
  setAllVisModeOnDoc,
  setCategoryVisModeOnDoc,
  setRowVisModeOnDoc,
} from "./visibility.ts";
import { intentLabel } from "./intent-labels.ts";
import { isNoOpIntent } from "./no-op-guards.ts";
import {
  defineMessage,
  definePeer,
  defineSession,
  patchPeerDefinition,
} from "./entities.ts";
import {
  clampReasonFor,
  effectiveOfEntity,
  intrinsicOfEntity,
} from "./temporal/doc-resolver.ts";
import { projectFromObservations } from "./temporal/project-from-observations.ts";
import type {
  PeerProperty,
  SessionProperty,
  SessionValue,
} from "./trajectory.ts";
import {
  resetDocumentTo,
  restoreSnapshotInto,
  takeSnapshot,
} from "./snapshot.ts";
import { checkRekeyCollision, rekeyEntity } from "./authoring/identity.ts";
import type { AuthoringContext } from "./authoring/context.ts";
import {
  applyAuthored as applyAuthoredOnCtx,
  commitEntityAuthoring,
  latestStatedTime,
  moveEntitySpan,
  moveEvent as moveEventOnCtx,
  type MoveIntent,
  type MoveSpanIntent,
} from "./authoring/events.ts";
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
import { orderByRowOrder } from "./event-helpers.ts";
import { observationsOf } from "./temporal/recording-access.ts";
import { cascadePaste, type IdRemap } from "./schema/paste.ts";
import { type ClipboardPayload } from "./schema/clipboard.ts";
import { extractClipboardPayload, type Selection } from "./schema/extract.ts";

export type EngineOptions = {
  /** Override the document's layout mode. */
  layoutMode?: LayoutMode;
};

/** User intents the engine drains at the start of each `tick()`. */
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
 * Builder-level mutation intents. Routed through `engine.dispatch`
 * — the single mutation surface for the builder UI. Logging,
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
     *  used verbatim; the auto-mint counter stays untouched. On
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
     * `sessionId::side` stage id the end is drawn under; the position
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
     *  a peer without saying what attributed it — in Build mode the
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
       * which is a state the document holds and not a missing value —
       * a producer that reported no transport recorded exactly that. */
      transport?: Transport | null;
      /** A non-undefined value inserts a `session-state-changed`
       * event at `clock.t`. Mutating `initialState` is its own
       * thing — use that path if you need to edit the genesis.
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
       * `{from, to}` (in either order); the engine rejects the
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
     * events yet). Messages keep the event-shaped `move-event`
     * below, since a message always has its sent observation. */
    kind: "move-entity-span";
    move: MoveSpanIntent;
  }
  | {
    /** Retime an event without changing its shape. Foundation for
     * timeline-drag editing. The `move` payload is a tagged-union
     * `MoveIntent` so each gesture (`translate` / `resize-start` /
     * `resize-end`) declares exactly the inputs it needs — no
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
    /** Opt-in end time for a peer — pins `timing.duration` so the
     * peer's painted end lands at `t` (duration measured off the
     * effective start). Use `clear-peer-end` to remove. Validated
     * against ordering: `t` must be at or after the peer's painted
     * start; sessions whose containment requires the peer alive
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
     *  the duration row; `set-peer-end` stays for absolute-time
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
     *  world materializer keeps the peer alive from t=0 —
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
     *  `doc.entities.peers[peerId]` — the peer must already
     *  be defined there. */
    kind: "set-peer-start";
    peerId: string;
    t: number;
  }
  | {
    /** Opt-in end time for a session — pins `timing.duration` so
     * the session's painted end lands at `t` (duration measured
     * off the effective start). Use `clear-session-end` to remove.
     * Validated against ordering: `t` must be at or after the
     * session's painted start; endpoint peers leaving earlier
     * clamp the painted end without rewriting the stored intent. */
    kind: "set-session-end";
    sessionId: string;
    t: number;
  }
  | {
    /** Storage-shaped counterpart to `set-session-end`. Sets
     *  duration directly; the inspector duration row dispatches
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
     *  moment; `set-session-initial-state` and
     *  `update-session-endpoint` edit that. */
    kind: "remove-session-keyframe";
    sessionId: string;
    property: SessionProperty;
    t: number;
  }
  | {
    /** Edit row 0 of the state trajectory — the session's genesis
     *  `initialState`. */
    kind: "set-session-initial-state";
    sessionId: string;
    state: SessionState;
  }
  | {
    /** Edit one end of a session as it is born: what it claims to be,
     *  the peer it attaches to, and what attributed it. `null` clears
     *  a field, so detaching an end is `{ peer: null }` and the end
     *  goes loose. Row 0 of that end's trajectory; a later attachment
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
     *  (`trajectory.ts`); the value it JOINED with is
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
     *  moment; edit it with `update-peer`. */
    kind: "remove-peer-update";
    peerId: string;
    t: number;
    property: PeerProperty;
  }
  | {
    /** Session counterparts to `set-peer-start` / `clear-peer-
     *  start`. Implicit (cleared) start cascades to
     *  `max(peerA.effectiveStart, peerB.effectiveStart)` — the
     *  session "appears" when both endpoints exist. Explicit
     *  start must respect that lower bound. */
    kind: "set-session-start";
    sessionId: string;
    t: number;
  }
  | { kind: "clear-session-start"; sessionId: string }
  | {
    /** Message counterparts. Implicit (cleared) start
     *  cascades to `session.effectiveStart`; explicit start
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
     *  flight duration directly; the inspector duration row
     *  dispatches this. */
    kind: "set-message-duration";
    messageId: string;
    duration: number;
  }
  | {
    /** Flash-grade timeline (PR 1): set the per-category row
     * order on `TimelineDocument.rowOrder`. Listed entity ids
     * render first in the given order; entities not listed fall
     * after by the renderer's default sort (first-event-t).
     * Empty `order` clears the override for that category. */
    kind: "reorder-row";
    category: "peers" | "sessions" | "messages";
    order: string[];
  }
  | {
    /** Set an entity's per-row stage-visibility mode. Four states:
     *
     *   visible  — body + label both on stage (default)
     *   label    — body on stage, label hidden
     *   body     — body hidden, label still on stage
     *   both     — body + label both hidden
     *
     * Three doc fields back this: `rowHidden` (both), `rowLabelHidden`
     * (label), `rowBodyHidden` (body). An id is in at most one
     * array at a time; the mutator clears it from the other two
     * when transitioning. Parallels the category-level
     * `StageVisibility` toggles in the Layers panel — same Adobe
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
     * (lossy by design — the user explicitly opts into this
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
     * `set-category-vis-mode` — used by the "all rows" master
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

/** Defaults for an `open-session` intent that didn't pin them. */
/** An opening view as a document stores it: three numbers, or nothing said. */
type StoredView =
  | { zoom: number; center: { x: number; y: number } }
  | undefined;

/** Whether two documents name the same opening view, absence included. Absence is
 *  a distinct answer rather than a stand-in for the default, because the caller
 *  passes `undefined` for a camera sitting at the default
 *  (`Engine.setOpeningView`), so a document that says nothing and one that says
 *  1:1 centered cannot both occur. */
function sameStoredView(a: StoredView, b: StoredView): boolean {
  if (a === undefined || b === undefined) return a === b;
  return a.zoom === b.zoom && a.center.x === b.center.x &&
    a.center.y === b.center.y;
}

const DEFAULT_SESSION_CODEC: Codec = "capnp";
const DEFAULT_SESSION_CAPTP: CaptpVersion = "v1_0";
const DEFAULT_SESSION_STATE: SessionState = "open";

/**
 * Engine — the single main loop. Each `tick(wallDt)`:
 *   1. drains intents,
 *   2. advances the clock,
 *   3. folds events into the world,
 *   4. recomputes positions,
 *   5. notifies subscribers (only when something changed).
 *
 * Tests may call `restart` / `seekTo` imperatively; the app routes
 * through intents.
 *
 * **Doc ownership.** The engine takes ownership of the
 * `TimelineDocument` passed to its constructor and treats its
 * `events` array as mutable internal state — Zod's `readonly` is
 * a caller-side contract. Callers must not continue mutating the
 * doc after handing it off; clone first if a separate copy is
 * needed.
 */
export class Engine {
  doc: TimelineDocument;
  readonly clock: Clock;
  readonly world: GameWorld;
  readonly queries: Queries;
  readonly layout: KeyframeLayoutSystem;
  readonly messages: MessageFlightSystem;

  #prevT = 0;
  // Last `t` for which layout / messages systems ran. Lets
  // `tick()` skip per-frame interpolation when nothing moved
  // (paused, no seek). NaN sentinel so the first tick always runs.
  #lastUpdateT = Number.NaN;
  #intents: EngineIntent[] = [];
  #listeners = new Set<() => void>();
  #errorListeners = new Set<(err: EngineError) => void>();
  #scrubbing = false;
  #resumeAfterScrub = false;
  // Monotonic counter bumped in `#notify`. Read by
  // `useEngineVersion` via `useSyncExternalStore` to decide
  // whether to re-render.
  #version = 0;
  #docVersion = 0;
  // Per-engine authored-event id counter — two side-by-side
  // engines don't collide because each owns its own doc.
  #authoredCounter = 0;
  #history = new History();
  // Transaction nesting + the snapshot/label captured at depth=1.
  // Mutations within a transaction coalesce into ONE history entry
  // (e.g. every keystroke between focus and blur).
  #txnDepth = 0;
  #txnSnapshot: DocSnapshot | null = null;
  #txnLabel = "";
  /** Layout must recompute when the transaction closes (pin clears,
   *  deletes, other topology edits). Coalesces N cold anneals into one. */
  #txnLayoutDirty = false;
  /** Authoring seek deferred to transaction end; null when none pending. */
  #txnSeekT: number | null = null;
  // The document this engine was built from, deep-cloned at
  // construction so nothing that happens afterwards can reach it.
  // It is what `discardAllEdits` goes back to, and the reason it can
  // reach further than the history can. One extra document per engine,
  // at our sizes.
  #source!: TimelineDocument;

  /** Built once in the constructor. The document-authoring
   *  subsystem in `./authoring/` reads only what's on this context,
   *  not the whole Engine. */
  #ctx!: AuthoringContext;

  constructor(doc: TimelineDocument, opts: EngineOptions = {}) {
    // Project observations → entity.timing for any entity that
    // doesn't yet carry one. Newly-authored entities already
    // populate timing at creation; this catches loaded / imported
    // docs so every reader can rely on entity.timing being
    // present. Idempotent — no-op on fully-projected docs.
    this.doc = projectFromObservations(doc);
    this.clock = new Clock(this.doc.duration);
    this.world = createWorld();
    this.queries = queries(this.world);
    // `orderedPeers / orderedSessions / orderedMessages` below
    // are the canonical iteration order for renderers (and any
    // other consumer that cares about z/row order). Raw
    // `queries.*` stays available for engine internals + presence
    // checks where order is immaterial.
    // Precedence: opts override > doc default > DEFAULT_LAYOUT_CONFIG.
    const mode = opts.layoutMode ?? this.doc.layoutMode ??
      DEFAULT_LAYOUT_CONFIG.mode;
    // Bind the layout to `this.doc` — the projection above may have
    // returned a fresh object, and the layout must read the doc the
    // engine mutates, not the constructor argument.
    this.layout = new KeyframeLayoutSystem(this.doc, {
      ...DEFAULT_LAYOUT_CONFIG,
      mode,
    });
    this.messages = new MessageFlightSystem();
    // Authoring context — narrow surface the `./authoring/`
    // subsystem reads. Built once; `mintId` and `seekTo` close over
    // `this` so the counter survives across calls and the seek
    // routes through the Engine's cursor/world rebuild path.
    this.#ctx = {
      doc: this.doc,
      world: this.world,
      clock: this.clock,
      layout: this.layout,
      mintId: () => ++this.#authoredCounter,
      recomputeLayout: () => this.#requestLayoutRecompute(),
      seekTo: (t) => this.#authoringSeek(t),
      notify: () => this.#notify(),
      emitError: (err) => this.#emitError(err),
    };
    this.#applyInstantaneousEvents();
    // Taken last, so the baseline is the document as every reader
    // first sees it: after the constructor's projection, which fills
    // in `entity.timing` for a loaded document and is what an author
    // then edits away from.
    this.#source = structuredClone(this.doc);
  }

  /** Materialize the world at t=0 and run the layout pass. Used
   *  by construction and restart paths. */
  #applyInstantaneousEvents(): void {
    materializeWorldAt(this.world, this.doc, 0);
    this.layout.update(this.world, 0);
  }

  // Entity-definition mutation helpers (define, patch, remove)
  // live in `./entities.ts`. The private shims below keep the
  // internal callsites readable as `this.#definePeer(...)` while
  // delegating to the free functions. World materialization is
  // handled by `materializeWorldAt`; no separate "eternal-entities
  // injection" pass is needed — any entity whose effective range
  // contains t shows up in the world.
  #definePeer(peerId: string, def: PeerDefinition): void {
    definePeer(this.doc, peerId, def);
  }
  #patchPeerDefinition(
    peerId: string,
    patch: {
      label?: string;
      profile?: PeerProfile;
      designator?: string;
      position?: { x: number; y: number };
    },
  ): void {
    patchPeerDefinition(this.doc, peerId, patch);
  }
  #defineSession(sessionId: string, def: SessionDefinition): void {
    defineSession(this.doc, sessionId, def);
  }
  #defineMessage(messageId: string, def: MessageDefinition): void {
    defineMessage(this.doc, messageId, def);
  }

  /** Enqueue a user intent. Drained in FIFO order at the next `tick()`. */
  enqueue(intent: EngineIntent): void {
    this.#intents.push(intent);
  }

  /** Subscribe to post-tick notifications. */
  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  /**
   * Subscribe to engine errors. Fires for:
   *   - exceptions thrown during intent drain (`tick`),
   *   - exceptions thrown during `dispatch`,
   *   - subscriber listener exceptions caught by `#notify`,
   *   - explicit `#emitError` from validation paths in future commits.
   *
   * The UI mounts toast / modal surfaces over this channel. Errors are
   * delivered synchronously; listeners that throw are isolated so one
   * bad subscriber can't starve the rest.
   */
  onError(listener: (err: EngineError) => void): () => void {
    this.#errorListeners.add(listener);
    return () => {
      this.#errorListeners.delete(listener);
    };
  }

  #emitError(err: EngineError): void {
    for (const listener of this.#errorListeners) {
      try {
        listener(err);
      } catch (listenerErr) {
        console.error(
          "ocapnviz engine: error listener threw",
          listenerErr,
        );
      }
    }
  }

  /**
   * Pre-flight check for an intent. Returns `{ ok: true }` when the
   * intent is safe to enqueue/dispatch; returns `{ ok: false, error }`
   * when the caller should block the action and surface the error
   * inline (Inspector ID field, options bar) without ever mutating
   * engine state.
   *
   * Today's coverage:
   *   - `rename-*`: collision check (IDE-style — gesture is blocked
   *     for user-facing collisions, no auto-suffix).
   *
   * Future work fills in paste / duplicate validation.
   */
  validate(intent: BuilderIntent | EngineIntent): EngineResult<void> {
    if (
      intent.kind === "rename-peer" ||
      intent.kind === "rename-session" ||
      intent.kind === "rename-message"
    ) {
      if (intent.oldId === intent.newId) return ok(undefined);
      const category = intent.kind === "rename-peer"
        ? "peer"
        : intent.kind === "rename-session"
        ? "session"
        : "message";
      return checkRekeyCollision(this.doc, category, intent.newId);
    }
    // add-peer with a user-supplied id: pre-flight the collision so
    // the ToolOptionsBar can surface the error inline (via
    // `<FieldError>`) before the click that drops the peer.
    if (
      intent.kind === "add-peer" &&
      intent.id !== undefined && intent.id.length > 0
    ) {
      if (this.doc.entities?.peers?.[intent.id] !== undefined) {
        return err(collisionError("peer", intent.id));
      }
    }
    return ok(undefined);
  }

  /** Advance by `wallDt` ms. The only runtime mutator. Returns simDt. */
  tick(wallDt: number): number {
    // Notify only when something observable changed — paused frames
    // would otherwise wake every `useEngineVersion` subscriber 60Hz
    // for nothing.
    let dirty = this.#intents.length > 0;
    // Every authoring intent edits the document, so a non-empty queue counts as
    // a document change without anyone reading the intents to find out. The
    // default runs this way round on purpose: over-reporting costs a re-render
    // nobody needed, while under-reporting leaves a panel showing a document
    // that is no longer there.
    let docChanged = this.#intents.length > 0;
    for (const intent of this.#intents) {
      try {
        this.#applyIntent(intent);
      } catch (caught) {
        // Keep draining — one bad intent shouldn't strand the rest of
        // the queue. The error surfaces via `onError`; the UI decides
        // whether to toast or modal based on the code.
        this.#emitError(internalError(caught));
      }
    }
    this.#intents.length = 0;

    const simDt = this.clock.tick(wallDt);
    const tNow = this.clock.t;

    if (simDt > 0) {
      if (this.#drainEvents(this.#prevT, tNow)) docChanged = true;
      dirty = true;
    }
    // Skip layout / message updates when `t` hasn't advanced —
    // paused frames or repeated ticks at the same t would otherwise
    // reinterpolate every peer back to the same coords.
    if (tNow !== this.#lastUpdateT) {
      this.layout.update(this.world, tNow);
      this.messages.update(
        this.world,
        observationsOf(this.doc) as readonly TimelineEvent[],
        tNow,
        this.claims,
      );
      this.#lastUpdateT = tNow;
      dirty = true;
    }
    this.#prevT = tNow;

    // The world moving is not the document changing. A playing clock advances
    // positions and flights on every frame, and a panel showing what the
    // document says has nothing to redraw for any of it.
    if (dirty) this.#notify(docChanged);
    return simDt;
  }

  /** Monotonic counter bumped on every `#notify` — the "any engine
   * state changed?" signal `useEngineVersion` reads via
   * `useSyncExternalStore`. */
  /**
   * Monotonic counter bumped only when the DOCUMENT changed, which
   * `useDocVersion` reads. A panel showing what the document says — its source,
   * its title, whether an id is taken — subscribes here instead of to
   * {@link version}, and then a playing clock costs it nothing.
   *
   * It never moves without `version` moving too, so a consumer that wants
   * everything is still right to read `version` alone.
   */
  get docVersion(): number {
    return this.#docVersion;
  }

  get version(): number {
    return this.#version;
  }

  /**
   * The peer each claiming session end names (`engine/claims.ts`), for every
   * surface that has to agree about it: the layout places these ends, the
   * renderer draws them, and the message flight follows the wire they are on.
   *
   * Derived where the keyframes are, because it is the same fact about the
   * document and changes on the same edits, so a frame reads a map rather than
   * rebuilding one.
   */
  get claims(): ReadonlyMap<string, string> {
    return this.layout.claims;
  }

  /** Peers in their canonical draw order: explicit `doc.rowOrder`
   * overrides first (in the listed order), then any unlisted
   * entities by insertion. Renderers / inspectors iterate this
   * instead of `queries.peers` so the Stage z-order, Timeline
   * gutter row order, and Inspector connection lists all agree
   * automatically — no caller has to remember to call a sort
   * helper. New consumers get the ordering for free.
   *
   * Allocates one small array per call (per category per frame),
   * which is negligible at our cardinality and avoided entirely
   * when no `rowOrder` override is set (returns a shallow copy
   * of the query in that case). */
  orderedPeers(): readonly PeerEntity[] {
    return orderByRowOrder(
      [...this.queries.peers],
      (e) => e.peer.id,
      this.doc.rowOrder?.peers,
    );
  }

  orderedSessions(): readonly SessionEntity[] {
    return orderByRowOrder(
      [...this.queries.sessions],
      (e) => e.session.id,
      this.doc.rowOrder?.sessions,
    );
  }

  orderedMessages(): readonly MessageEntity[] {
    return orderByRowOrder(
      [...this.queries.messagesInFlight],
      (e) => e.messageInFlight.id,
      this.doc.rowOrder?.messages,
    );
  }

  /** Fire each subscriber; one bad listener can't starve the rest. */
  /**
   * Wake every subscriber, and say whether the document changed with it.
   *
   * `docChanged` defaults to true so that a caller which has not thought about
   * the question reports the conservative answer. Callers that pass false are
   * ones that can prove the document identity did not change for panel
   * purposes: `tick` when the clock alone advanced, and a placement write
   * inside an open transaction (the txn-end `#notify` records the edit).
   */
  #notify(docChanged = true): void {
    this.#version += 1;
    if (docChanged) this.#docVersion += 1;
    for (const listener of this.#listeners) {
      try {
        listener();
      } catch (caught) {
        console.error("ocapnviz engine: subscriber threw", caught);
        this.#emitError(internalError(caught));
      }
    }
  }

  #applyIntent(intent: EngineIntent): void {
    switch (intent.kind) {
      case "play":
        this.#playOrRestart();
        return;
      case "pause":
        this.clock.pause();
        return;
      case "toggle":
        if (this.clock.state === "playing") this.clock.pause();
        else this.#playOrRestart();
        return;
      case "restart":
        this.#doRestart();
        return;
      case "setSpeed":
        this.clock.setSpeed(intent.speed);
        return;
      case "seekTo":
        this.#doSeek(intent.t);
        return;
      case "beginScrub":
        if (this.#scrubbing) return;
        this.#scrubbing = true;
        this.#resumeAfterScrub = this.clock.state === "playing";
        this.clock.pause();
        return;
      case "endScrub":
        if (!this.#scrubbing) return;
        this.#scrubbing = false;
        if (this.#resumeAfterScrub) this.clock.play();
        this.#resumeAfterScrub = false;
        return;
    }
  }

  /** Fold the document forward to `toT`, and report whether the document
   *  itself changed on the way — which in playback is never, and in live mode
   *  is whenever an observation arrived. */
  #drainEvents(fromT: number, toT: number): boolean {
    // Reconciler-based replay: rather than walking events from
    // fromT..toT, project any new observations into the behavior
    // layer (so live-mode pushes to the recording get reflected in
    // entity.timing/keyframes), then materialize the world to
    // `toT`. One code path for build / live / playback.
    void fromT;
    // A recompute is warranted by the DOCUMENT changing, because that is the
    // whole of what the keyframes are derived from: `recompute` reads the doc
    // and the config and nothing else, and `KeyframeLayoutSystem.claims` says
    // so where it is declared. Projection is what knows — it returns a fresh
    // doc when it touched something and the original when it did not.
    //
    // Which topology the world holds AT `toT` is a different fact, and it was
    // the wrong one to ask. It shifts on any ordinary playback frame where a
    // peer or a session comes into view, with the document behind it
    // untouched, so a document whose sessions arrive steadily re-derived every
    // era's layout on frame after frame and threw the identical keyframes
    // away. That is one d3-force convergence per era per arrival, and it is
    // why playing a hand-built document cost far more than drawing it.
    const docChanged = this.#reproject();
    materializeWorldAt(this.world, this.doc, toT);
    if (docChanged) this.layout.recompute();
    return docChanged;
  }

  /** Re-derive the behavior layer from the observations. Idempotent
   *  on already-projected entities, and authored values outrank it,
   *  so it is safe to run before anything reads the doc. Both paths
   *  that rebuild the world call it: the playing tick, where live
   *  observations arrive, and every seek, because an authoring
   *  gesture that moved observations must not wait for the clock to
   *  advance before the doc agrees with them.
   *
   *  Returns whether the document changed, which is the signal a caller needs
   *  to decide whether anything derived from the document is now stale. A
   *  quiet run over an unchanged observation set returns the same doc object
   *  and so reports false. */
  #reproject(): boolean {
    this.doc = projectFromObservations(this.doc);
    if (this.#ctx.doc === this.doc) return false;
    // Authoring context and layout both hold a doc reference;
    // keep them in sync. (projectFromObservations returns a new
    // doc only when it touches something — otherwise the
    // original.)
    this.#ctx = { ...this.#ctx, doc: this.doc };
    this.layout.rebind(this.doc);
    return true;
  }

  /** Imperative reset to t=0. Notifies subscribers. Tests / embedders only. */
  restart(): void {
    this.#doRestart();
    this.#notify();
  }

  // ──────────────── Builder transactions + undo / redo ────────────────

  /** Open a transaction — mutations dispatched while one is open
   * coalesce into ONE history entry (peer drag, typing burst).
   * `label` is the undo-tooltip name; nested begins use the
   * outermost label. */
  beginTransaction(label = "Edit"): void {
    if (this.#txnDepth === 0) {
      this.#txnSnapshot = this.#takeSnapshot();
      this.#txnLabel = label;
      this.#clearTxnStage();
    }
    this.#txnDepth += 1;
  }

  endTransaction(): void {
    if (this.#txnDepth === 0) return;
    this.#txnDepth -= 1;
    if (this.#txnDepth === 0 && this.#txnSnapshot) {
      // One layout solve and one world rebuild for the whole gesture —
      // Unpin all and multi-delete used to pay these per member.
      this.#flushTxnStage();
      // Skip the push when the transaction was a no-op (focused but
      // didn't type, dragged but returned to start position).
      const after = this.#takeSnapshot();
      if (!snapshotsEqual(this.#txnSnapshot, after)) {
        this.#history.recordBefore(this.#txnSnapshot, this.#txnLabel);
        this.#notify();
      }
      this.#txnSnapshot = null;
      this.#txnLabel = "";
      this.#clearTxnStage();
    }
  }

  /** Recompute layout, deferred while a transaction is open. */
  #requestLayoutRecompute(): void {
    if (this.#txnDepth > 0) {
      this.#txnLayoutDirty = true;
      return;
    }
    this.layout.recompute();
  }

  /**
   * Authoring seek: rebuild the world at `t`. Inside a transaction the
   * seek (and a layout recompute, because deletes otherwise leave
   * stale keyframes) waits for `endTransaction`.
   */
  #authoringSeek(t: number): void {
    if (this.#txnDepth > 0) {
      this.#txnSeekT = t;
      this.#txnLayoutDirty = true;
      return;
    }
    this.#doSeek(t);
    this.#notify();
  }

  #flushTxnStage(): void {
    if (this.#txnLayoutDirty) {
      this.layout.recompute();
      this.#txnLayoutDirty = false;
    }
    if (this.#txnSeekT !== null) {
      const t = this.#txnSeekT;
      this.#txnSeekT = null;
      this.#doSeek(t);
    }
  }

  #clearTxnStage(): void {
    this.#txnLayoutDirty = false;
    this.#txnSeekT = null;
  }

  /** Pop the previous snapshot and restore it. No-op when empty. */
  undo(): void {
    const previous = this.#history.undo(this.#takeSnapshot());
    if (previous) this.#applySnapshot(previous.snapshot);
  }

  /**
   * Pop the next snapshot off the redo stack and restore it.
   * No-op if there's nothing to redo. Notifies subscribers via
   * `seekTo`.
   */
  redo(): void {
    const next = this.#history.redo(this.#takeSnapshot());
    if (next) this.#applySnapshot(next.snapshot);
  }

  get canUndo(): boolean {
    return this.#history.canUndo;
  }
  get canRedo(): boolean {
    return this.#history.canRedo;
  }
  /**
   * Whether the history holds anything at all, in either direction.
   *
   * Distinct from `canUndo`, which asks whether there are steps LEFT
   * TO WALK BACK. They come apart at the bottom of the stack: a reader
   * who has undone their way to the start is at the beginning of a
   * history that still exists, with every step of it sitting on the
   * redo side. `undoAll` has nothing to do there and `discardAllEdits`
   * does — it is the one that throws the history away, and there is a
   * history to throw away.
   */
  get hasHistory(): boolean {
    return this.#history.canUndo || this.#history.canRedo;
  }
  /**
   * Name of the action `undo()` would reverse — drives the
   * "Undo {label}" tooltip. `undefined` when nothing to undo. */
  get nextUndoLabel(): string | undefined {
    return this.#history.nextUndoLabel;
  }
  /** Name of the action `redo()` would re-apply, or `undefined`. */
  get nextRedoLabel(): string | undefined {
    return this.#history.nextRedoLabel;
  }

  // Snapshot clone / restore lives in `./snapshot.ts`. The Engine
  // adds the post-restore orchestration (layout + seek) since that's
  // engine-internal — `snapshot.ts` is doc-pure.
  #takeSnapshot(): DocSnapshot {
    return takeSnapshot(this.doc);
  }

  #applySnapshot(snap: DocSnapshot): void {
    restoreSnapshotInto(this.doc, snap);
    this.#afterDocReplaced();
  }

  /**
   * Walk the whole history back in one move, keeping it.
   *
   * "Undo all": the same place pressing undo until it stops would
   * reach, and reversible in the same way — every step crosses to the
   * redo side, so the author can walk forward again. That is the whole
   * difference from `discardAllEdits` below, and it is why both exist.
   * Where it stops is what the HISTORY remembers, which is not always
   * the document the buffer was built from: the stack holds a hundred
   * entries, and each one restores the fields `DocSnapshot` carries
   * rather than the whole document.
   */
  undoAll(): void {
    const oldest = this.#history.undoAll(this.#takeSnapshot());
    if (oldest) this.#applySnapshot(oldest.snapshot);
  }

  /**
   * Throw away every edit: the document becomes the one this engine
   * was built from, and the history that got it here goes with it.
   *
   * The other half of the pair, and the strong one. It goes back to
   * the WHOLE document however long ago it arrived, so it reaches
   * past both of the limits `undoAll` runs into. The price is that it
   * cannot be taken back, which is why it is not a `BuilderIntent`:
   * an intent is an edit to the composition and every one of them is
   * a step you can undo, a rule `undo-coverage.test.ts` holds over
   * the whole union, one case per kind, refusing to compile when a
   * new kind arrives without one. This is not an edit. It is a reset
   * of the buffer, the same act as the buffer being built from a
   * different source, which throws the same work away and empties
   * Undo for the same reason: the steps in it lead back through a
   * document that is no longer the one in front of you.
   *
   * Offered on `hasHistory` rather than on `canUndo`, which is what
   * its neighbour `undoAll` reads. A reader sitting at the beginning
   * of the history has nothing left to undo and still has a history,
   * and this is the command that gets rid of one.
   */
  discardAllEdits(): void {
    if (!this.hasHistory) return;
    resetDocumentTo(this.doc, this.#source);
    this.#history.clear();
    this.#afterDocReplaced();
  }

  /** Bring the derived state back in step after the document has been
   *  written wholesale — by an undo, a redo, a rollback, or a
   *  discard.
   *
   *  The clock's upper bound follows `doc.duration` everywhere the doc
   *  grows (`growDurationToFit` / `commitEntityAuthoring`), so a write
   *  that shrinks it back must keep the pair in step or the transport
   *  plays past the timeline's end. The layout re-derives every era whose
   *  problem the replacement changed, keeping the arrangement it holds for the
   *  eras the replacement left alone: an era's problem is what the solver was
   *  asked, so an era the edit did not reach was asked the same question and has
   *  the same answer. The seek rebuilds the world at the playhead and notifies.
   */
  #afterDocReplaced(): void {
    this.clock.setDuration(this.doc.duration);
    this.layout.recompute();
    this.seekTo(this.clock.t);
  }

  // ────────────────────── Builder mutation API ────────────────────────

  /**
   * Imperative seek. Rebuilds the world from `[0, targetT]`, runs
   * layout, pins messages-in-flight to their progress at `targetT`.
   * Preserves clock state. Tests / embedders only.
   */
  seekTo(targetT: number): void {
    // A scrub during an open authoring transaction still needs a current
    // layout if pin/topology writes deferred a recompute.
    if (this.#txnLayoutDirty) {
      this.layout.recompute();
      this.#txnLayoutDirty = false;
    }
    this.#txnSeekT = null;
    this.#doSeek(targetT);
    this.#notify();
  }

  /** Append an event, preserving the sort-by-`t` invariant. Extends
   * `doc.duration` if the event lands past the end (Flash-style: the
   * timeline grows as you draw past it). Re-seeks so the change
   * folds in immediately even when paused. Tests stub this directly,
   * which is why the public surface stays even though the engine
   * routes through `ctx` everywhere else. */
  applyAuthored(event: TimelineEvent): void {
    applyAuthoredOnCtx(this.#ctx, event);
  }

  /** Move a peer in-place — rewrites the `position` on its
   * `peer-joined` event, which pins the peer in the force modes.
   * No-op if the peer id is unknown. Called continuously during
   * builder drags. The layout re-derives through the placement
   * rule (`recomputeForPlacement`): an era the edit did not
   * disturb — the pin sits where the era already had the peer —
   * keeps its layout verbatim, and a disturbed era re-derives
   * cold, so neighbors re-balance around a genuinely moved pin
   * with the canonical, history-free response a drag wants. */
  repositionPeer(peerId: string, position: { x: number; y: number }): void {
    this.#writePeerPosition(peerId, position);
    this.#afterPlacementEdit();
  }

  /**
   * Pin several peers and/or session ends in one placement pass.
   *
   * A multi-select drag used to call `repositionPeer` / `repositionEndpoint`
   * once per member per pointermove, each paying a full
   * `recomputeForPlacement` and a subscriber wake. One call writes every
   * pin, then recomputes and notifies once — same document result, one
   * layout solve.
   */
  repositionNodes(
    moves: ReadonlyArray<{
      kind: "peer" | "endpoint";
      id: string;
      position: { x: number; y: number };
    }>,
  ): void {
    if (moves.length === 0) return;
    for (const move of moves) {
      if (move.kind === "peer") {
        this.#writePeerPosition(move.id, move.position);
      } else {
        this.#writeEndpointPosition(move.id, move.position);
      }
    }
    this.#afterPlacementEdit();
  }

  #writePeerPosition(
    peerId: string,
    position: { x: number; y: number },
  ): void {
    // Identity-side write first (source of truth). Mirror to the
    // event payload for fixture / wire-format consistency. Both
    // paths must stay synced — readers prefer entities, but the
    // keyframe-layout system still reads event.position.
    this.#patchPeerDefinition(peerId, {
      position: { x: position.x, y: position.y },
    });
    for (const ev of observationsOf(this.doc) as TimelineEvent[]) {
      if (ev.kind === "peer-joined" && ev.peerId === peerId) {
        ev.position = { x: position.x, y: position.y };
        break;
      }
    }
  }

  #writeEndpointPosition(
    endpointId: string,
    position: { x: number; y: number },
  ): void {
    const at = parseEndpointStageId(endpointId);
    const def = at && this.doc.entities?.sessions?.[at.sessionId];
    if (!at || !def) return;
    def.endpointPosition = {
      ...def.endpointPosition,
      [at.side]: { x: position.x, y: position.y },
    };
  }

  /** Land a placement edit on the stage this frame and wake subscribers.
   *
   * Inside a transaction the document version stays quiet: the gesture's
   * `endTransaction` is the edit document-shaped panels care about, and
   * mid-drag wakes still reach world subscribers via `version`. */
  #afterPlacementEdit(): void {
    this.layout.recomputeForPlacement();
    this.#refreshStageAtPlayhead();
    this.#notify(this.#txnDepth === 0);
  }

  /**
   * Run the same layout + message systems `tick` would for this `t`, then
   * mark the playhead current so the next paused tick does not redo them.
   *
   * Both systems must run: message dots sit on curves derived from peer
   * positions, so a placement that only updated layout left in-flight
   * messages on the pre-drag wire until time advanced.
   */
  #refreshStageAtPlayhead(): void {
    const t = this.clock.t;
    this.layout.update(this.world, t);
    this.messages.update(
      this.world,
      observationsOf(this.doc) as readonly TimelineEvent[],
      t,
      this.claims,
    );
    this.#lastUpdateT = t;
  }

  /** Unpin a peer — remove its authored `position` from the
   * definition and the `peer-joined` event so the force modes own
   * its placement again. No-op if the peer was never pinned. A
   * removal goes through `recompute` rather than
   * `recomputeForPlacement`, because that rule is only sound for pins
   * being added or moved. Every era holding the unpinned peer is
   * re-derived, since a pin is part of what the solver was asked and
   * so part of the era's problem, and that is exactly what the round
   * trip needs: when the pin never moved, the
   * deterministic derivation reproduces the pre-pin layout bit for
   * bit, so unpinning in place moves nothing, while unpinning a
   * dragged-away pin visibly hands the peer back to the pack. */
  clearPeerPosition(peerId: string): void {
    const def = this.doc.entities?.peers?.[peerId];
    if (def) delete def.position;
    for (const ev of observationsOf(this.doc) as TimelineEvent[]) {
      if (ev.kind === "peer-joined" && ev.peerId === peerId) {
        delete ev.position;
        break;
      }
    }
    this.#requestLayoutRecompute();
    if (this.#txnDepth > 0) {
      this.#txnSeekT = this.clock.t;
      return;
    }
    this.#refreshStageAtPlayhead();
    this.#notify();
  }

  /** Move a session's unattributed end in place, pinning it for the
   * force modes exactly as `repositionPeer` pins a peer. No-op when the id
   * does not name an end of a declared session.
   *
   * The write lands on the session rather than on an entity of the end's
   * own, because the end has none: it is a place its session owns, and it
   * stops existing the moment something attributes it. */
  repositionEndpoint(
    endpointId: string,
    position: { x: number; y: number },
  ): void {
    const at = parseEndpointStageId(endpointId);
    if (!at || this.doc.entities?.sessions?.[at.sessionId] === undefined) {
      return;
    }
    this.#writeEndpointPosition(endpointId, position);
    this.#afterPlacementEdit();
  }

  /** Unpin an end, handing its placement back to the force layout. Cold
   * recompute for the same reason `clearPeerPosition` takes one: the old
   * layout was an equilibrium of the pinned system, not of the free one. */
  clearEndpointPosition(endpointId: string): void {
    const at = parseEndpointStageId(endpointId);
    const def = at && this.doc.entities?.sessions?.[at.sessionId];
    if (!at || !def?.endpointPosition) return;
    delete def.endpointPosition[at.side];
    this.#requestLayoutRecompute();
    if (this.#txnDepth > 0) {
      this.#txnSeekT = this.clock.t;
      return;
    }
    this.#refreshStageAtPlayhead();
    this.#notify();
  }

  /** Single dispatch point for builder mutations. Routes a
   * domain-shaped intent to the underlying mutation method,
   * handling no-op detection + undo bookkeeping. Returns the new
   * peer id for `add-peer`. */
  dispatch(intent: BuilderIntent): string | undefined {
    // No-op intents short-circuit before we pay for a snapshot;
    // they neither mutate nor record undo.
    if (
      isNoOpIntent(this.doc, this.world, this.clock.t, intent)
    ) {
      return undefined;
    }

    // ONE snapshot serves two roles:
    //   1. Atomic rollback if the mutation throws partway. Without
    //      this, a half-applied dispatch (e.g. `#authoredCounter`
    //      bumped, `#definePeer` ran, then `applyAuthored` threw)
    //      would desync state vs. fixture identity. The user-visible
    //      symptom shows up the moment validation/collision checks
    //      start throwing intentionally (rename / paste / duplicate).
    //   2. The undo entry's "before" image — recorded on success
    //      when we're outside a transaction. Inside a transaction,
    //      `beginTransaction` already captured the txn-begin
    //      snapshot, so we only use this one for the rollback path.
    //
    // Inside a transaction `beginTransaction` already holds the undo
    // image. Cloning again per dispatch was the second tax on Unpin all
    // and multi-delete (after the per-member layout/seek). Rollback of a
    // failed member uses the txn snapshot — the whole gesture, which is
    // what `asOneEdit` means.
    const snapshotBefore = this.#txnDepth > 0
      ? this.#txnSnapshot!
      : this.#takeSnapshot();
    // `#authoredCounter` lives outside the doc snapshot (undo/redo
    // deliberately doesn't reuse IDs across boundaries), so rollback
    // restores it separately. Without this a half-applied dispatch
    // would silently burn an ID slot.
    const counterBefore = this.#authoredCounter;
    let result: string | undefined;
    try {
      result = this.#applyBuilderIntent(intent);
    } catch (caught) {
      this.#clearTxnStage();
      this.#applySnapshot(snapshotBefore);
      this.#authoredCounter = counterBefore;
      this.#emitError(internalError(caught));
      return undefined;
    }
    if (this.#txnDepth === 0) {
      this.#history.recordBefore(snapshotBefore, intentLabel(intent));
    }
    return result;
  }

  #applyBuilderIntent(intent: BuilderIntent): string | undefined {
    switch (intent.kind) {
      case "add-peer": {
        // User-supplied id wins over the auto-mint. Collision-rejecting
        // — emit `collisionError` and short-circuit (the doc is
        // untouched at this point so no rollback needed). Matches the
        // `rename-*` paths' UX.
        let peerId: string;
        if (intent.id !== undefined && intent.id.length > 0) {
          if (this.doc.entities?.peers?.[intent.id] !== undefined) {
            this.#emitError(collisionError("peer", intent.id));
            return undefined;
          }
          peerId = intent.id;
        } else {
          this.#authoredCounter += 1;
          peerId = `peer-${this.#authoredCounter}`;
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
          start: explicitBound(this.clock.t),
          duration: implicitBound(0),
        };
        this.#definePeer(peerId, {
          profile: intent.profile,
          label: intent.label ?? peerId,
          position: intent.position,
          timing: peerTiming,
        });
        commitEntityAuthoring(this.#ctx, this.clock.t);
        return peerId;
      }
      case "reposition-peer":
        this.repositionPeer(intent.peerId, intent.position);
        return undefined;
      case "clear-peer-position":
        this.clearPeerPosition(intent.peerId);
        return undefined;
      case "reposition-endpoint":
        this.repositionEndpoint(intent.endpointId, intent.position);
        return undefined;
      case "clear-endpoint-position":
        this.clearEndpointPosition(intent.endpointId);
        return undefined;
      case "update-peer":
        this.updatePeer(intent.peerId, intent.patch);
        return undefined;
      case "open-session": {
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
          if (this.doc.entities?.peers?.[peer] !== undefined) continue;
          this.#emitError(
            nodeKindOf(peer) === "endpoint"
              ? validationError(
                "A session cannot be opened onto an end nothing has attributed.",
                "Attribute that end to a peer first, then open the session to the peer.",
              )
              : notFoundError("peer", peer),
          );
          return undefined;
        }
        this.#authoredCounter += 1;
        const sessionId = `session-${this.#authoredCounter}`;
        const codec = intent.codec ?? DEFAULT_SESSION_CODEC;
        const captpVersion = intent.captpVersion ?? DEFAULT_SESSION_CAPTP;
        const initialState = intent.initialState ?? DEFAULT_SESSION_STATE;
        // Identity → entities map first; event below carries the
        // same attrs for fixture back-compat.
        const sessionTiming: TimeSpan = {
          start: explicitBound(this.clock.t),
          duration: implicitBound(0),
        };
        this.#defineSession(sessionId, {
          a: intent.a,
          b: intent.b,
          codec,
          captpVersion,
          initialState,
          timing: sessionTiming,
        });
        commitEntityAuthoring(this.#ctx, this.clock.t);
        return sessionId;
      }
      case "send-message": {
        this.#authoredCounter += 1;
        const messageId = `msg-${this.#authoredCounter}`;
        const flight = intent.flightMs ?? DEFAULT_MESSAGE_FLIGHT_MS;
        const sentT = this.clock.t;
        const arrivalT = sentT + flight;
        // Identity → entities map first (see #defineMessage).
        // Messages: duration is ALWAYS explicit (flight time is a
        // semantic property, not inherited).
        const messageTiming: TimeSpan = {
          start: explicitBound(sentT),
          duration: explicitBound(flight),
        };
        this.#defineMessage(messageId, {
          sessionId: intent.sessionId,
          from: intent.from,
          to: intent.to,
          ...(intent.label !== undefined ? { label: intent.label } : {}),
          // Flight time IS timing.duration; no separate flightMs field.
          timing: messageTiming,
        });
        commitEntityAuthoring(this.#ctx, arrivalT);
        return messageId;
      }
      case "delete-peer":
        this.deletePeer(intent.peerId);
        return undefined;
      case "delete-session":
        this.deleteSession(intent.sessionId);
        return undefined;
      case "delete-message":
        this.deleteMessage(intent.messageId);
        return undefined;
      case "update-session":
        this.updateSession(intent.sessionId, intent.patch);
        return undefined;
      case "update-message":
        this.updateMessage(intent.messageId, intent.patch);
        return undefined;
      case "move-event":
        this.moveEvent(intent.move);
        return undefined;
      case "move-entity-span":
        moveEntitySpan(this.#ctx, intent.move);
        return undefined;
      case "set-peer-end":
        this.setPeerEnd(intent.peerId, intent.t);
        return undefined;
      case "set-peer-duration":
        this.setPeerDuration(intent.peerId, intent.duration);
        return undefined;
      case "clear-peer-end":
        this.clearPeerEnd(intent.peerId);
        return undefined;
      case "set-peer-start":
        this.setPeerStart(intent.peerId, intent.t);
        return undefined;
      case "set-peer-update":
        this.setPeerUpdate(
          intent.peerId,
          intent.t,
          intent.property,
          intent.value,
        );
        return undefined;
      case "remove-peer-update":
        this.removePeerUpdate(intent.peerId, intent.t, intent.property);
        return undefined;
      case "clear-peer-start":
        this.clearPeerStart(intent.peerId);
        return undefined;
      case "set-session-start":
        this.setSessionStart(intent.sessionId, intent.t);
        return undefined;
      case "clear-session-start":
        this.clearSessionStart(intent.sessionId);
        return undefined;
      case "set-message-start":
        this.setMessageStart(intent.messageId, intent.t);
        return undefined;
      case "clear-message-start":
        this.clearMessageStart(intent.messageId);
        return undefined;
      case "set-message-end":
        this.setMessageEnd(intent.messageId, intent.t);
        return undefined;
      case "set-message-duration":
        this.setMessageDuration(intent.messageId, intent.duration);
        return undefined;
      case "set-session-end":
        this.setSessionEnd(intent.sessionId, intent.t);
        return undefined;
      case "set-session-duration":
        this.setSessionDuration(intent.sessionId, intent.duration);
        return undefined;
      case "clear-session-end":
        this.clearSessionEnd(intent.sessionId);
        return undefined;
      case "set-session-keyframe":
        this.setSessionKeyframe(
          intent.sessionId,
          intent.property,
          intent.t,
          intent.value,
        );
        return undefined;
      case "remove-session-keyframe":
        this.removeSessionKeyframe(
          intent.sessionId,
          intent.property,
          intent.t,
        );
        return undefined;
      case "set-session-initial-state":
        this.setSessionInitialState(intent.sessionId, intent.state);
        return undefined;
      case "update-session-endpoint":
        this.updateSessionEndpoint(
          intent.sessionId,
          intent.side,
          intent.patch,
        );
        return undefined;
      case "reorder-row":
        this.reorderRow(intent.category, intent.order);
        return undefined;
      case "set-row-vis-mode":
        this.setRowVisMode(intent.category, intent.id, intent.mode);
        return undefined;
      case "set-category-vis-mode":
        this.setCategoryVisMode(intent.category, intent.mode);
        return undefined;
      case "set-all-vis-mode":
        this.setAllVisMode(intent.mode);
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
          this.#ctx,
          category,
          intent.oldId,
          intent.newId,
        );
        if (!result.ok) this.#emitError(result.error);
        return undefined;
      }
    }
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
    deletePeerOnCtx(this.#ctx, peerId);
  }

  deleteSession(sessionId: string): void {
    deleteSessionOnCtx(this.#ctx, sessionId);
  }

  deleteMessage(messageId: string): void {
    deleteMessageOnCtx(this.#ctx, messageId);
  }

  /** Extract a `ClipboardPayload` from the current doc + a selection.
   *  Pure read — no engine state change. Caller (UI) holds the
   *  payload between copy and paste; the engine doesn't carry
   *  clipboard state. */
  extractPayload(selection: Selection): ClipboardPayload {
    return extractClipboardPayload(this.doc, selection);
  }

  /** Paste a clipboard payload into the doc at `clockT` (defaults to
   *  current playhead). On success: applies the merged doc in place,
   *  recomputes layout, seeks to refresh the world, records one
   *  undo entry (unless inside an open transaction), and notifies
   *  subscribers. Returns the id-remap so the UI can update its
   *  selection state to the pasted entities. On validation failure
   *  (dangling external refs): emits the error on the bus, returns
   *  the result; doc untouched. */
  paste(
    payload: ClipboardPayload,
    clockT?: number,
    /** What the undo menu calls this. Duplicate is the same write
     *  reached by a different verb, and it says its own name. */
    label = "Paste",
  ): EngineResult<{ remap: IdRemap }> {
    const t = clockT ?? this.clock.t;
    const before = this.#takeSnapshot();
    const counterBefore = this.#authoredCounter;
    const r = cascadePaste(this.doc, payload, t);
    if (!r.ok) {
      this.#emitError(r.error);
      return r;
    }
    try {
      restoreSnapshotInto(this.doc, takeSnapshot(r.value.doc));
      // Same clock-follows-doc pairing as `#applySnapshot`.
      this.clock.setDuration(this.doc.duration);
      this.layout.recompute();
      this.seekTo(this.clock.t);
    } catch (caught) {
      this.#applySnapshot(before);
      this.#authoredCounter = counterBefore;
      const internal = internalError(caught);
      this.#emitError(internal);
      return err(internal);
    }
    if (this.#txnDepth === 0) {
      this.#history.recordBefore(before, label);
    }
    this.#notify();
    return ok({ remap: r.value.remap });
  }

  /** Duplicate a selection — extract a payload from the current doc
   *  and immediately paste it. Equivalent to copy + paste in one
   *  step but doesn't touch any external clipboard state. Returns
   *  the id-remap so callers can select the duplicated entities. */
  duplicate(
    selection: Selection,
    clockT?: number,
  ): EngineResult<{ remap: IdRemap }> {
    const payload = extractClipboardPayload(this.doc, selection);
    return this.paste(payload, clockT, "Duplicate");
  }

  /** Shared deletion path. Filters events in place, then re-runs
   * layout + re-seeks so the world catches up. */
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
    updateSessionOnCtx(this.#ctx, sessionId, patch);
  }

  updateMessage(
    messageId: string,
    patch: {
      label?: string;
      sessionId?: string;
      swapDirection?: true;
    },
  ): void {
    updateMessageOnCtx(this.#ctx, messageId, patch);
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
    moveEventOnCtx(this.#ctx, move);
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
    updatePeerOnCtx(this.#ctx, peerId, patch);
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
    const next = { ...(this.doc.rowOrder ?? {}) };
    if (order.length === 0) {
      delete next[category];
    } else {
      next[category] = [...order];
    }
    const anyEntry = next.peers !== undefined ||
      next.sessions !== undefined ||
      next.messages !== undefined;
    (this.doc as TimelineDocument).rowOrder = anyEntry ? next : undefined;
    // Pure view-state — no clock seek needed (the renderer reads
    // `doc.rowOrder` directly each paint). But we DO need to
    // notify React-side subscribers (`useEngineVersion`) so the
    // Scrubber re-renders immediately; without this, the gutter
    // paint lags one engine tick behind the dispatch (Stage is
    // unaffected because its ticker reads `engine.doc` directly).
    this.#notify();
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
    return effectiveOfEntity(this.doc, category, id).start;
  }
  effectiveEnd(
    category: "peers" | "sessions" | "messages",
    id: string,
  ): number {
    // doc-resolver returns Infinity for implicit-end peers (world
    // is unbounded). Callers expect `doc.duration` as the visible
    // ceiling — clamp here so the timeline-bounded UI keeps
    // working without a separate "visible end" pass.
    const end = effectiveOfEntity(this.doc, category, id).end;
    return Number.isFinite(end) ? end : this.doc.duration;
  }

  /** Intrinsic start — the entity's stored intent after resolving
   * implicit sides through inheritance, BUT before clamping into
   * the parent context. Differs from `effectiveStart` only when a
   * parent context has squeezed the value. */
  intrinsicStart(
    category: "peers" | "sessions" | "messages",
    id: string,
  ): number {
    return intrinsicOfEntity(this.doc, category, id).start;
  }
  intrinsicEnd(
    category: "peers" | "sessions" | "messages",
    id: string,
  ): number {
    const end = intrinsicOfEntity(this.doc, category, id).end;
    return Number.isFinite(end) ? end : this.doc.duration;
  }

  /** When intrinsic ≠ effective on a side, names the ancestor
   * that's clamping. Null when the value passes through unchanged.
   * For peers (parent = unbounded world), always null. */
  clampReason(
    category: "peers" | "sessions" | "messages",
    id: string,
    side: "start" | "end",
  ): string | null {
    return clampReasonFor(this.doc, category, id, side);
  }

  setPeerEnd(peerId: string, t: number): void {
    setPeerEndOnCtx(this.#ctx, peerId, t);
  }

  setPeerDuration(peerId: string, duration: number): void {
    setPeerDurationOnCtx(this.#ctx, peerId, duration);
  }

  clearPeerEnd(peerId: string): void {
    clearPeerEndOnCtx(this.#ctx, peerId);
  }

  setPeerStart(peerId: string, t: number): void {
    setPeerStartOnCtx(this.#ctx, peerId, t);
  }

  clearPeerStart(peerId: string): void {
    clearPeerStartOnCtx(this.#ctx, peerId);
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
    setPeerUpdateOnCtx(this.#ctx, peerId, t, property, value);
  }

  /** Stop stating one property at exactly `t`. No-op when it stated
   *  nothing. */
  removePeerUpdate(peerId: string, t: number, property: PeerProperty): void {
    removePeerUpdateOnCtx(this.#ctx, peerId, t, property);
  }

  /** Set the session's start: pins `timing.start` explicit at `t`.
   * Identity from `doc.entities.sessions[sessionId]`. Validates
   * against the cascade lower bound: `t >= max(peerA.effectiveStart,
   * peerB.effectiveStart)` — a session can't predate either
   * endpoint. Mirrors `setPeerStart` for the session level. */
  setSessionStart(sessionId: string, t: number): void {
    setSessionStartOnCtx(this.#ctx, sessionId, t);
  }

  clearSessionStart(sessionId: string): void {
    clearSessionStartOnCtx(this.#ctx, sessionId);
  }

  setMessageStart(messageId: string, t: number): void {
    setMessageStartOnCtx(this.#ctx, messageId, t);
  }

  clearMessageStart(messageId: string): void {
    clearMessageStartOnCtx(this.#ctx, messageId);
  }

  setMessageEnd(messageId: string, arrivalT: number): void {
    setMessageEndOnCtx(this.#ctx, messageId, arrivalT);
  }

  setMessageDuration(messageId: string, duration: number): void {
    setMessageDurationOnCtx(this.#ctx, messageId, duration);
  }

  /** Session counterpart to `setPeerEnd` — pins `timing.duration`
   * so the session's painted end lands at `t`. Validated against
   * the painted start (close cannot precede open). */
  setSessionEnd(sessionId: string, t: number): void {
    setSessionEndOnCtx(this.#ctx, sessionId, t);
  }

  setSessionDuration(sessionId: string, duration: number): void {
    setSessionDurationOnCtx(this.#ctx, sessionId, duration);
  }

  clearSessionEnd(sessionId: string): void {
    clearSessionEndOnCtx(this.#ctx, sessionId);
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
    setSessionKeyframeOnCtx(this.#ctx, sessionId, property, t, value);
  }

  /** Stop stating one property at exactly `t`. No-op when it stated
   *  nothing there. */
  removeSessionKeyframe(
    sessionId: string,
    property: SessionProperty,
    t: number,
  ): void {
    removeSessionKeyframeOnCtx(this.#ctx, sessionId, property, t);
  }

  /** Edit the session's genesis `initialState` (row 0 of the state
   *  trajectory — the value the session is born with). */
  setSessionInitialState(sessionId: string, state: SessionState): void {
    setSessionInitialStateOnCtx(this.#ctx, sessionId, state);
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
    updateSessionEndpointOnCtx(this.#ctx, sessionId, side, patch);
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
    setRowVisModeOnDoc(this.doc as TimelineDocument, category, id, mode);
    // Same React-subscriber notification as `reorderRow` — without
    // it the gutter eyeball glyph waits for the next clock tick to
    // repaint, even though the Stage updates same-frame.
    this.#notify();
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
    if (setCategoryVisModeOnDoc(this.doc as TimelineDocument, category, mode)) {
      this.#notify();
    }
  }

  /** Set the all-rows visibility flag. INDEPENDENT of per-category
   * and per-entity flags — same cascade rationale as
   * `setCategoryVisMode`. */
  // ─────────────── What the document says about itself ────────────────
  //
  // One setter per field rather than one that takes a patch, because each is a
  // separate undo entry with its own label and a patch would need the caller to
  // say which. `dct:modified` is not among them: it is stamped when a document is
  // saved (`saveStampedDoc`), so no clock runs in the edit path.

  /** Set the document's title, or clear it when the text is blank. */
  setDocumentTitle(title: string): void {
    this.#setMetadataField("dct:title", title);
  }

  /** Set the document's description, or clear it when the text is blank. */
  setDocumentDescription(description: string): void {
    this.#setMetadataField("dct:description", description);
  }

  /** Set who the document is by, or clear it when the text is blank. */
  setDocumentCreator(creator: string): void {
    this.#setMetadataField("dct:creator", creator);
  }

  /**
   * Write one metadata field, treating blank as absent.
   *
   * Blank clears rather than storing `""`, because an empty string and a missing
   * field would both read as "no title" and only one of them survives a
   * round-trip through the schema, so keeping both would make two documents that
   * say the same thing compare unequal.
   *
   * The text is stored EXACTLY as typed. Trimming it here would eat the space a
   * reader is in the middle of typing: this runs per keystroke against a
   * controlled field that reads the stored value straight back, so "Hand off "
   * would be stored as "Hand off" and redrawn without the space, and the next
   * letter would arrive against the trimmed text. Only the decision to clear
   * looks past whitespace, so a field holding nothing but spaces is a field
   * holding nothing.
   *
   * No transaction is opened here. A typing burst is bracketed by the field that
   * owns the caret (`InlineTextField` through `EditSession`), so opening one per
   * keystroke would make each letter its own undo step.
   */
  #setMetadataField(
    key: "dct:title" | "dct:description" | "dct:creator",
    text: string,
  ): void {
    const next = text.trim() === "" ? "" : text;
    const current = this.doc.metadata?.[key];
    if ((current ?? "") === next) return;
    const metadata = { ...this.doc.metadata };
    if (next === "") delete metadata[key];
    else metadata[key] = next;
    this.doc.metadata = Object.keys(metadata).length > 0 ? metadata : undefined;
    this.#notify();
  }

  /**
   * Stamp `dct:modified` with `now`.
   *
   * Outside history by construction: it is called after the edit's transaction
   * has closed, and `endTransaction` is the only thing that records, so nothing
   * here can push an entry. `DocSnapshot` also leaves this one key out, so an
   * undo reverts the edit and not the record that an edit happened — reverting a
   * title should not claim the document was last modified before it was.
   *
   * `now` is a parameter rather than read from a clock here, so the edit path
   * stays free of one and a test can say what time it is.
   */
  noteDocumentModified(now: string): void {
    const metadata = { ...this.doc.metadata, "dct:modified": now };
    this.doc.metadata = metadata;
    this.#notify();
  }

  /**
   * Set how long the timeline is.
   *
   * Refuses to shrink below what the document already states, because a
   * duration shorter than the last thing on it would hide events with no way to
   * reach them: the scrubber cannot travel past the end. Growing is always
   * allowed. `authoring/events.ts` grows it the other way, to fit an edit that
   * lands past the end, and the two must not disagree about the floor.
   */
  setDocumentDuration(duration: number): void {
    if (!Number.isFinite(duration)) return;
    const floor = latestStatedTime(this.doc);
    const next = Math.max(floor, Math.max(0, duration));
    if (next === this.doc.duration) return;
    this.beginTransaction("Set timeline length");
    (this.doc as { duration: number }).duration = next;
    this.clock.setDuration(next);
    this.endTransaction();
    this.#notify();
  }

  /** The floor `setDocumentDuration` will not go below: the last moment the
   *  document states anything at. */
  documentDurationFloor(): number {
    return latestStatedTime(this.doc);
  }

  /**
   * Record where the camera is, as the view this document opens at.
   *
   * Called as the camera comes to rest, so looking around IS what sets it and
   * there is nothing to press. That is why it is outside undo: a wheel gesture
   * crosses dozens of scales on the way to one, and each would otherwise be a
   * step to undo, so a reader who zoomed in and pressed undo would walk back out
   * a frame at a time instead of reversing their last real edit.
   *
   * Outside undo is also why it is written straight rather than through a
   * transaction: `endTransaction` is the only thing that records, so a write with
   * none open cannot enter history. `DocSnapshot` leaves it out for the same
   * reason, which means an undo does not move the camera either — reversing an
   * edit should not also send the reader somewhere else.
   *
   * No-ops when the view is the one already stored, so a still camera publishing
   * the same numbers does not notify the app.
   */
  /**
   * Set where the document opens, or say it names no view at all.
   *
   * An ordinary document edit: pressed for, recorded in the history, taken back
   * by undo like a title. That is the whole reason it is a verb rather than
   * something the camera does — a document changes when a reader changes it, and
   * every change a reader makes is a step they can walk back.
   *
   * The camera does NOT write this as it moves. Looking around is reading, and a
   * reader who pans across a document should not be building a history or turning
   * the panel's edited badge on. What the camera does instead is offer: the
   * Opens-at row's button lights up once the view differs from what is stored, and
   * pressing it lands here (`ui/DocumentFields.tsx`).
   *
   * `undefined` means the document names no view and so opens where any document
   * that names none opens. The caller passes it when the camera is sitting exactly
   * there, because what that place IS belongs to the camera
   * (`render/stage-view.ts`'s `DEFAULT_STAGE_VIEW`), which is also why this takes
   * a plain view rather than reaching for it.
   */
  setOpeningView(
    view: { zoom: number; center: { x: number; y: number } } | undefined,
  ): void {
    if (sameStoredView(this.doc.initialView, view)) return;
    this.doc.initialView = view === undefined ? undefined : {
      zoom: view.zoom,
      center: { x: view.center.x, y: view.center.y },
    };
    this.#notify();
  }

  setAllVisMode(mode: "visible" | "label" | "body" | "both"): void {
    if (setAllVisModeOnDoc(this.doc as TimelineDocument, mode)) {
      this.#notify();
    }
  }

  /** Per-entity stored mode. UI consumers cycling the entity
   * eyeball read this directly; render-time cascade lives in
   * `effectiveRowVisMode`. */
  rowVisMode(
    category: "peers" | "sessions" | "messages",
    id: string,
  ): "visible" | "label" | "body" | "both" {
    return rowVisModeOnDoc(this.doc, category, id);
  }

  /** Stored category flag. NOT a roll-up of entity flags. */
  categoryVisMode(
    category: "peers" | "sessions" | "messages",
  ): "visible" | "label" | "body" | "both" {
    return categoryVisModeOnDoc(this.doc, category);
  }

  /** Stored all-rows flag. NOT a roll-up of category flags. */
  allVisMode(): "visible" | "label" | "body" | "both" {
    return allVisModeOnDoc(this.doc);
  }

  /** Effective per-entity visibility for rendering: composes the
   * `all → category → entity` cascade. The cascade-bug fix replaces
   * `effectiveRowVisMode` in `./visibility.ts` only — this method
   * stays a one-line delegate. */
  effectiveRowVisMode(
    category: "peers" | "sessions" | "messages",
    id: string,
  ): "visible" | "label" | "body" | "both" {
    return effectiveRowVisModeOnDoc(this.doc, category, id);
  }

  #doRestart(): void {
    this.#resetWorld();
    this.clock.restart();
    this.#applyInstantaneousEvents();
  }

  /** Play, restarting first if at the end. Without the restart,
   * the world is frozen in its end-state and transient events
   * never re-fire. */
  #playOrRestart(): void {
    if (this.clock.isAtEnd) this.#doRestart();
    this.clock.play();
  }

  #doSeek(targetT: number): void {
    const clamped = Math.max(0, Math.min(this.doc.duration, targetT));
    // Same document-changed gate as `#drainEvents`: live feeds append
    // observations in place, projection returns a fresh doc when it notices,
    // and only then are keyframes stale. Seek must not skip that recompute or
    // scrubbing after a paused live arrival leaves peers at seed positions.
    const docChanged = this.#reproject();
    this.#resetWorld();
    materializeWorldAt(this.world, this.doc, clamped);
    if (docChanged) this.layout.recompute();
    this.layout.update(this.world, clamped);
    this.messages.update(
      this.world,
      observationsOf(this.doc) as readonly TimelineEvent[],
      clamped,
      this.claims,
    );
    this.clock.seekTo(clamped);
    this.#prevT = clamped;
    this.#lastUpdateT = clamped;
  }

  #resetWorld(): void {
    for (const e of [...this.world]) this.world.remove(e);
    this.#prevT = 0;
    // Force the next tick's layout / messages update to run — the
    // entity world is empty so the cached "already updated for
    // this t" promise no longer holds.
    this.#lastUpdateT = Number.NaN;
  }
}
