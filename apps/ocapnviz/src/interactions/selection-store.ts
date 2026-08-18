/**
 * Selection store — implements § 6 of the interaction model.
 *
 * Pure reducer over the three slots:
 *   - `timeRange`: sim-time interval (scrubber / range overlay)
 *   - `anchor`: range-extension pivot AND Inspector follow target
 *   - `selection`: THE set of selected entities (size 0+)
 *
 * Vocabulary note: a selection is the selection. There is no "multi"
 * — a selection of size 1 is still the selection. Actions are
 * `set-selection`, `add-to-selection`, `remove-from-selection`,
 * `toggle-in-selection`, `extend-selection-range`. Property edits,
 * group delete, group drag, group nudge all operate on this set.
 *
 * Each action writes a single slot unless it's a named cross-slot
 * bridge (clear-all, clear-on-empty-click).
 */

import { parseEndpointStageId } from "../schema/session-end.ts";
import {
  type DeclaredEntities,
  EMPTY_SELECTION,
  entityKey,
  type EntityRef,
  type EntityRefKey,
  parseEntityKey,
  type SelectionAction,
  type SelectionDocSnapshot,
  type SelectionState,
  type SelectMode,
  type TimeRange,
} from "./types.ts";

/** The one interpretation of a modifier select-mode against the
 * selection: which store action a surface's gesture becomes. Every
 * selecting surface (stage click, stage marquee, timeline pill,
 * timeline marquee) forwards `(mode, hits)` here instead of
 * spelling its own set arithmetic. An empty hit set is the
 * empty-space gesture: plain replace clears (with the surface's
 * own clear semantics), a modifier gesture preserves the selection
 * (null = dispatch nothing). */
export function selectionActionFor(
  mode: SelectMode,
  entities: ReadonlySet<EntityRefKey>,
  emptySurface: "stage" | "timeline",
): SelectionAction | null {
  if (entities.size === 0) {
    return mode === "replace" ? { kind: "clear-on-empty-click", surface: emptySurface } : null;
  }
  switch (mode) {
    case "add":
      return { kind: "add-to-selection", entities };
    case "remove":
      return { kind: "remove-from-selection", entities };
    case "replace":
      return { kind: "set-selection", entities };
  }
}

// ─────────────────────── Reducer ──────────────────────────────────────

export function selectionReducer(
  state: SelectionState,
  action: SelectionAction,
): SelectionState {
  switch (action.kind) {
    case "set-time-range":
      return { ...state, timeRange: normalizeRange(action.range) };
    case "extend-time-range":
      return {
        ...state,
        timeRange: extendRange(state.timeRange, action.t),
      };
    case "expand-time-range":
      return {
        ...state,
        timeRange: state.timeRange
          ? normalizeRange({
            start: state.timeRange.start - action.deltaMs,
            end: state.timeRange.end + action.deltaMs,
          })
          : null,
      };
    case "shrink-time-range-to-events":
      return {
        ...state,
        timeRange: shrinkToEvents(state.selection, action.doc) ??
          state.timeRange,
      };
    case "set-anchor":
      return { ...state, anchor: action.entity };
    case "set-selection":
      // Always return a NEW Set (I4 — paint bail relies on identity).
      // Anchor follows the LAST entity added (Adobe convention:
      // single-click on something makes it the Inspector focus).
      return {
        ...state,
        selection: new Set(action.entities),
        anchor: lastOrNull(action.entities),
      };
    case "add-to-selection": {
      if (action.entities.size === 0) return state;
      const next = new Set(state.selection);
      for (const k of action.entities) next.add(k);
      return {
        ...state,
        selection: next,
        anchor: lastOrNull(action.entities) ?? state.anchor,
      };
    }
    case "remove-from-selection": {
      if (action.entities.size === 0) return state;
      const next = new Set(state.selection);
      for (const k of action.entities) next.delete(k);
      // Anchor invariant: anchor must be IN the selection (or null
      // when selection is empty).
      const anchorKey = state.anchor ? entityKey(state.anchor) : null;
      const anchor = anchorKey && next.has(anchorKey) ? state.anchor : firstOrNull(next);
      return { ...state, selection: next, anchor };
    }
    case "toggle-in-selection": {
      const key = entityKey(action.entity);
      const next = new Set(state.selection);
      if (next.has(key)) {
        next.delete(key);
        const anchor = state.anchor &&
            entityKey(state.anchor) === key
          ? firstOrNull(next)
          : state.anchor;
        return { ...state, selection: next, anchor };
      }
      next.add(key);
      return { ...state, selection: next, anchor: action.entity };
    }
    case "extend-selection-range":
      return {
        ...state,
        selection: extendByDocOrder(
          state.selection,
          state.anchor,
          action.toEntity,
          action.doc,
        ),
        anchor: action.toEntity,
      };
    case "invert-selection":
      return {
        ...state,
        selection: invertSelection(state.selection, action.doc),
        anchor: null,
      };
    case "reconcile-with-doc": {
      const kept = new Set<EntityRefKey>();
      for (const k of state.selection) {
        if (documentHolds(action.doc.entities, parseEntityKey(k))) kept.add(k);
      }
      const anchorGone = state.anchor !== null &&
        !documentHolds(action.doc.entities, state.anchor);
      // Same object back when nothing was lost, so a reconcile that
      // finds everything in place cannot cause a render.
      if (kept.size === state.selection.size && !anchorGone) return state;
      return {
        ...state,
        selection: kept,
        anchor: anchorGone ? null : state.anchor,
      };
    }
    case "rename-entity": {
      // Surgical id rewrite: the renamed entity stays in the same
      // slot it was in, anchor only moves if it was the renamed
      // entity. Going through `set-selection` here would stomp the
      // anchor (it always sets `anchor = lastOrNull(entities)`).
      const oldKey: EntityRefKey = `${action.entityKind}:${action.oldId}` as EntityRefKey;
      const newKey: EntityRefKey = `${action.entityKind}:${action.newId}` as EntityRefKey;
      const inSelection = state.selection.has(oldKey);
      const isAnchor = state.anchor?.kind === action.entityKind &&
        state.anchor.id === action.oldId;
      if (!inSelection && !isAnchor) return state;
      let nextSelection: ReadonlySet<EntityRefKey> = state.selection;
      if (inSelection) {
        const next = new Set(state.selection);
        next.delete(oldKey);
        next.add(newKey);
        nextSelection = next;
      }
      const nextAnchor: EntityRef | null = isAnchor ? { kind: action.entityKind, id: action.newId } : state.anchor;
      return { ...state, selection: nextSelection, anchor: nextAnchor };
    }
    case "set-selection-from-time-range":
      return {
        ...state,
        selection: entitiesInRange(state.timeRange, action.doc),
      };
    case "clear-all":
      return EMPTY_SELECTION;
    case "clear-on-empty-click":
      return action.surface === "stage"
        ? { ...state, anchor: null, selection: new Set() }
        : { ...state, timeRange: null, selection: new Set() };
    default:
      return assertNever(action);
  }
}

// ─────────────────────── Helpers ──────────────────────────────────────

function normalizeRange(range: TimeRange | null): TimeRange | null {
  if (!range) return null;
  // I1: start ≤ end always. Swap if user dragged right-to-left.
  if (range.start <= range.end) return range;
  return { start: range.end, end: range.start };
}

function extendRange(
  current: TimeRange | null,
  t: number,
): TimeRange {
  if (!current) return { start: t, end: t };
  // Shift-click extends the NEAREST edge to t.
  const distStart = Math.abs(t - current.start);
  const distEnd = Math.abs(t - current.end);
  return distStart < distEnd
    ? normalizeRange({ start: t, end: current.end })!
    : normalizeRange({ start: current.start, end: t })!;
}

/** Last item of an iterable (or null when empty). Used to pick the
 *  anchor after a `set-selection` or `add-to-selection`: whoever
 *  was added last becomes the new range-extension pivot. */
function lastOrNull(
  entities: ReadonlySet<EntityRefKey>,
): EntityRef | null {
  let last: EntityRefKey | null = null;
  for (const k of entities) last = k;
  return last ? parseEntityKey(last) : null;
}

/** First item of an iterable (or null when empty). Used to re-seat
 *  the anchor when the previous anchor was removed from the
 *  selection — pick any surviving member so range-extend still has
 *  a pivot. */
function firstOrNull(
  entities: ReadonlySet<EntityRefKey>,
): EntityRef | null {
  for (const k of entities) return parseEntityKey(k);
  return null;
}

/** Walk `doc.observations` in iteration order, find the index of
 *  the anchor and toEntity, and add every entity between them
 *  (inclusive) to the set. If no anchor is set, falls back to a
 *  plain add. */
function extendByDocOrder(
  current: ReadonlySet<EntityRefKey>,
  anchor: EntityRef | null,
  toEntity: EntityRef,
  doc: SelectionDocSnapshot,
): ReadonlySet<EntityRefKey> {
  const next = new Set(current);
  if (!anchor) {
    next.add(entityKey(toEntity));
    return next;
  }
  const ordering = entityOrderFromDoc(doc);
  const anchorIdx = ordering.indexOf(entityKey(anchor));
  const toIdx = ordering.indexOf(entityKey(toEntity));
  if (anchorIdx === -1 || toIdx === -1) {
    next.add(entityKey(toEntity));
    return next;
  }
  const lo = Math.min(anchorIdx, toIdx);
  const hi = Math.max(anchorIdx, toIdx);
  for (let i = lo; i <= hi; i++) {
    next.add(ordering[i]!);
  }
  return next;
}

/** Whether the document still declares this entity.
 *
 *  Exported because two things need it and it must be one answer: the reducer's
 *  `reconcile-with-doc`, which drops a selection the document no longer holds, and
 *  the Inspector, which will not draw a panel for an entity the buffer in front of
 *  the reader has never heard of (`ui/Sidebar.tsx`).
 *
 *  The question is asked of `doc.entities`, which is where a document's
 *  identities live, and not of the observation stream. An entity can be
 *  declared with no observation at all — that is what every peer an
 *  author adds in Build looks like — so a walk over the stream would
 *  report a live peer as gone and take the selection with it.
 *
 *  A session end has no identity of its own: it is one end of one
 *  session and it dies with that session, so it is held exactly while
 *  its session is. `parseEndpointStageId` is what reads the session
 *  back out of the end's stage id, because the spelling of that id has
 *  one home. */
export function documentHolds(
  entities: DeclaredEntities,
  ref: EntityRef,
): boolean {
  switch (ref.kind) {
    case "peer":
      return entities?.peers?.[ref.id] !== undefined;
    case "session":
      return entities?.sessions?.[ref.id] !== undefined;
    case "message":
      return entities?.messages?.[ref.id] !== undefined;
    case "endpoint": {
      const at = parseEndpointStageId(ref.id);
      if (at === undefined) return false;
      return entities?.sessions?.[at.sessionId] !== undefined;
    }
  }
}

/** Compute the entity-iteration order: the order in which entities
 *  first appear in the observation stream. Stable as long as
 *  `doc.observations` iteration order is stable. */
function entityOrderFromDoc(doc: SelectionDocSnapshot): EntityRefKey[] {
  const seen = new Set<EntityRefKey>();
  const ordering: EntityRefKey[] = [];
  for (const ev of doc.observations) {
    const refs = entityRefsOf(ev);
    for (const ref of refs) {
      const k = entityKey(ref);
      if (!seen.has(k)) {
        seen.add(k);
        ordering.push(k);
      }
    }
  }
  return ordering;
}

/** Extract the entity refs an event mentions. Mirrors the engine's
 *  event taxonomy without importing the engine module (kept pure
 *  via the structural shim in `types.ts`). */
function entityRefsOf(
  ev: SelectionDocSnapshot["observations"][number],
): EntityRef[] {
  switch (ev.kind) {
    case "peer-joined":
    case "peer-left":
      return [{ kind: "peer", id: ev.peerId as string }];
    case "session-opened":
    case "session-closed":
    case "session-state-changed":
      return [{ kind: "session", id: ev.sessionId as string }];
    case "message-sent":
    case "message-delivered":
      return [{ kind: "message", id: ev.messageId as string }];
    default:
      return [];
  }
}

/** Entity refs of events whose `t` falls inside [start, end]. */
function entitiesInRange(
  range: TimeRange | null,
  doc: SelectionDocSnapshot,
): ReadonlySet<EntityRefKey> {
  if (!range) return new Set();
  const out = new Set<EntityRefKey>();
  for (const ev of doc.observations) {
    if (ev.t < range.start || ev.t > range.end) continue;
    for (const ref of entityRefsOf(ev)) out.add(entityKey(ref));
  }
  return out;
}

/** Invert: all entities in doc that AREN'T in `current`. */
function invertSelection(
  current: ReadonlySet<EntityRefKey>,
  doc: SelectionDocSnapshot,
): ReadonlySet<EntityRefKey> {
  const all = entityOrderFromDoc(doc);
  const out = new Set<EntityRefKey>();
  for (const k of all) {
    if (!current.has(k)) out.add(k);
  }
  return out;
}

/** Shrink the time range to tightly enclose the events of entities
 *  in `current`. Returns null if `current` is empty or no events
 *  match. */
function shrinkToEvents(
  current: ReadonlySet<EntityRefKey>,
  doc: SelectionDocSnapshot,
): TimeRange | null {
  if (current.size === 0) return null;
  let min = Infinity;
  let max = -Infinity;
  for (const ev of doc.observations) {
    const refs = entityRefsOf(ev);
    const matches = refs.some((r) => current.has(entityKey(r)));
    if (!matches) continue;
    if (ev.t < min) min = ev.t;
    if (ev.t > max) max = ev.t;
  }
  if (!Number.isFinite(min)) return null;
  return { start: min, end: max };
}

function assertNever(x: never): never {
  throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}

// ─────────────────────── Selectors (helpers for consumers) ─────────────

/** Decode the selection set back to typed EntityRefs. */
export function selectionRefs(
  state: SelectionState,
): readonly EntityRef[] {
  return [...state.selection].map(parseEntityKey);
}

/** True if any selection slot is non-empty. */
export function hasAnySelection(state: SelectionState): boolean {
  return state.timeRange !== null ||
    state.anchor !== null ||
    state.selection.size > 0;
}
