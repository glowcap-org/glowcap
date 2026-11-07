/// <reference lib="dom" />
// The Rooms server this browser uses: its relay, where people reach this
// browser, and the directory a blank address means. It is a fact about this
// device, not the session: a server one browser reaches may not be one another
// reaches. With no choice, it is the server that sent this page, under its
// base.

import { pageBase, servedByRooms } from "./page_base.ts";

export const SERVER_KEY = "rooms.server";

/** A typed server address, read as a page base: an http or https URL whose
 * path ends in `/`, with no credentials, query, or fragment. Blank is no
 * choice. Anything else is refused, never repaired past a missing final `/`. */
export function serverBase(typed: string): { base: string | null } | { refused: true } {
	const text = typed.trim();
	if (text === "") return { base: null };
	let url: URL;
	try {
		url = new URL(text);
	} catch {
		return { refused: true };
	}
	const plain = (url.protocol === "http:" || url.protocol === "https:") &&
		url.username === "" && url.password === "" && url.search === "" && url.hash === "" &&
		!text.includes("?") && !text.includes("#");
	if (!plain) return { refused: true };
	if (!url.pathname.endsWith("/")) url.pathname += "/";
	return { base: url.href };
}

/** The server this browser chose, as a page base, or null for the page's own
 * server. A stored value that does not read as one counts as no choice. */
export function chosenServer(storage: Pick<Storage, "getItem"> = localStorage): string | null {
	const read = serverBase(storage.getItem(SERVER_KEY) ?? "");
	return "base" in read ? read.base : null;
}

/** Keep `base` as this browser's server, or forget the choice for null. */
export function chooseServer(
	base: string | null,
	storage: Pick<Storage, "setItem" | "removeItem"> = localStorage,
): void {
	if (base == null) storage.removeItem(SERVER_KEY);
	else storage.setItem(SERVER_KEY, base);
}

/** The parameter a link uses to offer this browser a server, such as the link a
 * Rooms server prints for a page hosted elsewhere. */
export const SERVER_OFFER = "server";

/** A server a link offers, read from `page` and taken out of it: `rest` is the
 * address without the offer, so a reload or a shared link does not repeat it.
 * `base` is null when the offer is not a server address or is already the
 * choice, so there is nothing to ask. Null when the link offers nothing. */
export function serverOffer(
	page: URL,
	chosen: string | null = chosenServer(),
): { base: string | null; rest: URL } | null {
	const offered = page.searchParams.get(SERVER_OFFER);
	if (offered == null) return null;
	const rest = new URL(page);
	rest.searchParams.delete(SERVER_OFFER);
	const read = serverBase(offered);
	const base = "base" in read && read.base !== chosen ? read.base : null;
	return { base, rest };
}

/** The Rooms server this browser uses, as a page base, and whether this device
 * chose it. Null when it chose none and a static host sent the page, which is
 * no Rooms server. */
export function serverInUse(
	chosen: string | null = chosenServer(),
	page: URL = pageBase(),
	served: boolean = servedByRooms(),
): { base: string; chosen: boolean } | null {
	if (chosen != null) return { base: chosen, chosen: true };
	return served ? { base: page.href, chosen: false } : null;
}

/** What a server at `base` says to this page before anything is saved. */
export type ServerProbe =
	| { readonly kind: "answers"; readonly directory: string }
	| { readonly kind: "elsewhere" }
	| { readonly kind: "refuses" }
	| { readonly kind: "silent" };

/** How long a test waits for a server to answer. */
export const PROBE_TIMEOUT_MS = 5_000;

/** Ask the server at `base` for its directory the way the session will. A
 * read this page may see answers with the directory `names` accepts. A Rooms
 * server always has one, or answers 503 while it starts, so any other reply is
 * from somewhere else, or from a server still starting.
 * A browser hides why a cross-origin read failed, so an opaque read of the
 * same route tells the two causes apart: it resolves whenever something
 * answers, so the server is there and turned this page away. When neither
 * resolves, nothing answered. */
export async function probeServer(
	base: string,
	names: (text: string) => boolean,
	read: (address: URL, init: RequestInit) => Promise<Response> = fetch,
	timeoutMs: number = PROBE_TIMEOUT_MS,
): Promise<ServerProbe> {
	const locator = new URL("locator", base);
	try {
		const res = await read(locator, { cache: "no-store", signal: AbortSignal.timeout(timeoutMs) });
		const text = res.ok ? (await res.text()).trim() : "";
		return names(text) ? { kind: "answers", directory: text } : { kind: "elsewhere" };
	} catch {
		// tolerant: the opaque read below says which failure this was.
	}
	try {
		await read(locator, { cache: "no-store", mode: "no-cors", signal: AbortSignal.timeout(timeoutMs) });
		return { kind: "refuses" };
	} catch {
		return { kind: "silent" };
	}
}
