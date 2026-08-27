// React bindings for the page projection and browser media facts.

import { useCallback, useEffect, useSyncExternalStore } from "react";
import { useStore } from "zustand";
import { noteVisibility, roomsProjection, State } from "./store.ts";

/** Subscribe a component to the projection it renders. The selector result is
 * compared by identity, so aggregate selectors use Zustand's `useShallow` and
 * leaf selectors return the retained map, row, or primitive directly. */
export function useRoomsState<T>(selector: (state: Readonly<State>) => T): T {
	return useStore(roomsProjection, selector);
}

// One list per distinct query, shared by every caller. Built lazily and never
// replaced, so two components asking the same question subscribe to one object.
const lists = new Map<string, MediaQueryList>();
function listFor(query: string): MediaQueryList {
	let list = lists.get(query);
	if (!list) lists.set(query, list = matchMedia(query));
	return list;
}

/** Whether a media query matches, kept current. Private: the exported hooks
 * below name the two questions this page actually asks, so no caller can pass a
 * query that changes between renders — which this would silently ignore. */
function useMediaQuery(query: string): boolean {
	const listen = useCallback((onChange: () => void) => {
		const list = listFor(query);
		list.addEventListener("change", onChange);
		return () => list.removeEventListener("change", onChange);
	}, [query]);
	return useSyncExternalStore(listen, () => listFor(query).matches, () => false);
}

/** Whether the pointer cannot hold a modifier, which decides whether Return
 * sends or inserts a newline. Layout is not this question and is not asked here:
 * it is `state.mobile`, because the store's own verbs depend on it. */
export function useCoarsePointer(): boolean {
	return useMediaQuery("(pointer: coarse)");
}

/** Put something away when a click lands outside it.
 *
 * `within` is a selector naming the thing and whatever opens it, and it is
 * containment rather than identity on purpose: the click usually lands on an
 * icon *inside* the toggle, so testing the target itself would close the panel
 * in the same click that opened it. */
export function useDismissOnClickOutside(
	open: boolean,
	within: string,
	close: () => void,
): void {
	useEffect(() => {
		if (!open) return;
		const dismiss = (e: MouseEvent) => {
			// Asked of the path the press was dispatched along, not of where its
			// target sits now. A handler that runs before this one can re-render
			// the pressed element out of the document, which a toggle swapping
			// its own icon does every time it is pressed, and a detached node has
			// no ancestors left to find. Reading its `closest` therefore called
			// such a press an outside one and dismissed whatever was open, which
			// is the opposite of what pressing a control inside means.
			const path = e.composedPath();
			if (!path.some((node) => node instanceof Element && node.matches(within))) close();
		};
		document.addEventListener("click", dismiss);
		return () => document.removeEventListener("click", dismiss);
	}, [open, within, close]);
}

// Whether the tab is being looked at is a document fact, and the store holds it
// as a field with one writer. That writer is here: this module is the seam
// between the browser and the store, so the store itself never reads the page.
// The first call syncs a tab that was opened in the background, and costs
// nothing when it was not.
noteVisibility(!document.hidden);
document.addEventListener("visibilitychange", () => noteVisibility(!document.hidden));
