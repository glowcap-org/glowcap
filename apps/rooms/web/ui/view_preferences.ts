// This browser keeps its own view choices independently of the selected peer.
//
// The view state is one record to the page, to the `/theme` command, to
// Settings, and to the export file. In the browser it is kept under two keys,
// because one of its fields is not Rooms' alone: the theme is the face every
// glowcap page on this origin wears. The website reads and writes the same
// key, so a reader who chose light on the site opens Rooms light, and
// page.html reads it before the first paint. Everything else is Rooms' own
// and lives in the Rooms record.
import * as z from "zod/mini";
import { parseRoomsViewState, type RoomsViewState, RoomsViewStateSchema } from "../../lib/view_state.ts";
import type { PageProjection } from "./store/projection.ts";
import { noteTrouble } from "./store.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";

/** The Rooms record: every view choice but the theme. */
export const VIEW_PREFERENCES_KEY = "rooms.view-preferences";
/** The origin-wide theme, "light" or "dark". Unset is the default face, syrup. */
export const THEME_KEY = "glowcap-theme";

const StoredPreferencesSchema = z.omit(RoomsViewStateSchema, { theme: true });

export function viewPreferences(projection: PageProjection): RoomsViewState {
	const { theme, notifyOn, railOpen, rosterOpen, settingsTab, opsPane, remembered } = projection.get();
	return { theme, notifyOn, railOpen, rosterOpen, settingsTab, opsPane, remembered };
}

/** The view state as this browser holds it: the theme from its own key, every
 * other choice from the Rooms record, and the page's current value for either
 * that is unset. A record of another shape is refused once: `refuse` hears
 * why, the theme is kept, and the record is removed so the next load does not
 * say it again. */
function storedViewState(current: RoomsViewState, refuse: (error: unknown) => void): RoomsViewState {
	const theme = localStorage.getItem(THEME_KEY);
	const saved = localStorage.getItem(VIEW_PREFERENCES_KEY);
	let preferences: Omit<RoomsViewState, "theme"> = current;
	if (saved != null) {
		try {
			preferences = z.parse(StoredPreferencesSchema, JSON.parse(saved));
		} catch (error) {
			localStorage.removeItem(VIEW_PREFERENCES_KEY);
			refuse(error);
		}
	}
	return parseRoomsViewState({
		...preferences,
		theme: theme === "light" || theme === "dark" ? theme : current.theme,
	});
}

/** The view state as the two keys hold it. */
function keyed({ theme, ...preferences }: RoomsViewState): { theme: string; record: string } {
	return { theme, record: JSON.stringify(preferences) };
}

export function bindViewPreferences(projection: PageProjection): () => void {
	const refuse = (error: unknown) =>
		noteTrouble(projection, managedSessionText.browserPreferences, refusalText(error));
	try {
		projection.set(storedViewState(viewPreferences(projection), refuse));
	} catch (error) {
		// The browser's storage itself refused, so the page keeps its defaults.
		refuse(error);
	}
	let previous = keyed(viewPreferences(projection));
	return projection.subscribe(() => {
		const next = keyed(viewPreferences(projection));
		const themeMoved = next.theme !== previous.theme;
		const recordMoved = next.record !== previous.record;
		if (!themeMoved && !recordMoved) return;
		previous = next;
		try {
			if (themeMoved) localStorage.setItem(THEME_KEY, next.theme);
			if (recordMoved) localStorage.setItem(VIEW_PREFERENCES_KEY, next.record);
		} catch (error) {
			refuse(error);
		}
	});
}
