import { parseEndpointStageId } from "../schema/session-end.ts";
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
import type { LayoutMode, TimelineDocument } from "./timeline.ts";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "./systems/keyframe-layout-system.ts";
import { MessageFlightSystem } from "./systems/message-flight-system.ts";
import { type FrameGeometry } from "./session-geometry.ts";
import { type EngineError, type EngineResult, err, internalError, ok } from "./errors.ts";
import { intentLabel } from "./intent-labels.ts";
import { isNoOpIntent } from "./no-op-guards.ts";
import { restoreSnapshotInto, takeSnapshot } from "./snapshot.ts";
import {
  clearEndpointPositionOnDoc,
  clearPeerPositionOnDoc,
  writeEndpointPosition,
  writePeerPosition,
} from "./authoring/placement.ts";
import type { AuthoringContext } from "./authoring/context.ts";
import { applyBuilderIntent, type PlacementCommands } from "./authoring/dispatch.ts";
import { validateIntent } from "./authoring/validate.ts";
import { cascadePaste, type IdRemap } from "./schema/paste.ts";
import { type ClipboardPayload } from "./schema/clipboard.ts";
import { extractClipboardPayload, type Selection } from "./schema/extract.ts";
import { type BuilderIntent, type EngineIntent } from "./intents.ts";
import { orderByRowOrder } from "./event-helpers.ts";
import { projectFromObservations } from "./temporal/project-from-observations.ts";
import { EngineDocApi } from "./engine-doc.ts";
import { EditSession } from "./edit-session.ts";
import { Playback } from "./playback.ts";

export type EngineOptions = {
  /** Override the document's layout mode. */
  layoutMode?: LayoutMode;
};

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
 *
 * Playback, edit history, and document authoring each have their own
 * module. This class is the public door and the placement path that
 * has to refresh the stage the same frame as a pin write.
 */
export class Engine extends EngineDocApi implements PlacementCommands {
  doc: TimelineDocument;
  readonly clock: Clock;
  readonly world: GameWorld;
  readonly queries: Queries;
  readonly layout: KeyframeLayoutSystem;
  readonly messages: MessageFlightSystem;

  #listeners = new Set<() => void>();
  #errorListeners = new Set<(err: EngineError) => void>();
  // Monotonic counter bumped in `notify`. Read by
  // `useEngineVersion` via `useSyncExternalStore` to decide
  // whether to re-render.
  #version = 0;
  #docVersion = 0;
  // Per-engine authored-event id counter — two side-by-side
  // engines don't collide because each owns its own doc.
  #authoredCounter = 0;
  #playback!: Playback;
  #edits!: EditSession;
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
    super();
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
    this.#playback = new Playback({
      getDoc: () => this.doc,
      setDoc: (value) => {
        this.doc = value;
      },
      clock: this.clock,
      world: this.world,
      layout: this.layout,
      messages: this.messages,
      claims: () => this.layout.claims,
      notify: (docChanged) => this.notify(docChanged),
      emitError: (err) => this.#emitError(err),
      rebindDoc: (next) => {
        if (this.#ctx.doc === next) return false;
        this.#ctx = { ...this.#ctx, doc: next };
        return true;
      },
    });
    this.#edits = new EditSession({
      getDoc: () => this.doc,
      clock: this.clock,
      layout: this.layout,
      notify: (docChanged) => this.notify(docChanged),
      seekWorld: (t) => this.#playback.seekTo(t),
      source: () => this.#source,
    });
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
      recomputeLayout: () => this.#edits.requestLayoutRecompute(),
      seekTo: (t) => this.#edits.authoringSeek(t),
      notify: () => this.notify(),
      emitError: (err) => this.#emitError(err),
    };
    this.#playback.applyInstantaneousEvents();
    // Taken last, so the baseline is the document as every reader
    // first sees it: after the constructor's projection, which fills
    // in `entity.timing` for a loaded document and is what an author
    // then edits away from.
    this.#source = structuredClone(this.doc);
  }

  protected override get ctx(): AuthoringContext {
    return this.#ctx;
  }

  /**
   * Wake every subscriber, and say whether the document changed with it.
   *
   * `docChanged` defaults to true so that a caller which has not thought about
   * the question reports the conservative answer. Callers that pass false are
   * ones that can prove the document identity did not change for panel
   * purposes: `tick` when the clock alone advanced, and a placement write
   * inside an open transaction (the txn-end `#notify` records the edit).
   */
  protected override notify(docChanged = true): void {
    this.#version += 1;
    if (docChanged) {
      this.#docVersion += 1;
      this.#playback.markDocumentChanged();
    }
    for (const listener of this.#listeners) {
      try {
        listener();
      } catch (caught) {
        console.error("ocapnviz engine: subscriber threw", caught);
        this.#emitError(internalError(caught));
      }
    }
  }

  /** Advance by `wallDt` ms. The only runtime mutator. Returns simDt. */
  tick(wallDt: number): number {
    return this.#playback.tick(wallDt);
  }

  /** Enqueue a user intent. Drained in FIFO order at the next `tick()`. */
  enqueue(intent: EngineIntent): void {
    this.#playback.enqueue(intent);
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
   * Coverage lives in `authoring/validate.ts`.
   */
  validate(intent: BuilderIntent | EngineIntent): EngineResult<void> {
    return validateIntent(this.doc, intent);
  }

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

  /** Monotonic counter bumped on every `#notify`; `useEngineVersion` reads it. */
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

  /**
   * The claim/bundle tables the last layout + message pass produced.
   * Stage reads these for the frame instead of rebuilding; flight already
   * used them to place dots, so an edge drawn from a second map would
   * disagree with its own traffic.
   */
  get frameGeometry(): FrameGeometry {
    return this.#playback.frameGeometry;
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

  /** Imperative reset to t=0. Notifies subscribers. Tests / embedders only. */
  restart(): void {
    this.#playback.restart();
    this.notify();
  }

  override beginTransaction(label = "Edit"): void {
    this.#edits.begin(label);
  }

  override endTransaction(): void {
    this.#edits.end();
  }

  /** Pop the previous snapshot and restore it. No-op when empty. */
  undo(): void {
    this.#edits.undo();
  }

  /**
   * Pop the next snapshot off the redo stack and restore it.
   * No-op if there's nothing to redo. Notifies subscribers via
   * `seekTo`.
   */
  redo(): void {
    this.#edits.redo();
  }

  get canUndo(): boolean {
    return this.#edits.canUndo;
  }
  get canRedo(): boolean {
    return this.#edits.canRedo;
  }
  get hasHistory(): boolean {
    return this.#edits.hasHistory;
  }
  get nextUndoLabel(): string | undefined {
    return this.#edits.nextUndoLabel;
  }
  get nextRedoLabel(): string | undefined {
    return this.#edits.nextRedoLabel;
  }

  undoAll(): void {
    this.#edits.undoAll();
  }

  discardAllEdits(): void {
    this.#edits.discardAllEdits();
  }

  /**
   * Imperative seek. Rebuilds the world from `[0, targetT]`, runs
   * layout, pins messages-in-flight to their progress at `targetT`.
   * Preserves clock state. Tests / embedders only.
   */
  seekTo(targetT: number): void {
    // A scrub during an open authoring transaction still needs a current
    // layout if pin/topology writes deferred a recompute.
    this.#edits.flushLayoutForSeek();
    this.#playback.seekTo(targetT);
    this.notify();
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
    writePeerPosition(this.doc, peerId, position);
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
        writePeerPosition(this.doc, move.id, move.position);
      } else {
        writeEndpointPosition(this.doc, move.id, move.position);
      }
    }
    this.#afterPlacementEdit();
  }

  /** Land a placement edit on the stage this frame and wake subscribers.
   *
   * Inside a transaction the document version stays quiet: the gesture's
   * `endTransaction` is the edit document-shaped panels care about, and
   * mid-drag wakes still reach world subscribers via `version`. */
  #afterPlacementEdit(): void {
    this.layout.recomputeForPlacement();
    this.#playback.refreshStageAtPlayhead();
    this.notify(!this.#edits.isOpen);
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
    clearPeerPositionOnDoc(this.doc, peerId);
    this.#edits.requestLayoutRecompute();
    if (this.#edits.isOpen) {
      this.#edits.deferSeek(this.clock.t);
      return;
    }
    this.#playback.refreshStageAtPlayhead();
    this.notify();
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
    writeEndpointPosition(this.doc, endpointId, position);
    this.#afterPlacementEdit();
  }

  /** Unpin an end, handing its placement back to the force layout. Cold
   * recompute for the same reason `clearPeerPosition` takes one: the old
   * layout was an equilibrium of the pinned system, not of the free one. */
  clearEndpointPosition(endpointId: string): void {
    if (!clearEndpointPositionOnDoc(this.doc, endpointId)) return;
    this.#edits.requestLayoutRecompute();
    if (this.#edits.isOpen) {
      this.#edits.deferSeek(this.clock.t);
      return;
    }
    this.#playback.refreshStageAtPlayhead();
    this.notify();
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
    //      this, a half-applied dispatch (e.g. `mintId`
    //      bumped, `definePeer` ran, then `applyAuthored` threw)
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
    const snapshotBefore = this.#edits.isOpen ? this.#edits.txnSnapshot! : this.#edits.takeSnapshot();
    // `#authoredCounter` lives outside the doc snapshot (undo/redo
    // deliberately doesn't reuse IDs across boundaries), so rollback
    // restores it separately. Without this a half-applied dispatch
    // would silently burn an ID slot.
    const counterBefore = this.#authoredCounter;
    let result: string | undefined;
    try {
      result = applyBuilderIntent(this.#ctx, intent, this);
    } catch (caught) {
      this.#edits.clearTxnStage();
      this.#edits.applySnapshot(snapshotBefore);
      this.#authoredCounter = counterBefore;
      this.#emitError(internalError(caught));
      return undefined;
    }
    this.#edits.recordIfClosed(snapshotBefore, intentLabel(intent));
    return result;
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
    const before = this.#edits.takeSnapshot();
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
      this.#edits.applySnapshot(before);
      this.#authoredCounter = counterBefore;
      const internal = internalError(caught);
      this.#emitError(internal);
      return err(internal);
    }
    this.#edits.recordIfClosed(before, label);
    this.notify();
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
}
