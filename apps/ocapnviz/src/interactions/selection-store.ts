/**
 * Selection store, implements § 6 of the interaction model.
 *
 * Pure reducer over the entity selection and its Inspector-follow anchor.
 *
 * Vocabulary note: a selection is the selection. There is no "multi",
 * a selection of size 1 is still the selection. Actions are
 * `set-selection`, `add-to-selection`, and `remove-from-selection`.
 * Property edits, group delete, group drag, and group nudge all operate on
 * this set.
 */

import { parseEndpointStageId } from "../schema/session-end.ts";
import { assertNever } from "./assert-never.ts";
import { entityKey, type EntityKind, type EntityRef, type EntityRefKey, parseEntityKey } from "./entity-ref.ts";
import type { SelectMode } from "./select-mode.ts";
import { hasEntry } from "../engine/schema/entity-maps.ts";

export type SelectionState = {
	/** Inspector follow target. The current entity moves to the most
	 *  recent selection member and is null when nothing is selected.
	 *  Null when nothing is anchored (selection size 0 implies
	 *  anchor null. Selection size ≥ 1 implies anchor set). */
	anchor: EntityRef | null;
	/** THE selection. The set of entities the user has selected.
	 *  property edits, group delete, group drag, group nudge all
	 *  operate on this set. Heterogeneous: peers, sessions, and
	 *  messages may coexist. There is no separate "multi", a
	 *  selection of size 1 is still the selection. */
	selection: ReadonlySet<EntityRefKey>;
};

export const EMPTY_SELECTION: SelectionState = {
	anchor: null,
	selection: new Set(),
};

/** The identity side of a document: which entities it declares, by kind and id.
 *
 *  Named on its own because the one question it answers, does this document
 *  still hold this entity, is asked from outside the store too, and a caller
 *  with a document in hand can ask it directly (`documentHolds`). */
export type DeclaredEntities = {
	peers?: Readonly<Record<string, unknown>> | undefined;
	sessions?: Readonly<Record<string, unknown>> | undefined;
	messages?: Readonly<Record<string, unknown>> | undefined;
} | undefined;

export type SelectionAction =
	// selection (THE set; size 0+; uniform vocabulary)
	| { kind: "set-selection"; entities: ReadonlySet<EntityRefKey> }
	| { kind: "add-to-selection"; entities: ReadonlySet<EntityRefKey> }
	| { kind: "remove-from-selection"; entities: ReadonlySet<EntityRefKey> }
	// Drop whatever the document no longer holds. Undo and redo move
	// ids under the selection, a rename taken back leaves it pointing
	// at a name nothing answers to, and this is how it catches up.
	// `undoWithSelection` / `redoWithSelection` in `builder/selection-history.ts`
	// are what dispatch it, and the top bar and the Cmd-Z binding both
	// take history back through them.
	| { kind: "reconcile-with-doc"; entities: DeclaredEntities }
	// Surgical id rewrite after a rename, see `selection-store.ts`
	// for why this is distinct from `set-selection`.
	| {
		kind: "rename-entity";
		entityKind: EntityKind;
		oldId: string;
		newId: string;
	}
	| { kind: "clear-all" }
	| { kind: "clear-on-empty-click" };

/** The one interpretation of a modifier select-mode against the
 * selection: which store action a surface's gesture becomes. Every
 * selecting surface (stage click, stage marquee, timeline pill,
 * timeline marquee) forwards `(mode, hits)` here instead of
 * spelling its own set arithmetic. An empty hit set is the empty-space
 * gesture: plain replace clears, while a modifier gesture preserves the selection
 * (null = dispatch nothing). */
export function selectionActionFor(
	mode: SelectMode,
	entities: ReadonlySet<EntityRefKey>,
): SelectionAction | null {
	if (entities.size === 0) {
		return mode === "replace" ? { kind: "clear-on-empty-click" } : null;
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
		case "set-selection":
			// Always return a NEW Set (I4, paint bail relies on identity).
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
		case "reconcile-with-doc": {
			const kept = new Set<EntityRefKey>();
			for (const k of state.selection) {
				if (documentHolds(action.entities, parseEntityKey(k))) {
					kept.add(k);
				}
			}
			const anchorGone = state.anchor !== null &&
				!documentHolds(action.entities, state.anchor);
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
			const nextAnchor: EntityRef | null = isAnchor
				? { kind: action.entityKind, id: action.newId }
				: state.anchor;
			return { ...state, selection: nextSelection, anchor: nextAnchor };
		}
		case "clear-all":
		case "clear-on-empty-click":
			return EMPTY_SELECTION;
		default:
			return assertNever(action);
	}
}

// ─────────────────────── Helpers ──────────────────────────────────────

/** Last item of an iterable (or null when empty). It picks the
 *  anchor after a `set-selection` or `add-to-selection`: whoever
 *  was added last becomes the new range-extension pivot. */
function lastOrNull(
	entities: ReadonlySet<EntityRefKey>,
): EntityRef | null {
	let last: EntityRefKey | null = null;
	for (const k of entities) last = k;
	return last ? parseEntityKey(last) : null;
}

/** First item of an iterable (or null when empty). It re-seats
 *  the anchor when the previous anchor was removed from the
 *  selection, pick any surviving member so range-extend still has
 *  a pivot. */
function firstOrNull(
	entities: ReadonlySet<EntityRefKey>,
): EntityRef | null {
	for (const k of entities) return parseEntityKey(k);
	return null;
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
 *  declared with no observation at all. That is what every peer an
 *  author adds in Build looks like, so a walk over the stream would
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
			return hasEntry(entities?.peers, ref.id);
		case "session":
			return hasEntry(entities?.sessions, ref.id);
		case "message":
			return hasEntry(entities?.messages, ref.id);
		case "endpoint": {
			const at = parseEndpointStageId(ref.id);
			if (at === undefined) return false;
			return hasEntry(entities?.sessions, at.sessionId);
		}
	}
}

/** Every selectable top-level entity the document declares. Endpoints are
 * parts of sessions rather than independent document identities, so Select All
 * names the peer, session, and message rows a document owns. This allocates
 * only for the explicit Cmd-A command, never on paint or pointer paths. */
export function allEntityKeys(
	entities: DeclaredEntities,
): ReadonlySet<EntityRefKey> {
	const all = new Set<EntityRefKey>();
	for (const id of Object.keys(entities?.peers ?? {})) {
		all.add(entityKey({ kind: "peer", id }));
	}
	for (const id of Object.keys(entities?.sessions ?? {})) {
		all.add(entityKey({ kind: "session", id }));
	}
	for (const id of Object.keys(entities?.messages ?? {})) {
		all.add(entityKey({ kind: "message", id }));
	}
	return all;
}

// ─────────────────────── Selectors (helpers for consumers) ─────────────
