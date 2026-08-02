// The seam between the store and React.
//
// Everything the interface reads about the outside world — the layout in force,
// whether the tab is being looked at — is a store field written by one
// subscriber, so it is read here like any other fact. What is left is this: one
// subscription to the store, and the one query that is genuinely a component's
// own business.

import { useCallback, useEffect, useSyncExternalStore } from "react";
import { get, noteVisibility, State, subscribe } from "./store.ts";

/** The whole state, re-read whenever any of it changes.
 *
 * One subscription for the application. The page is small enough that a change
 * anywhere is cheap to re-derive everywhere, and the alternative — a selector
 * per component — buys speed this app cannot spend and costs a class of bug (a
 * selector that forgets a dependency) it would rather not have. What it does
 * cost is that a keystroke in the composer, whose draft is a store field,
 * re-renders from the root; the panes that cannot differ because of a keystroke
 * are memoised, which is where that cost would otherwise land. */
export function useStore(): State {
	return useSyncExternalStore(subscribe, get, get);
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
			if (!(e.target as Element | null)?.closest?.(within)) close();
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
