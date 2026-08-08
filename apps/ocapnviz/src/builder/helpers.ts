/**
 * Pure helpers for build-mode authoring — no React, no DOM. The UI
 * lives in components like `ToolPalette` and `Stage`; this module is
 * the glue between a user's gesture and the engine intents it means.
 * The two-click tools are here, and so are the gestures that act on a
 * whole selection at once: taking history back, and the arrow-key
 * nudge.
 */

import type React from "react";
import type { Engine } from "../engine/engine.ts";
import { findNode } from "../engine/world.ts";
import { authoredPins } from "../engine/event-helpers.ts";
import { observationsOf } from "../engine/temporal/recording-access.ts";
import { TimelineDocument } from "../engine/timeline.ts";
import {
  selectionPhrase,
  tallyByKind,
} from "../ui/inspector/selection-summary.ts";
import type { AppAction } from "../state/app-state.ts";
import {
  attachedEndpoint,
  type CaptpVersion,
  type Codec,
  endpointStageId,
  nodeKindOf,
  type SessionState,
  unattributedEndpoint,
} from "../schema/topology.ts";
import { UNNAMED_END_LABEL } from "../schema/topology.ts";
import {
  entityKey,
  type EntityRef,
  type EntityRefKey,
  parseEntityKey,
  type SelectionAction,
  type SelectionDocSnapshot,
} from "../interactions/types.ts";
import {
  type NodeKind,
  toolAcceptsNode,
} from "../interactions/gesture-resolver.ts";

/**
 * Run `body`'s dispatches as one undo step.
 *
 * The engine records history only at transaction depth zero, so a
 * transaction that opens and never closes does not just lose its own
 * step: it swallows every dispatch after it, and from that moment
 * nothing in the app is undoable. Nothing says so, which is what makes
 * it expensive.
 *
 * A run of dispatches with a `beginTransaction` above it and an
 * `endTransaction` below it is one `parseEntityKey` on a bad key away
 * from exactly that, and the `finally` is the only spelling that
 * cannot be reached around. Written once here so a caller opens a
 * transaction by naming what the step is called and what is in it,
 * and never by remembering to close one.
 *
 * This is for a run that begins and ends in one call. A gesture that
 * opens on one event and closes on another — a drag, a scrub, a typing
 * burst — cannot use it, and takes the Inspector's `editBracket`
 * instead, which knows whether it is open and closes itself when its
 * control goes away.
 */
export function asOneEdit(
  engine: Engine,
  label: string,
  body: () => void,
): void {
  engine.beginTransaction(label);
  try {
    body();
  } finally {
    engine.endTransaction();
  }
}

/** Whether this id names an end nothing has attributed. `nodeKindOf` owns
 *  the question; this is its yes-or-no reading, for the places that only
 *  need the branch. */
function isLoose(nodeId: string): boolean {
  return nodeKindOf(nodeId) === "endpoint";
}

function singletonSet(entity: EntityRef): ReadonlySet<EntityRefKey> {
  return new Set([entityKey(entity)]);
}

/** Tool-options-bar values that affect the commit step of the
 *  two-click flow. Every field is optional — undefined means "use
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
 * between them get one opened for the message; an end cannot take a second
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
  return findOpenSessionBetween(engine, armedNodeId, target.id) === null
    ? "refuses"
    : "takes";
}

/** Commit step of the two-click open-session / send-message tools.
 *
 * First click (no prior pick): arms the node — it lights up via the
 * selection ring while we wait for its partner.
 *
 * Re-click of the armed node: cancels.
 *
 * Click on a different node: dispatches the intent and resets the armed slot.
 * Send-message auto-opens a session first (in the same undo step) if the two
 * don't already share one — there's no way to author a free-floating message.
 *
 * A node here is a peer OR an unattributed session end, because a message can
 * be sent to an end nothing has attributed: that is what the wire looks like
 * before anything proves who answered, and a recording holds it. What an end
 * cannot do is join a SECOND session. Two ends claiming one address may be one
 * host twice or an impostor beside an honest one, and nothing has proved
 * which; a node shared between sessions would be this app asserting they are
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
    // be here. The engine refuses it and says why — the rule is about
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
      ...(options?.captpVersion !== undefined
        ? { captpVersion: options.captpVersion }
        : {}),
      ...(options?.initialState !== undefined
        ? { initialState: options.initialState }
        : {}),
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
      // Open-session options apply to the auto-opened session too —
      // user's intent for "what kind of session to use" is the same
      // whether they explicitly opened one or are sending a message
      // that opens one inline.
      ...(options?.codec !== undefined ? { codec: options.codec } : {}),
      ...(options?.captpVersion !== undefined
        ? { captpVersion: options.captpVersion }
        : {}),
      ...(options?.initialState !== undefined
        ? { initialState: options.initialState }
        : {}),
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
        ...(options?.flightMs !== undefined && Number.isFinite(options.flightMs)
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
 * yet answered for who answered — the wire is real, and who is on the far
 * side of it is open. Build's claim is that every shape a recording can hold
 * can be authored, and until now this one could only be reached by opening a
 * session between two peers in the Inspector and then detaching an end.
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
      ...(options?.captpVersion !== undefined
        ? { captpVersion: options.captpVersion }
        : {}),
      ...(options?.initialState !== undefined
        ? { initialState: options.initialState }
        : {}),
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

/**
 * Hand every pinned node back to the force layout.
 *
 * The same act the Inspector's position row offers one node at a time,
 * swept across the whole stage. Both kinds of pin go: a peer's authored
 * position and a session end's, which `authoredPins` reads together so this
 * cannot clear one kind and call the stage unpinned.
 *
 * One transaction, so the whole sweep is one undo step, because the reader
 * made one gesture. An empty stage dispatches nothing rather than opening a
 * transaction that would close on no change.
 */
export function clearAllPins(engine: Engine): void {
  const pins = authoredPins(engine.doc);
  if (pins.size === 0) return;
  asOneEdit(engine, "Unpin all", () => {
    for (const nodeId of pins.keys()) {
      if (isLoose(nodeId)) {
        engine.dispatch({
          kind: "clear-endpoint-position",
          endpointId: nodeId,
        });
      } else {
        engine.dispatch({ kind: "clear-peer-position", peerId: nodeId });
      }
    }
  });
}

/**
 * Move every node in the selection by one step.
 *
 * A node is a peer or a session end nothing has attributed, which is the same
 * pair the stage lets you drag, so what the arrow keys move and what the
 * pointer moves are one set. Everything else in the selection sits still: a
 * session is drawn between its two ends and a message rides the wire, so
 * neither has a place of its own to be moved to.
 *
 * Every position is read before the first write, because repositioning one
 * node re-solves the layout around it: read as we go and a later node would
 * step off wherever the solver had just put it rather than off where the
 * reader saw it.
 *
 * One transaction, so a press moves the whole selection in a single undo
 * step, and the label names what actually moved. A press that moves nothing
 * answers `false` and hands the keystroke back, which is what lets an arrow
 * over a selection of sessions go on scrubbing time.
 */
export function nudgeSelection(
  engine: Engine,
  selection: ReadonlySet<EntityRefKey>,
  delta: { dx: number; dy: number },
): boolean {
  const moving: {
    key: EntityRefKey;
    kind: "peer" | "endpoint";
    id: string;
    to: { x: number; y: number };
  }[] = [];
  for (const key of selection) {
    const { kind, id } = parseEntityKey(key);
    if (kind !== "peer" && kind !== "endpoint") continue;
    const from = findNode(engine.world, id)?.position;
    if (from === undefined) continue;
    moving.push({
      key,
      kind,
      id,
      to: { x: from.x + delta.dx, y: from.y + delta.dy },
    });
  }
  if (moving.length === 0) return false;
  const moved = new Set<EntityRefKey>(moving.map((m) => m.key));
  asOneEdit(engine, `Nudge ${selectionPhrase(tallyByKind(moved))}`, () => {
    engine.repositionNodes(
      moving.map((m) => ({
        kind: m.kind,
        id: m.id,
        position: m.to,
      })),
    );
  });
  return true;
}

/** What the selection store needs to know about the document it is
 *  selecting in. The store holds no engine import, so this is where a
 *  real document is read into the shape its actions carry. */
export function selectionDocOf(doc: TimelineDocument): SelectionDocSnapshot {
  return {
    observations: observationsOf(doc),
    duration: doc.duration,
    entities: doc.entities,
  };
}

function reconcileSelection(
  engine: Engine,
  dispatchSelection: React.Dispatch<SelectionAction>,
): void {
  dispatchSelection({
    kind: "reconcile-with-doc",
    doc: selectionDocOf(engine.doc),
  });
}

/**
 * Take history back, and walk the selection back with it.
 *
 * Undo moves ids out from under the selection. A rename taken back restores
 * the name the peer had before it, an undone paste takes its entities away
 * again, and a selection still naming what went is a selection pointing at
 * nothing, which the Inspector reads out as an unknown peer. So the two are
 * one act, and every surface that offers undo asks for it here instead of
 * reaching for the engine on its own.
 */
export function undoWithSelection(
  engine: Engine,
  dispatchSelection: React.Dispatch<SelectionAction>,
): void {
  engine.undo();
  reconcileSelection(engine, dispatchSelection);
}

/** Take history forward, and walk the selection with it. The mirror of
 *  `undoWithSelection`: redo moves ids under the selection exactly as undo
 *  does, so it takes the same pair of steps. */
export function redoWithSelection(
  engine: Engine,
  dispatchSelection: React.Dispatch<SelectionAction>,
): void {
  engine.redo();
  reconcileSelection(engine, dispatchSelection);
}

/**
 * Throw away every edit, and walk the selection back with them.
 *
 * The same pairing `undoWithSelection` makes, for the same reason and
 * more of it: a discard takes back every id an edit ever minted at
 * once, so a selection naming a peer the author added is a selection
 * pointing at nothing the moment the command runs.
 *
 * The engine's `discardAllEdits` is the reset, and unlike a step of
 * history it cannot be taken back: it empties the history along with
 * the edits, because the steps in it lead back through a document that
 * is no longer the one in front of you. That is what makes it the one
 * act in Build a reader cannot recover from, and why the affordance
 * asks first. A reader who wants their edits back afterwards wanted
 * `undoAllWithSelection` below.
 */
export function discardAllEdits(
  engine: Engine,
  dispatchSelection: React.Dispatch<SelectionAction>,
): void {
  engine.discardAllEdits();
  reconcileSelection(engine, dispatchSelection);
}

/**
 * Walk the whole history back, and walk the selection with it.
 *
 * "Undo all", which is undo held down: the same act
 * `undoWithSelection` performs, repeated until the history runs out,
 * so it takes the same second step for the same reason — a history
 * move takes ids out from under the selection, and taking many at once
 * takes more of them.
 *
 * The mild half of the pair with `discardAllEdits` above. It keeps the
 * history, so every step crosses to the redo side and the author can
 * walk forward again; what it cannot promise is the document the
 * buffer was built from, because the stack is bounded and restores
 * only the fields a `DocSnapshot` carries.
 */
export function undoAllWithSelection(
  engine: Engine,
  dispatchSelection: React.Dispatch<SelectionAction>,
): void {
  engine.undoAll();
  reconcileSelection(engine, dispatchSelection);
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

/** How long a document starts out. Ten seconds is enough timeline to place a few
 *  things on without scrolling, and the panel's own length row is how it grows.
 *  `authoring/events.ts` grows it anyway for an edit that lands past the end, so
 *  this is a starting point rather than a limit. */
export const NEW_DOCUMENT_DURATION_MS = 10_000;

/**
 * An empty document to start from.
 *
 * Says nothing about itself, because a title the reader did not write is a title
 * they have to notice and delete; the panel shows the id as a placeholder until
 * they name it. There is no recording layer and no entity, so every surface reads
 * it as the empty document it is rather than as a document that failed to load.
 *
 * `id` is the one field that cannot be empty — it names the download and stands
 * in for the title until there is one.
 */
export function newDocument(id = "untitled"): TimelineDocument {
  return TimelineDocument.parse({
    id,
    duration: NEW_DOCUMENT_DURATION_MS,
    events: [],
  });
}

/**
 * What gets written when a document is saved: everything it says, with
 * `dct:modified` stamped now.
 *
 * Saving is where that field is written, and the reason it is not written as
 * edits land is that a clock in the edit path would make every keystroke differ
 * from the last: `endTransaction` compares snapshots to skip a transaction that
 * changed nothing, and a fresh timestamp would defeat it, so focusing a field and
 * leaving it would push an undo entry. Stamped here it also matches what the
 * term means, which is when this file was last written.
 *
 * Pure, and separate from the download below, so a test can read what would be
 * written without a DOM. The `now` is passed in for the same reason.
 */
export function saveStampedDoc(
  doc: TimelineDocument,
  now: string,
): TimelineDocument {
  return { ...doc, metadata: { ...doc.metadata, "dct:modified": now } };
}

/** Serialize the current doc and trigger a browser download.
 * Filename is the doc id with a `.json` suffix (slashes scrubbed
 * so the OS doesn't reject the suggested name). */
export function downloadDocAsJson(doc: TimelineDocument): void {
  const json = JSON.stringify(
    saveStampedDoc(doc, new Date().toISOString()),
    null,
    2,
  );
  const blob = new Blob([json], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement("a");
    a.href = url;
    a.download = `${doc.id.replace(/[\\/]/g, "-")}.json`;
    a.click();
  } finally {
    URL.revokeObjectURL(url);
  }
}
