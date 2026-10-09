// This browser keeps its own view choices independently of the selected peer.
import { parseRoomsViewState, type RoomsViewState } from "../../lib/view_state.ts";
import type { PageProjection } from "./store/core.ts";
import { noteTrouble } from "./store.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";

export const VIEW_PREFERENCES_KEY = "rooms.view-preferences";

export function viewPreferences(projection: PageProjection): RoomsViewState {
	const { theme, notifyOn, railOpen, rosterOpen, settingsTab, opsPane, remembered } = projection.get();
	return { theme, notifyOn, railOpen, rosterOpen, settingsTab, opsPane, remembered };
}

export function bindViewPreferences(projection: PageProjection): () => void {
	try {
		const saved = localStorage.getItem(VIEW_PREFERENCES_KEY);
		if (saved != null) projection.set(parseRoomsViewState(JSON.parse(saved)));
	} catch (error) {
		noteTrouble(projection, managedSessionText.browserPreferences, refusalText(error));
	}
	let previous = JSON.stringify(viewPreferences(projection));
	return projection.subscribe(() => {
		const next = JSON.stringify(viewPreferences(projection));
		if (next === previous) return;
		previous = next;
		try {
			localStorage.setItem(VIEW_PREFERENCES_KEY, next);
		} catch (error) {
			noteTrouble(projection, managedSessionText.browserPreferences, refusalText(error));
		}
	});
}
