/// <reference lib="dom" />
// The URL names this tab's DM transport; durable session intent supplies the
// default. Changing it reloads the page because transport is chosen at startup.
import { pageRoute } from "./page_base.ts";

/** The saved preference. Fastest is the default: both routes at once on a
 * page with a Rooms server, browser to browser on a page with none. */
export type DmMode = "fastest" | "webrtc" | "relay";
const DM_MODES: readonly DmMode[] = ["fastest", "webrtc", "relay"];
function dmModeOf(value: string | null): DmMode | null {
	return DM_MODES.find((mode) => mode === value) ?? null;
}

/** Resolve the DM preference from a search string and a stored preference.
 * The URL names a route to start under, or nothing, and storage fills in. */
export function dmFrom(search: URLSearchParams, stored: string | null): DmMode {
	return dmModeOf(search.get("dm")) ?? dmModeOf(stored) ?? "fastest";
}

export function dmMode(stored: DmMode = "fastest"): DmMode {
	return dmFrom(new URLSearchParams(location.search), stored);
}

export function current(intent?: { connection: DmMode }): { dm: DmMode } {
	return { dm: dmMode(intent?.connection) };
}

/** The directory a Rooms server hosts, from its `locator` (by default the one
 * under this page's base), or null when it names none. A static host has no
 * `locator`, and one with a page fallback answers every path with HTML, so only
 * a body `names` accepts as a directory address counts. `read` is the caller's
 * fetch, with the deadline the caller gives it. */
export async function servedDirectory(
	names: (text: string) => boolean,
	read: (address: URL) => Promise<Response>,
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
	if (next.dm === "fastest") url.searchParams.delete("dm");
	else url.searchParams.set("dm", next.dm);
}
