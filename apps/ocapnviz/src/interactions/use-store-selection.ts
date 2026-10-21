/**
 * React host for the selection store, interaction-model § 6.
 *
 * `selection-store.ts` owns the reducer. This hook owns the App's one
 * store instance and the surface bridges that turn stage / timeline
 * gestures into store actions. `anchor` is the Inspector-follow slot,
 * `selection` is the entity-key set the marquee and bulk ops write
 * through.
 */

import { type Dispatch, useCallback, useReducer } from "react";
import type { SelectMode, StageSelection } from "../render/types.ts";
import { selectionActionFor, selectionReducer } from "./selection-store.ts";
import { EMPTY_SELECTION, entityKey, type EntityRefKey, type SelectionAction, type SelectionState } from "./types.ts";

export type StoreSelectionHost = {
	storeSelection: SelectionState;
	dispatchSelection: Dispatch<SelectionAction>;
	handleRubberBandCommit: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
	handleTimelineEditSelection: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
	handleClearStoreSelection: () => void;
	handleSetSelection: (entities: ReadonlySet<EntityRefKey>) => void;
	handleEntityRenamed: (
		kind: "peer" | "session" | "message",
		oldId: string,
		newId: string,
	) => void;
	handleStoreSelect: (
		sel: StageSelection,
		opts?: { mode?: SelectMode },
	) => void;
};

export function useStoreSelection(): StoreSelectionHost {
	const [storeSelection, dispatchSelection] = useReducer(
		selectionReducer,
		EMPTY_SELECTION,
	);
	// Rubber-band commit (interaction-model § 4.7): drag-end on
	// empty stage hands back the set of entity keys + a mode.
	// Modifier latches captured during the drag pick the mode:
	// plain → replace, shift → add, shift+option → remove.
	const handleRubberBandCommit = useCallback(
		(entities: ReadonlySet<EntityRefKey>, mode: SelectMode) => {
			const action = selectionActionFor(mode, entities);
			if (action) dispatchSelection(action);
		},
		[],
	);
	// The timeline's counterpart, same interpreter, timeline
	// empty-space semantics (clears the time range, keeps the
	// anchor).
	const handleTimelineEditSelection = useCallback(
		(entities: ReadonlySet<EntityRefKey>, mode: SelectMode) => {
			const action = selectionActionFor(mode, entities);
			if (action) dispatchSelection(action);
		},
		[],
	);
	// Escape clears EVERY selection slot, anchor, multi-selection,
	// and time range, so the user sees one coherent "clear" verb.
	const handleClearStoreSelection = useCallback(
		() => dispatchSelection({ kind: "clear-all" }),
		[],
	);
	// Direct-write bridges to the store for surfaces that already
	// think in entity-key space (the Scrubber's rubber-band /
	// shift-click after unification, TimelinePanel's Cmd-A / Escape /
	// Delete). Stage's marquee already routes through
	// `handleRubberBandCommit`; these mirror that wiring for the
	// Timeline surface so both halves of the selection bus speak the
	// same store actions.
	const handleSetSelection = useCallback(
		(entities: ReadonlySet<EntityRefKey>) => dispatchSelection({ kind: "set-selection", entities }),
		[],
	);
	// Single `rename-entity` dispatch, see `selection-store.ts`.
	// A dedicated action keeps the anchor, which delete-then-add via
	// `set-selection` would replace.
	const handleEntityRenamed = useCallback(
		(
			kind: "peer" | "session" | "message",
			oldId: string,
			newId: string,
		) => {
			dispatchSelection({
				kind: "rename-entity",
				entityKind: kind,
				oldId,
				newId,
			});
		},
		[],
	);
	// Single bridge from a Stage entity click to the store. Keeps
	// the store's `selection` in lockstep with the visible halo,
	// the mode's meaning has one home: `selectionActionFor` in the
	// selection store. This wrapper only shapes the stage's
	// single-entity click into a hit set.
	const handleStoreSelect = useCallback(
		(sel: StageSelection, opts?: { mode?: SelectMode }) => {
			const entities = sel
				? new Set<EntityRefKey>([
					entityKey({ kind: sel.kind, id: sel.id }),
				])
				: new Set<EntityRefKey>();
			const action = selectionActionFor(
				opts?.mode ?? "replace",
				entities,
			);
			if (action) dispatchSelection(action);
		},
		[],
	);
	return {
		storeSelection,
		dispatchSelection,
		handleRubberBandCommit,
		handleTimelineEditSelection,
		handleClearStoreSelection,
		handleSetSelection,
		handleEntityRenamed,
		handleStoreSelect,
	};
}
