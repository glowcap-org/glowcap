// The view state is one record to the page and two keys in the browser: the
// theme under the key the website shares, everything else under the Rooms
// record. A refused record is said once and does not take the theme with it.

/// <reference lib="dom" />

import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";
import { DEFAULT_ROOMS_VIEW_STATE } from "../lib/view_state.ts";

const kept = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: (key: string) => kept.get(key) ?? null,
		setItem: (key: string, value: string) => void kept.set(key, value),
		removeItem: (key: string) => void kept.delete(key),
	},
});
const store = await import("../web/ui/store.ts");
const { bindViewPreferences, THEME_KEY, VIEW_PREFERENCES_KEY } = await import("../web/ui/view_preferences.ts");
const { theme: _defaultTheme, ...defaultRecord } = DEFAULT_ROOMS_VIEW_STATE;

Deno.test("view preferences: the theme and the Rooms record are two keys, each written when it moves", () => {
	kept.clear();
	kept.set(THEME_KEY, "light");
	kept.set(VIEW_PREFERENCES_KEY, JSON.stringify({ ...defaultRecord, railOpen: !defaultRecord.railOpen }));
	const projection = new store.PageProjection();
	const stop = bindViewPreferences(projection);
	assertEquals(projection.get().theme, "light", "the theme from its own key");
	assertEquals(projection.get().railOpen, !defaultRecord.railOpen, "the rail from the Rooms record");
	const record = kept.get(VIEW_PREFERENCES_KEY);
	projection.set({ theme: "dark" });
	assertEquals(kept.get(THEME_KEY), "dark", "a moved theme is written under its key");
	assertEquals(kept.get(VIEW_PREFERENCES_KEY), record, "and the record is left as it was");
	projection.set({ railOpen: defaultRecord.railOpen });
	assertEquals(kept.get(THEME_KEY), "dark", "a moved record leaves the theme key");
	assertEquals(
		JSON.parse(kept.get(VIEW_PREFERENCES_KEY) ?? "{}").railOpen,
		defaultRecord.railOpen,
		"and rewrites the record",
	);
	assertEquals(projection.get().trouble.length, 0, "nothing to report");
	stop();
});

Deno.test("view preferences: a record of another shape is refused once and the theme is kept", () => {
	kept.clear();
	kept.set(THEME_KEY, "light");
	kept.set(VIEW_PREFERENCES_KEY, JSON.stringify({ ...defaultRecord, nope: 1 }));
	const projection = new store.PageProjection();
	const stop = bindViewPreferences(projection);
	assertEquals(projection.get().theme, "light", "the theme survives the refused record");
	assertEquals(projection.get().railOpen, defaultRecord.railOpen, "the record's choices are the page's defaults");
	assertEquals(kept.has(VIEW_PREFERENCES_KEY), false, "the refused record is removed");
	assertEquals(projection.get().trouble.length, 1, "said once");
	stop();
});
