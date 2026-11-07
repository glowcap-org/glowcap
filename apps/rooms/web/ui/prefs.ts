/// <reference lib="dom" />
// The URL names this tab's DM transport; durable session intent supplies the
// default. Changing it reloads the page because transport is chosen at startup.
import { pageRoute } from "./page_base.ts";

export type DmMode = "webrtc" | "relay";

/** Resolve DM transport from a search string and a stored preference. */
export function dmFrom(search: URLSearchParams, stored: string | null): DmMode {
	const q = search.get("dm");
	if (q === "relay") return "relay";
	if (q === "webrtc") return "webrtc";
	return stored === "relay" ? "relay" : "webrtc";
}

export function dmMode(stored: DmMode = "webrtc"): DmMode {
	return dmFrom(new URLSearchParams(location.search), stored);
}

export function current(intent?: { connection: DmMode }): { dm: DmMode } {
	return { dm: dmMode(intent?.connection) };
}

/** The directory a Rooms server hosts, from its `locator` (by default the one
 * under this page's base), or null when it names none. A static host has no
 * `locator`, and one with a page fallback answers every path with HTML, so only
 * a body `names` accepts as a directory address counts. */
export async function servedDirectory(
	names: (text: string) => boolean,
	read: (address: URL) => Promise<Response> = fetch,
	address: URL = pageRoute("locator"),
): Promise<string | null> {
	try {
		const res = await read(address);
		if (!res.ok) return null;
		const text = (await res.text()).trim();
		return text !== "" && names(text) ? text : null;
	} catch {
		return null;
	}
}

/** Persist the DM route choice, preserving unrelated query parameters. */
export function writeSearch(url: URL, next: { dm: DmMode }): void {
	if (next.dm === "relay") url.searchParams.set("dm", "relay");
	else url.searchParams.delete("dm");
}
