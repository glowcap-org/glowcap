import { assert, assertEquals } from "@std/assert";
import {
  hasAnySelection,
  selectionActionFor,
  selectionReducer,
  selectionRefs,
} from "./selection-store.ts";
import {
  EMPTY_SELECTION,
  entityKey,
  type EntityRef,
  type EntityRefKey,
  type SelectionAction,
  type SelectionDocSnapshot,
  type SelectionState,
} from "./types.ts";

function withState(over: Partial<SelectionState>): SelectionState {
  return { ...EMPTY_SELECTION, ...over };
}

function dispatch(
  state: SelectionState,
  actions: SelectionAction[],
): SelectionState {
  return actions.reduce(selectionReducer, state);
}

const docABC: SelectionDocSnapshot = {
  duration: 10_000,
  // Three peers, one session between two of them, one message on it.
  // The identities are what says the document holds them; the stream
  // below is when each of them happened.
  entities: {
    peers: { alice: {}, bob: {}, carol: {} },
    sessions: { ab: {} },
    messages: { m1: {} },
  },
  observations: [
    { id: "ea", t: 0, kind: "peer-joined", peerId: "alice" },
    { id: "eb", t: 100, kind: "peer-joined", peerId: "bob" },
    { id: "ec", t: 200, kind: "peer-joined", peerId: "carol" },
    {
      id: "es",
      t: 300,
      kind: "session-opened",
      sessionId: "ab",
      a: { peer: "alice" },
      b: { peer: "bob" },
    },
    {
      id: "em",
      t: 400,
      kind: "message-sent",
      messageId: "m1",
      sessionId: "ab",
      from: "alice",
      to: "bob",
      arrivalT: 500,
    },
  ],
};

const peerA: EntityRef = { kind: "peer", id: "alice" };
const peerB: EntityRef = { kind: "peer", id: "bob" };
const peerC: EntityRef = { kind: "peer", id: "carol" };

// ─────────────────────── timeRange ────────────────────────────────────

Deno.test("set-time-range writes timeRange only", () => {
  const r = selectionReducer(EMPTY_SELECTION, {
    kind: "set-time-range",
    range: { start: 100, end: 500 },
  });
  assertEquals(r.timeRange, { start: 100, end: 500 });
  assertEquals(r.anchor, null);
  assertEquals(r.selection.size, 0);
});

Deno.test("I1: set-time-range normalizes start ≤ end", () => {
  const r = selectionReducer(EMPTY_SELECTION, {
    kind: "set-time-range",
    range: { start: 500, end: 100 },
  });
  assertEquals(r.timeRange, { start: 100, end: 500 });
});

Deno.test("extend-time-range from null creates point range", () => {
  const r = selectionReducer(EMPTY_SELECTION, {
    kind: "extend-time-range",
    t: 250,
  });
  assertEquals(r.timeRange, { start: 250, end: 250 });
});

Deno.test("extend-time-range moves the nearest edge to t", () => {
  const state = withState({ timeRange: { start: 100, end: 500 } });
  const r1 = selectionReducer(state, { kind: "extend-time-range", t: 120 });
  assertEquals(r1.timeRange, { start: 120, end: 500 });
  const r2 = selectionReducer(state, { kind: "extend-time-range", t: 480 });
  assertEquals(r2.timeRange, { start: 100, end: 480 });
});

Deno.test("expand-time-range grows by deltaMs on each side", () => {
  const state = withState({ timeRange: { start: 100, end: 500 } });
  const r = selectionReducer(state, {
    kind: "expand-time-range",
    deltaMs: 50,
  });
  assertEquals(r.timeRange, { start: 50, end: 550 });
});

Deno.test("shrink-time-range-to-events tightens to event extents", () => {
  const state = withState({
    timeRange: { start: 0, end: 10_000 },
    selection: new Set([entityKey(peerA), entityKey(peerB)]),
  });
  const r = selectionReducer(state, {
    kind: "shrink-time-range-to-events",
    doc: docABC,
  });
  assertEquals(r.timeRange, { start: 0, end: 100 });
});

// ─────────────────────── anchor ───────────────────────────────────────

Deno.test("set-anchor writes only anchor", () => {
  const r = selectionReducer(EMPTY_SELECTION, {
    kind: "set-anchor",
    entity: peerA,
  });
  assertEquals(r.anchor, peerA);
  assertEquals(r.timeRange, null);
  assertEquals(r.selection.size, 0);
});

// ─────────────────────── selection (the set) ──────────────────────────

Deno.test("toggle-in-selection adds and removes a single entity", () => {
  const s1 = selectionReducer(EMPTY_SELECTION, {
    kind: "toggle-in-selection",
    entity: peerA,
  });
  assertEquals(s1.selection.size, 1);
  assert(s1.selection.has(entityKey(peerA)));
  // Toggle-add seats anchor on the toggled entity.
  assertEquals(s1.anchor, peerA);
  const s2 = selectionReducer(s1, {
    kind: "toggle-in-selection",
    entity: peerA,
  });
  assertEquals(s2.selection.size, 0);
  // Removing the only / last member re-seats anchor to null.
  assertEquals(s2.anchor, null);
});

Deno.test("set-selection replaces and returns a NEW Set (I4); anchor follows last", () => {
  const initial = new Set([entityKey(peerA)]);
  const state = withState({ selection: initial, anchor: peerA });
  const r = selectionReducer(state, {
    kind: "set-selection",
    entities: new Set([entityKey(peerB), entityKey(peerC)]),
  });
  assert(r.selection !== initial);
  assertEquals(r.selection.size, 2);
  assert(r.selection.has(entityKey(peerB)));
  assert(r.selection.has(entityKey(peerC)));
  // Anchor follows the last entity in the new set (Adobe convention).
  assertEquals(r.anchor, peerC);
});

Deno.test("add-to-selection unions and updates anchor to last added", () => {
  const state = withState({
    selection: new Set([entityKey(peerA)]),
    anchor: peerA,
  });
  const r = selectionReducer(state, {
    kind: "add-to-selection",
    entities: new Set([entityKey(peerB), entityKey(peerC)]),
  });
  assertEquals(r.selection.size, 3);
  assertEquals(r.anchor, peerC);
});

Deno.test("add-to-selection with empty set is identity", () => {
  const state = withState({
    selection: new Set([entityKey(peerA)]),
    anchor: peerA,
  });
  const r = selectionReducer(state, {
    kind: "add-to-selection",
    entities: new Set(),
  });
  assertEquals(r, state);
});

Deno.test("remove-from-selection drops keys; re-seats anchor when anchor removed", () => {
  const state = withState({
    selection: new Set([entityKey(peerA), entityKey(peerB), entityKey(peerC)]),
    anchor: peerB,
  });
  const r = selectionReducer(state, {
    kind: "remove-from-selection",
    entities: new Set([entityKey(peerB)]),
  });
  assertEquals(r.selection.size, 2);
  assert(!r.selection.has(entityKey(peerB)));
  // Anchor was peerB; got removed → re-seated to any surviving member.
  assert(r.anchor !== null && r.selection.has(entityKey(r.anchor)));
});

Deno.test("extend-selection-range adds entities between anchor and target by doc order", () => {
  const state = withState({
    anchor: peerA,
    selection: new Set([entityKey(peerA)]),
  });
  const r = selectionReducer(state, {
    kind: "extend-selection-range",
    toEntity: peerC,
    doc: docABC,
  });
  assertEquals(r.selection.size, 3);
  assert(r.selection.has(entityKey(peerA)));
  assert(r.selection.has(entityKey(peerB)));
  assert(r.selection.has(entityKey(peerC)));
  // Anchor moves to the new target.
  assertEquals(r.anchor, peerC);
});

Deno.test("extend-selection-range without anchor just adds toEntity", () => {
  const r = selectionReducer(EMPTY_SELECTION, {
    kind: "extend-selection-range",
    toEntity: peerB,
    doc: docABC,
  });
  assertEquals(r.selection.size, 1);
  assert(r.selection.has(entityKey(peerB)));
});

Deno.test("set-selection-from-time-range writes selection from timeRange + doc", () => {
  const state = withState({ timeRange: { start: 0, end: 200 } });
  const r = selectionReducer(state, {
    kind: "set-selection-from-time-range",
    doc: docABC,
  });
  assertEquals(r.selection.size, 3);
});

// ─────────────────────── rename-entity ──────────────────────────────

Deno.test("rename-entity rewrites selection key in place", () => {
  const state = withState({
    selection: new Set([entityKey(peerA), entityKey(peerB)]),
    anchor: peerA,
  });
  const r = selectionReducer(state, {
    kind: "rename-entity",
    entityKind: "peer",
    oldId: "alice",
    newId: "alice2",
  });
  assertEquals(r.selection.size, 2);
  assert(r.selection.has("peer:alice2"));
  assert(!r.selection.has("peer:alice"));
  assert(r.selection.has(entityKey(peerB)));
  // Anchor was renamed entity → moves to new id.
  assertEquals(r.anchor, { kind: "peer", id: "alice2" });
});

Deno.test("rename-entity does NOT stomp anchor when anchor is a different entity", () => {
  // Regression: previous flow dispatched `set-selection` after
  // delete+add, which set anchor = lastOrNull(next) = newKey,
  // silently moving the anchor away from the user's intent.
  const state = withState({
    selection: new Set([entityKey(peerA), entityKey(peerB)]),
    anchor: peerB,
  });
  const r = selectionReducer(state, {
    kind: "rename-entity",
    entityKind: "peer",
    oldId: "alice",
    newId: "alice2",
  });
  assertEquals(r.selection.size, 2);
  assert(r.selection.has("peer:alice2"));
  assert(r.selection.has(entityKey(peerB)));
  // Anchor was bob; rename of alice must not move it.
  assertEquals(r.anchor, peerB);
});

Deno.test("rename-entity is a no-op when entity isn't selected or anchored", () => {
  const state = withState({
    selection: new Set([entityKey(peerB)]),
    anchor: peerB,
  });
  const r = selectionReducer(state, {
    kind: "rename-entity",
    entityKind: "peer",
    oldId: "alice",
    newId: "alice2",
  });
  // Identity preserved — paint bail relies on it.
  assertEquals(r, state);
});

Deno.test("rename-entity moves anchor when anchor is the renamed entity but not in selection", () => {
  // Anchor without selection-membership shouldn't happen in the
  // normal flow (anchor invariant says anchor ∈ selection or
  // anchor null), but the reducer is defensive.
  const state = withState({
    selection: new Set(),
    anchor: peerA,
  });
  const r = selectionReducer(state, {
    kind: "rename-entity",
    entityKind: "peer",
    oldId: "alice",
    newId: "alice2",
  });
  assertEquals(r.selection.size, 0);
  assertEquals(r.anchor, { kind: "peer", id: "alice2" });
});

Deno.test("invert-selection flips membership against doc entities", () => {
  const state = withState({
    selection: new Set([entityKey(peerA)]),
  });
  const r = selectionReducer(state, {
    kind: "invert-selection",
    doc: docABC,
  });
  // docABC has 5 entities: 3 peers + 1 session + 1 message.
  // peerA was in; 4 others come out.
  assertEquals(r.selection.size, 4);
  assert(!r.selection.has(entityKey(peerA)));
});

// ─────────────────────── Cross-slot bridges ───────────────────────────

Deno.test("clear-all empties every slot", () => {
  const state = withState({
    timeRange: { start: 0, end: 100 },
    anchor: peerA,
    selection: new Set([entityKey(peerB)]),
  });
  const r = selectionReducer(state, { kind: "clear-all" });
  assertEquals(r, EMPTY_SELECTION);
});

Deno.test("clear-on-empty-click 'stage' clears anchor + selection, keeps timeRange", () => {
  const state = withState({
    timeRange: { start: 0, end: 100 },
    anchor: peerA,
    selection: new Set([entityKey(peerB)]),
  });
  const r = selectionReducer(state, {
    kind: "clear-on-empty-click",
    surface: "stage",
  });
  assertEquals(r.timeRange, { start: 0, end: 100 });
  assertEquals(r.anchor, null);
  assertEquals(r.selection.size, 0);
});

Deno.test("clear-on-empty-click 'timeline' clears timeRange + selection, keeps anchor", () => {
  const state = withState({
    timeRange: { start: 0, end: 100 },
    anchor: peerA,
    selection: new Set([entityKey(peerB)]),
  });
  const r = selectionReducer(state, {
    kind: "clear-on-empty-click",
    surface: "timeline",
  });
  assertEquals(r.timeRange, null);
  assertEquals(r.anchor, peerA);
  assertEquals(r.selection.size, 0);
});

// ─────────────────────── Helpers ──────────────────────────────────────

Deno.test("selectionRefs decodes back to typed refs", () => {
  const state = withState({
    selection: new Set([entityKey(peerA), entityKey(peerB)]),
  });
  const refs = selectionRefs(state);
  assertEquals(refs.length, 2);
  assert(refs.some((r) => r.kind === "peer" && r.id === "alice"));
});

Deno.test("hasAnySelection true if any slot is non-empty", () => {
  assertEquals(hasAnySelection(EMPTY_SELECTION), false);
  assertEquals(
    hasAnySelection(withState({ anchor: peerA })),
    true,
  );
  assertEquals(
    hasAnySelection(withState({ timeRange: { start: 0, end: 1 } })),
    true,
  );
});

// ─────────────────────── I4 reference identity property ───────────────

Deno.test("I4: every write to selection produces a new Set instance", () => {
  let state: SelectionState = withState({
    selection: new Set([entityKey(peerA)]),
    anchor: peerA,
  });
  const initial = state.selection;
  const actions: SelectionAction[] = [
    { kind: "toggle-in-selection", entity: peerB },
    { kind: "extend-selection-range", toEntity: peerC, doc: docABC },
    { kind: "set-selection", entities: new Set([entityKey(peerA)]) },
    { kind: "set-selection-from-time-range", doc: docABC },
    { kind: "invert-selection", doc: docABC },
  ];
  for (const a of actions) {
    const prev = state.selection;
    state = dispatch(state, [a]);
    assert(
      state.selection !== prev,
      `action ${a.kind} did not produce a new Set`,
    );
  }
  assertEquals(initial.size, 1);
});

// ── selectionActionFor: the one select-mode interpreter ──────────

Deno.test("selectionActionFor maps each mode to its store verb", () => {
  const hits = new Set<EntityRefKey>(["peer:a"]);
  assertEquals(selectionActionFor("replace", hits, "stage"), {
    kind: "set-selection",
    entities: hits,
  });
  assertEquals(selectionActionFor("add", hits, "timeline"), {
    kind: "add-to-selection",
    entities: hits,
  });
  assertEquals(selectionActionFor("remove", hits, "stage"), {
    kind: "remove-from-selection",
    entities: hits,
  });
});

Deno.test("selectionActionFor: empty hits — replace clears per surface, modifiers preserve", () => {
  assertEquals(
    selectionActionFor("replace", new Set(), "stage"),
    { kind: "clear-on-empty-click", surface: "stage" },
  );
  assertEquals(
    selectionActionFor("replace", new Set(), "timeline"),
    { kind: "clear-on-empty-click", surface: "timeline" },
  );
  assertEquals(selectionActionFor("add", new Set(), "stage"), null);
  assertEquals(selectionActionFor("remove", new Set(), "timeline"), null);
});

// ─────────────────────── reconcile-with-doc ──────────────────────────

Deno.test("reconcile-with-doc drops what the document no longer holds", () => {
  const state = withState({
    selection: new Set<EntityRefKey>([entityKey(peerA), "peer:ghost"]),
    anchor: peerA,
  });
  const r = selectionReducer(state, {
    kind: "reconcile-with-doc",
    doc: docABC,
  });
  assertEquals(r.selection.size, 1);
  assert(r.selection.has(entityKey(peerA)));
  assertEquals(r.anchor, peerA);
});

Deno.test("reconcile-with-doc clears an anchor nothing answers to", () => {
  const state = withState({
    selection: new Set<EntityRefKey>(),
    anchor: { kind: "peer", id: "renamed-away" },
  });
  const r = selectionReducer(state, {
    kind: "reconcile-with-doc",
    doc: docABC,
  });
  assertEquals(r.anchor, null);
});

Deno.test("reconcile-with-doc returns the same state when nothing was lost", () => {
  const state = withState({
    selection: new Set([entityKey(peerA), entityKey(peerB)]),
    anchor: peerB,
  });
  assertEquals(
    selectionReducer(state, { kind: "reconcile-with-doc", doc: docABC }),
    state,
  );
});
