/**
 * The two-click tools, over the two kinds of stage node.
 *
 * A message can name an end nothing has attributed: that is what the wire
 * looks like before anything proves who answered, and a recording holds it,
 * so Build has to be able to author it. What an end cannot do is join a
 * SECOND session — two ends claiming one address may be one host twice or an
 * impostor beside an honest one, and nothing has proved which, so a node
 * shared between sessions would be this app asserting they are the same
 * party. The node that IS shared across sessions is the peer, and attributing
 * an end is how it becomes one.
 *
 * These drive `advanceTwoClick` the way the Stage does, through the arm step
 * and then the commit, because the arm is where the picked node is parked and
 * the commit is where the session is resolved.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../engine/timeline.ts";
import { Engine } from "../engine/engine.ts";
import { authoredPeerPosition, authoredPins } from "../engine/event-helpers.ts";
import { findNode } from "../engine/world.ts";
import {
  advanceTwoClick,
  asOneEdit,
  clearAllPins,
  discardAllEdits,
  nudgeSelection,
  redoWithSelection,
  twoClickAccepts,
  undoAllWithSelection,
  undoWithSelection,
} from "./helpers.ts";
import type { AppAction } from "../state/app-state.ts";
import { selectionReducer } from "../interactions/selection-store.ts";
import {
  EMPTY_SELECTION,
  type EntityRefKey,
  type Hit,
  NO_MODIFIERS,
  type SelectionAction,
  type SelectionState,
  type ToolState,
} from "../interactions/types.ts";
import { cursorFor, type ToolWillPick } from "../interactions/cursor.ts";
import { nodeKindOf } from "../schema/topology.ts";

/** Carol holds one end of a session whose far end is a claim nobody has
 *  backed. Alice is on stage and shares no session with either. */
function looseDoc(): TimelineDocument {
  return TimelineDocument.parse({
    id: "two-click",
    duration: 10000,
    events: [
      {
        id: "p1",
        t: 0,
        kind: "peer-joined",
        peerId: "carol",
        profile: "pancake",
      },
      {
        id: "p2",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
      },
      {
        id: "so",
        t: 0,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "carol", attributedBy: "self-reported" },
        b: { designator: "127.0.0.1:9002" },
        codec: "syrup",
        captpVersion: "v1_0",
        initialState: "open",
      },
    ],
  });
}

const LOOSE_END = "s1::b";

/** Drive both clicks of the tool, parking the first pick the way the app's
 *  reducer does, and report what the document holds afterwards. */
function twoClicks(
  e: Engine,
  tool: "open-session" | "send-message",
  first: string,
  second: string,
): void {
  let parked: string | null = null;
  const dispatch = ((action: AppAction) => {
    if (action.type === "set-first-pick") parked = action.nodeId;
  }) as React.Dispatch<AppAction>;
  const noSelection = (() => {}) as React.Dispatch<SelectionAction>;
  advanceTwoClick(e, tool, null, first, dispatch, noSelection);
  assertEquals(parked, first, "the first click did not arm the node");
  advanceTwoClick(e, tool, parked, second, dispatch, noSelection);
}

function messages(e: Engine) {
  return Object.values(e.doc.entities?.messages ?? {});
}

function engineTest(name: string, fn: () => void): void {
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

engineTest("a message can be sent to an end nothing has attributed", () => {
  const e = new Engine(looseDoc());
  twoClicks(e, "send-message", "carol", LOOSE_END);
  const sent = messages(e);
  assertEquals(sent.length, 1);
  assertEquals(sent[0]!.from, "carol");
  assertEquals(sent[0]!.to, LOOSE_END);
  // On the end's own session, which is the only one it is an end of.
  assertEquals(sent[0]!.sessionId, "s1");
});

engineTest("a loose end can receive and can send", () => {
  const e = new Engine(looseDoc());
  twoClicks(e, "send-message", LOOSE_END, "carol");
  const sent = messages(e);
  assertEquals(sent.length, 1);
  assertEquals(sent[0]!.from, LOOSE_END);
  assertEquals(sent[0]!.to, "carol");
});

engineTest("a loose end carries no message off its own session", () => {
  // Alice shares no session with this end, and one cannot be opened to it, so
  // there is nowhere for the message to ride. The refusal is the engine's:
  // the auto-open is what gets turned away.
  const e = new Engine(looseDoc());
  const said: string[] = [];
  e.onError((err) => said.push(err.detail));
  twoClicks(e, "send-message", "alice", LOOSE_END);
  assertEquals(messages(e).length, 0);
  assertEquals(Object.keys(e.doc.entities?.sessions ?? {}), ["s1"]);
  // Refusing in silence is the worst shape this can take: the gesture and
  // the document both look fine afterwards and the reader learns nothing.
  assert(said.length > 0, "the refusal said nothing");
});

engineTest("a session cannot be opened onto an end nothing attributed", () => {
  const e = new Engine(looseDoc());
  twoClicks(e, "open-session", "carol", LOOSE_END);
  assertEquals(
    Object.keys(e.doc.entities?.sessions ?? {}),
    ["s1"],
    "a second session was opened onto an existing end",
  );
});

engineTest("two peers still open a session and send between them", () => {
  // The path everything above is an exception to: two peers with no session
  // between them get one, and the message rides it, in one undo step.
  const e = new Engine(looseDoc());
  twoClicks(e, "send-message", "carol", "alice");
  const sent = messages(e);
  assertEquals(sent.length, 1);
  const opened = Object.keys(e.doc.entities?.sessions ?? {});
  assertEquals(opened.length, 2, "no session was opened for the message");
  assert(
    opened.includes(sent[0]!.sessionId),
    "the message did not ride a session this document declares",
  );
});

// ─────────────────── what the second pick will take ───────────────────

function accepts(e: Engine, armed: string | null, id: string) {
  return twoClickAccepts(e, "send-message", armed, {
    kind: nodeKindOf(id),
    id,
  });
}

engineTest("with a loose end armed, only its own session's far end", () => {
  // The pointer used to read as an invitation over every node on the stage
  // while the commit refused all but one of them. An end nothing has
  // attributed can only talk on the session it is an end of, so that is the
  // only partner it has.
  const e = new Engine(looseDoc());
  assertEquals(accepts(e, LOOSE_END, "carol"), "takes");
  assertEquals(accepts(e, LOOSE_END, "alice"), "refuses");
});

engineTest("the same rule read from the other side", () => {
  const e = new Engine(looseDoc());
  assertEquals(accepts(e, "carol", LOOSE_END), "takes");
  assertEquals(accepts(e, "alice", LOOSE_END), "refuses");
});

engineTest("two peers may still pick each other with no session yet", () => {
  // The path the rule above must not break: a message between peers opens a
  // session if they need one, so any peer is a legal partner.
  const e = new Engine(looseDoc());
  assertEquals(accepts(e, "carol", "alice"), "takes");
});

engineTest("a first pick is never refused for its partner", () => {
  // Nothing is armed, so there is no partner to be wrong for; and re-picking
  // the armed node is how the gesture is cancelled.
  const e = new Engine(looseDoc());
  assertEquals(accepts(e, null, LOOSE_END), "takes");
  assertEquals(accepts(e, null, "alice"), "takes");
  assertEquals(accepts(e, LOOSE_END, LOOSE_END), "takes");
});

engineTest("Open Session refuses a loose end whatever is armed", () => {
  const e = new Engine(looseDoc());
  for (const armed of [null, "carol", "alice"]) {
    assertEquals(
      twoClickAccepts(e, "open-session", armed, {
        kind: "endpoint",
        id: LOOSE_END,
      }),
      "refuses",
    );
  }
});

// ─────────────────── what the pointer says over a node ───────────────────

/**
 * The cursor over a node, asked the way the Stage asks it: the app's one
 * cursor authority, handed the same `twoClickAccepts` the click path consults.
 * Testing anything less than `cursorFor` here would test a second function
 * that merely looks like the one shipping.
 */
function cursorOver(
  e: Engine,
  tool: "open-session" | "send-message",
  armed: string | null,
  id: string,
) {
  const willPick: ToolWillPick = ({ tool, armedNodeId, nodeId }) =>
    twoClickAccepts(e, tool, armedNodeId, {
      kind: nodeKindOf(nodeId),
      id: nodeId,
    }) === "takes";
  const hit: Hit = nodeKindOf(id) === "endpoint"
    ? { surface: "stage-endpoint", endpointId: id }
    : { surface: "stage-peer", peerId: id };
  const toolState: ToolState | null = armed === null
    ? null
    : { tool, nodeId: armed };
  return cursorFor(
    { modifiers: NO_MODIFIERS, spaceHeld: false, activeTool: tool, toolState },
    {
      fsm: { kind: "idle" },
      hover: { surface: hit.surface, hit },
      lastUp: null,
    },
    willPick,
  );
}

engineTest("the pointer refuses exactly what the click refuses", () => {
  // These drifted apart once: a node read as a target and the click then
  // declined it. Both answers come from `twoClickAccepts` now, and this is
  // the pair that has to agree — asserted against the cursor the app
  // actually draws, not a second one that merely looks like it.
  const e = new Engine(looseDoc());
  const cases: [string | null, string, "takes" | "refuses"][] = [
    [null, "alice", "takes"],
    [null, LOOSE_END, "takes"],
    [LOOSE_END, "carol", "takes"],
    [LOOSE_END, "alice", "refuses"],
    ["alice", LOOSE_END, "refuses"],
    ["carol", "alice", "takes"],
  ];
  for (const [armed, target, verdict] of cases) {
    const kind = nodeKindOf(target);
    assertEquals(
      twoClickAccepts(e, "send-message", armed, { kind, id: target }),
      verdict,
      `send-message ${armed} -> ${target}`,
    );
    assertEquals(
      cursorOver(e, "send-message", armed, target),
      // Accepted, the pointer keeps the tool's own cursor; only a refusal
      // overrides it.
      verdict === "refuses" ? "not-allowed" : "copy",
      `cursor for ${armed} -> ${target}`,
    );
  }
});

engineTest("Open Session's pointer refuses an end nothing attributed", () => {
  const e = new Engine(looseDoc());
  assertEquals(cursorOver(e, "open-session", null, LOOSE_END), "not-allowed");
  assertEquals(cursorOver(e, "open-session", null, "alice"), "cell");
});

// ─────────────────────── unpinning the whole stage ───────────────────────

/** Pin both kinds of node the stage draws: a peer, and the end nothing has
 *  attributed. `looseDoc` gives us one of each. */
function pinBoth(e: Engine): void {
  e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
  e.dispatch({
    kind: "reposition-endpoint",
    endpointId: LOOSE_END,
    position: PIN_B,
  });
}

const PIN_A = { x: 111, y: 222 };
const PIN_B = { x: 333, y: 444 };

function peerPin(e: Engine, peerId: string) {
  return authoredPeerPosition(e.doc, peerId);
}

function endPin(e: Engine) {
  return e.doc.entities?.sessions?.s1?.endpointPosition?.b ?? null;
}

engineTest("Unpin all clears both kinds of pin", () => {
  // A sweep that cleared only peers would leave the stage half-pinned while
  // telling the reader it had unpinned everything, which is the failure this
  // control exists to not have.
  const e = new Engine(looseDoc());
  pinBoth(e);
  assertEquals(peerPin(e, "carol"), PIN_A);
  assertEquals(endPin(e), PIN_B);
  clearAllPins(e);
  assertEquals(peerPin(e, "carol"), null);
  assertEquals(endPin(e), null);
});

engineTest("Unpin all is one undo step, and it restores both pins", () => {
  const e = new Engine(looseDoc());
  pinBoth(e);
  clearAllPins(e);
  assertEquals(e.nextUndoLabel, "Unpin all");
  e.undo();
  assertEquals(
    peerPin(e, "carol"),
    PIN_A,
    "one undo did not bring the peer's pin back",
  );
  assertEquals(
    endPin(e),
    PIN_B,
    "one undo did not bring the end's pin back — the sweep was more than " +
      "one transaction",
  );
});

engineTest(
  "an unpinned stage reads as unpinned, and the sweep is inert",
  () => {
    // `authoredPins` is what tells the control whether to offer itself, so a
    // count that saw a pin where the document has none would leave the button
    // live on a stage with nothing to unpin — and pressing it would spend the
    // reader's undo on a press that changed nothing.
    const e = new Engine(looseDoc());
    assertEquals(authoredPins(e.doc).size, 0);
    clearAllPins(e);
    assertEquals(e.canUndo, false);
    // ...and it wakes for either kind of pin on its own.
    e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
    assertEquals(authoredPins(e.doc).size, 1);
    e.dispatch({
      kind: "reposition-endpoint",
      endpointId: LOOSE_END,
      position: PIN_B,
    });
    assertEquals(authoredPins(e.doc).size, 2);
  },
);

engineTest("a peer pinned by its joining observation unpins too", () => {
  // A declared `entities.peers` entry wins over the event payload outright
  // (`TimelineDocument`'s transform never merges the two), so a document
  // that declares a peer AND records it joining somewhere else keeps its
  // only pin on the observation. `authoredPeerPosition` reads the
  // definition first and the observation second for exactly that shape, and
  // the sweep has to see the same pin the Inspector shows.
  const e = new Engine(TimelineDocument.parse({
    id: "joined-pin",
    duration: 10000,
    entities: { peers: { carol: { profile: "pancake" } } },
    events: [{
      id: "p1",
      t: 0,
      kind: "peer-joined",
      peerId: "carol",
      profile: "pancake",
      position: PIN_A,
    }],
  }));
  assertEquals(e.doc.entities?.peers?.carol?.position, undefined);
  assertEquals(peerPin(e, "carol"), PIN_A);
  clearAllPins(e);
  assertEquals(peerPin(e, "carol"), null);
});

// ─────────────────────── nudging the selection ───────────────────────

/** Where the stage is holding a node right now, copied out of the world so a
 *  later write cannot move the value under the assertion. */
function nodeAt(e: Engine, id: string): { x: number; y: number } {
  const at = findNode(e.world, id)?.position;
  assert(at, `the stage is not holding ${id}`);
  return { x: at.x, y: at.y };
}

engineTest("an arrow key moves an end nothing has attributed", () => {
  // The end is draggable on the stage, so it is nudgeable too: an entity a
  // reader can move one way and not the other is the interaction model
  // saying two different things about one node.
  const e = new Engine(looseDoc());
  const at = nodeAt(e, LOOSE_END);
  assert(nudgeSelection(e, new Set([`endpoint:${LOOSE_END}`]), {
    dx: 1,
    dy: -1,
  }));
  assertEquals(endPin(e), { x: at.x + 1, y: at.y - 1 });
});

engineTest("a nudge is one undo step, named for what it moved", () => {
  // The session in the selection is drawn between its two ends and has no
  // place of its own, so the label counts the two nodes that moved rather
  // than the three things selected.
  const e = new Engine(looseDoc());
  const carolAt = nodeAt(e, "carol");
  const endAt = nodeAt(e, LOOSE_END);
  const selection = new Set<EntityRefKey>([
    "peer:carol",
    `endpoint:${LOOSE_END}`,
    "session:s1",
  ]);
  assert(nudgeSelection(e, selection, { dx: 4, dy: 0 }));
  assertEquals(e.nextUndoLabel, "Nudge 1 peer and 1 session end");
  assertEquals(peerPin(e, "carol"), { x: carolAt.x + 4, y: carolAt.y });
  assertEquals(endPin(e), { x: endAt.x + 4, y: endAt.y });
  e.undo();
  assertEquals(peerPin(e, "carol"), null);
  assertEquals(endPin(e), null);
});

engineTest("a nudge that moves nothing hands the keystroke back", () => {
  // Which is what lets an arrow over a selection of sessions go on scrubbing
  // time instead of being swallowed by a move that never happened.
  const e = new Engine(looseDoc());
  assertEquals(
    nudgeSelection(e, new Set<EntityRefKey>(["session:s1"]), { dx: 1, dy: 0 }),
    false,
  );
  assertEquals(e.canUndo, false, "a nudge that moved nothing spent a step");
});

// ─────────────────── taking history back, selection and all ───────────

/** The selection store, driven the way the App drives it. */
function selectionHost(initial: Partial<SelectionState>) {
  let state: SelectionState = { ...EMPTY_SELECTION, ...initial };
  return {
    dispatch: (action: SelectionAction) => {
      state = selectionReducer(state, action);
    },
    get state(): SelectionState {
      return state;
    },
  };
}

engineTest("undo takes a rename back, and the selection lets go", () => {
  // The rename re-anchors the selection forward, so undo has to walk it
  // back. Left alone, the Inspector goes on pointing at a name the document
  // no longer answers to and reads out an unknown peer.
  const e = new Engine(looseDoc());
  const host = selectionHost({
    anchor: { kind: "peer", id: "carol" },
    selection: new Set<EntityRefKey>(["peer:carol"]),
  });
  e.dispatch({ kind: "rename-peer", oldId: "carol", newId: "caroline" });
  host.dispatch({
    kind: "rename-entity",
    entityKind: "peer",
    oldId: "carol",
    newId: "caroline",
  });
  assert(host.state.selection.has("peer:caroline"));

  undoWithSelection(e, host.dispatch);
  assert(e.doc.entities?.peers?.carol, "undo did not restore the old name");
  assertEquals(
    host.state.selection.has("peer:caroline"),
    false,
    "the selection still names a peer the document lost",
  );
  assertEquals(host.state.anchor, null);
});

engineTest("a peer an author added survives a step of history", () => {
  // An added peer is declared among the document's entities and mentioned by
  // no observation at all, so asking the observation stream whether the
  // document still holds it answers no — and clears the reader's selection
  // on the next Cmd-Z. The identity map is what answers this.
  const e = new Engine(looseDoc());
  const added = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 10, y: 10 },
  });
  assert(added);
  const key: EntityRefKey = `peer:${added}`;
  e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
  const host = selectionHost({
    anchor: { kind: "peer", id: added },
    selection: new Set<EntityRefKey>([key]),
  });

  undoWithSelection(e, host.dispatch);
  assertEquals(peerPin(e, "carol"), null, "the undo took back nothing");
  assert(host.state.selection.has(key), "the added peer lost its selection");
  assertEquals(host.state.anchor?.id, added);
});

engineTest("redo drops what going forward takes away", () => {
  // Redo moves ids under the selection exactly as undo does, so it walks the
  // selection the same way.
  const e = new Engine(looseDoc());
  e.dispatch({ kind: "delete-peer", peerId: "alice" });
  const host = selectionHost({});
  undoWithSelection(e, host.dispatch);
  assert(e.doc.entities?.peers?.alice, "undo did not bring the peer back");
  host.dispatch({
    kind: "set-selection",
    entities: new Set<EntityRefKey>(["peer:alice"]),
  });

  redoWithSelection(e, host.dispatch);
  assertEquals(host.state.selection.size, 0);
  assertEquals(host.state.anchor, null);
});

engineTest("a discard drops the selection it took the entities from", () => {
  // The strongest case of what undo does one step at a time: a discard
  // takes back every id an edit ever minted at once, so a selection
  // naming a peer the author added is left pointing at nothing.
  const e = new Engine(looseDoc());
  const added = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 10, y: 10 },
  });
  assert(added);
  const key: EntityRefKey = `peer:${added}`;
  const host = selectionHost({
    anchor: { kind: "peer", id: added },
    selection: new Set<EntityRefKey>([key]),
  });

  discardAllEdits(e, host.dispatch);
  assertEquals(
    e.doc.entities?.peers?.[added],
    undefined,
    "the discard left the added peer in the document",
  );
  assertEquals(
    host.state.selection.has(key),
    false,
    "the selection still names a peer the discard took away",
  );
  assertEquals(host.state.anchor, null);
});

engineTest("undo all walks the selection back the way undo does", () => {
  // The same act, repeated, so it takes the same second step: the
  // history move that takes an added peer away has to take the
  // selection naming it away too.
  const e = new Engine(looseDoc());
  const added = e.dispatch({
    kind: "add-peer",
    profile: "pancake",
    position: { x: 10, y: 10 },
  });
  assert(added);
  const key: EntityRefKey = `peer:${added}`;
  const host = selectionHost({
    anchor: { kind: "peer", id: added },
    selection: new Set<EntityRefKey>([key]),
  });

  undoAllWithSelection(e, host.dispatch);
  assertEquals(e.doc.entities?.peers?.[added], undefined);
  assertEquals(
    host.state.selection.has(key),
    false,
    "the selection still names a peer undo all took away",
  );
  // Unlike the discard, the way forward is still there.
  assert(e.canRedo, "undo all left no way forward");
});

engineTest("a discard with nothing to discard leaves the selection", () => {
  // The mirror of the case above, and the one a reader meets more
  // often: the command is inert, so nothing runs, and a selection made
  // while looking around is not disturbed by pressing it.
  const e = new Engine(looseDoc());
  const host = selectionHost({
    anchor: { kind: "peer", id: "alice" },
    selection: new Set<EntityRefKey>(["peer:alice"]),
  });

  discardAllEdits(e, host.dispatch);
  assert(host.state.selection.has("peer:alice"));
  assertEquals(host.state.anchor?.id, "alice");
  assertEquals(e.canUndo, false, "the refused discard spent a step");
});

// ─────────────── one gesture, one undo step, every way out ───────────────

engineTest("a run that throws still closes its undo step", () => {
  // The transaction depth is app-wide state: the engine records
  // history only at depth zero, so a run that opens one and escapes
  // without closing it does not merely lose its own step. It swallows
  // every dispatch after it, and from then on nothing in the app is
  // undoable, with nothing said.
  const e = new Engine(looseDoc());
  const before = e.canUndo;
  let escaped: unknown = null;
  try {
    asOneEdit(e, "Delete 2 peers", () => {
      e.dispatch({ kind: "delete-peer", peerId: "alice" });
      throw new Error("a bad key, halfway through the selection");
    });
  } catch (err) {
    escaped = err;
  }
  assert(escaped instanceof Error, "the throw was swallowed, not surfaced");
  // The proof that depth came back to zero: a later, unrelated edit
  // records a step of its own instead of vanishing into the open one.
  e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
  assert(e.canUndo && !before, "the later edit landed in nobody's history");
  assertEquals(e.nextUndoLabel, "Move peer");
});

engineTest("a run that returns records one step for the whole run", () => {
  const e = new Engine(looseDoc());
  asOneEdit(e, "Unpin all", () => {
    e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
    e.dispatch({ kind: "reposition-peer", peerId: "alice", position: PIN_A });
  });
  assertEquals(e.nextUndoLabel, "Unpin all");
  undoWithSelection(e, selectionHost({}).dispatch);
  assertEquals(peerPin(e, "carol"), null, "the step took back only half");
  assertEquals(peerPin(e, "alice"), null, "the step took back only half");
});
