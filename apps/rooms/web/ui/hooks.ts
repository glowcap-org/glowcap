// React bindings for the page projection and browser media facts.

import { createContext, useCallback, useContext, useEffect, useSyncExternalStore } from "react";
import { useStore } from "zustand";
import { NO_MEMBERS, type PageProjection, type State } from "./store.ts";
import { mayObserve } from "../../lib/session/client.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { effectiveRoomsSessionAccess } from "./controller/access.ts";
import type { Standing } from "./types.ts";

const RoomsProjectionContext = createContext<PageProjection | null>(null);

/** The page's presentation, for as long as the page. Every tree the page
 * renders stands in it, including the screen that runs before any session
 * exists, because a refusal met there opens the same error card the
 * established page opens. `PageSurface` in main.tsx is where it goes on. */
export const RoomsProjectionProvider = RoomsProjectionContext.Provider;

export function useRoomsProjection(): PageProjection {
	const projection = useContext(RoomsProjectionContext);
	if (projection == null) {
		throw new Error("rooms: the page projection was requested outside its provider");
	}
	return projection;
}

/** Subscribe a component to the projection it renders. The selector result is
 * compared by identity, so aggregate selectors use Zustand's `useShallow` and
 * leaf selectors return the retained map, row, or primitive directly. */
export function useRoomsState<T>(selector: (state: Readonly<State>) => T): T {
	return useStore(useRoomsProjection().api, selector);
}

/** Whether this browser's access to a shared session is paused.
 *
 * A view held at nothing is answered with no session at all, so several
 * surfaces are empty at once for one reason and each has to say which emptiness
 * this is rather than offer the act it usually suggests. They ask here so the
 * reading is made once.
 *
 * Which access applies is `effectiveRoomsSessionAccess`'s answer and not this
 * one's: a browser holding its own session is not under a link's access at all
 * and can never be paused, and an attached one that has not been answered yet
 * is not paused either. Deciding that here a second time is how the two drift
 * into disagreeing about the same browser. */
export function useSessionPaused(): boolean {
	const controller = useRoomsBrowser().roomsController();
	const attached = useRoomsState((state) => state.sessionAccess);
	const access = effectiveRoomsSessionAccess(controller, attached);
	return access !== null && !mayObserve(access);
}

/** Who is in this room. Subscribes here, not at the page root, so a join or
 * away word does not rebuild the shell. */
export function useConversationMembers(key: string | null): ReadonlyMap<string, Standing> {
	return useRoomsState((state) => key == null ? NO_MEMBERS : state.members.get(key) ?? NO_MEMBERS);
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
			const inside = path.some((node) => {
				if (!(node instanceof Element)) return false;
				if (node.matches(within)) return true;
				// A menu is drawn at the end of the document so that scrolling to
				// one of its rows cannot scroll the surface it belongs to out from
				// under it. That takes it off the path a press travels, so it
				// carries the name of what it belongs to and stands for it here.
				// Without this every such menu reads as somewhere else, and
				// pressing a row puts away the panel the row was acting on.
				const owner = node instanceof HTMLElement ? node.dataset.menuIn : undefined;
				return owner !== undefined && document.getElementById(owner)?.closest(within) != null;
			});
			if (!inside) close();
		};
		document.addEventListener("click", dismiss);
		return () => document.removeEventListener("click", dismiss);
	}, [open, within, close]);
}

/** Mirror whether this tab is being looked at into the page's projection.
 *
 * Whether the tab is being looked at is a document fact, and the store holds it
 * as a field with one writer. That writer is here: this module is the seam
 * between the browser and the store, so the store itself never reads the page.
 * The first call syncs a tab that was opened in the background, and costs
 * nothing when it was not. */
export function bindTabVisibility(projection: PageProjection): () => void {
	projection.noteVisibility(!document.hidden);
	const onChange = () => projection.noteVisibility(!document.hidden);
	document.addEventListener("visibilitychange", onChange);
	return () => document.removeEventListener("visibilitychange", onChange);
}
