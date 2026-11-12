// Deleting browser data forgets every Rooms preference and the shared theme,
// and leaves what other pages on the origin keep.
import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";
import { forgetBrowserPreferences, isDeletionNotice, ROOMS_PREFIX } from "../web/ui/controller/browser_data.ts";
import { THEME_KEY, VIEW_PREFERENCES_KEY } from "../web/ui/view_preferences.ts";
import { SERVER_KEY } from "../web/ui/server_choice.ts";
import { pageStorage } from "../web/ui/page_storage.ts";
import { LocalRefusal } from "../lib/text/failure.ts";

class MemoryStorage implements Storage {
	#items = new Map<string, string>();
	get length(): number {
		return this.#items.size;
	}
	key(index: number): string | null {
		return [...this.#items.keys()][index] ?? null;
	}
	getItem(key: string): string | null {
		return this.#items.get(key) ?? null;
	}
	setItem(key: string, value: string): void {
		this.#items.set(key, value);
	}
	removeItem(key: string): void {
		this.#items.delete(key);
	}
	clear(): void {
		this.#items.clear();
	}
	keys(): string[] {
		return [...this.#items.keys()];
	}
}

Deno.test("every named Rooms storage key sits under the prefix the deletion sweeps", () => {
	for (const key of [VIEW_PREFERENCES_KEY, SERVER_KEY]) assertEquals(key.startsWith(ROOMS_PREFIX), true, key);
	assertEquals(THEME_KEY.startsWith(ROOMS_PREFIX), false, "the theme is the website's key, removed by name");
});

Deno.test("forgetting browser preferences removes every Rooms key and the theme, and nothing else", () => {
	const storage = new MemoryStorage();
	storage.setItem(`${ROOMS_PREFIX}workspace-choice.tab-1`, "yes");
	storage.setItem(`${ROOMS_PREFIX}workspace-choice.tab-2`, "yes");
	storage.setItem(VIEW_PREFERENCES_KEY, "{}");
	storage.setItem(SERVER_KEY, "https://rooms.example/");
	storage.setItem(THEME_KEY, "light");
	storage.setItem("other-page", "kept");
	assertEquals(forgetBrowserPreferences(pageStorage(() => storage)), null);
	assertEquals(storage.keys(), ["other-page"]);
});

Deno.test("a deletion the browser refuses to finish says so instead of reporting it done", () => {
	const storage = new MemoryStorage();
	storage.setItem(VIEW_PREFERENCES_KEY, "{}");
	const refusing = pageStorage(() => ({
		length: storage.length,
		key: (index: number) => storage.key(index),
		getItem: (key: string) => storage.getItem(key),
		setItem: (key: string, value: string) => storage.setItem(key, value),
		removeItem: () => {
			throw new DOMException("The operation is insecure.", "SecurityError");
		},
	}));
	assertEquals(forgetBrowserPreferences(refusing) instanceof LocalRefusal, true);
	assertEquals(storage.keys(), [VIEW_PREFERENCES_KEY], "nothing it could not reach is claimed gone");
});

Deno.test("one key the browser refuses still lets every other key go", () => {
	const storage = new MemoryStorage();
	const stuck = `${ROOMS_PREFIX}workspace-choice.tab-1`;
	storage.setItem(stuck, "yes");
	storage.setItem(VIEW_PREFERENCES_KEY, "{}");
	storage.setItem(THEME_KEY, "light");
	const refusing = pageStorage(() => ({
		length: storage.length,
		key: (index: number) => storage.key(index),
		getItem: (key: string) => storage.getItem(key),
		setItem: (key: string, value: string) => storage.setItem(key, value),
		removeItem: (key: string) => {
			if (key === stuck) throw new DOMException("The operation is insecure.", "SecurityError");
			storage.removeItem(key);
		},
	}));
	assertEquals(forgetBrowserPreferences(refusing) instanceof LocalRefusal, true);
	assertEquals(storage.keys(), [stuck], "only the refused key remains");
});

Deno.test("another tab's finished deletion is recognized by the notice it writes, and nothing else", () => {
	assertEquals(isDeletionNotice({ key: `${ROOMS_PREFIX}deleted`, newValue: "1762700000000" }), true);
	assertEquals(isDeletionNotice({ key: `${ROOMS_PREFIX}deleted`, newValue: null }), false);
	assertEquals(isDeletionNotice({ key: VIEW_PREFERENCES_KEY, newValue: null }), false);
	assertEquals(isDeletionNotice({ key: null, newValue: null }), false);
});
