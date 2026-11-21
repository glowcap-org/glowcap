/// <reference lib="dom" />
// The Rooms server this browser uses: its relay, where people reach this
// browser, and the directory a blank address means. It is a fact about this
// device, not the session: a server one browser reaches may not be one another
// reaches. With no choice, it is the server that sent this page, under its
// base.

import { pageBase, servedByRooms } from "./page_base.ts";
import { localArea, type PageStorage } from "./page_storage.ts";
import type { LocalRefusal } from "../../lib/text/failure.ts";

export const SERVER_KEY = "rooms.server";

/** A typed server address, read as a page base: an http or https URL whose
 * path ends in `/`, with no credentials, query, or fragment. Blank is no
 * choice. Anything else is refused whole, the way the server reads its own
 * `--allow-origin` entries: a path with no final `/` could name a file or a
 * directory, so it is never guessed. A bare origin parses with the path `/`. */
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
		!text.includes("?") && !text.includes("#") && url.pathname.endsWith("/");
	return plain ? { base: url.href } : { refused: true };
}

/** The server this browser chose, as a page base, or null for the page's own
 * server. A stored value that does not read as one counts as no choice. */
export function chosenServer(storage: PageStorage = localArea): string | null {
	const read = serverBase(storage.read(SERVER_KEY) ?? "");
	return "base" in read ? read.base : null;
}

/** Keep `base` as this browser's server, or forget the choice for null. Null
 * once kept. Otherwise the browser's refusal, and the kept choice is
 * unchanged. */
export function chooseServer(base: string | null, storage: PageStorage = localArea): LocalRefusal | null {
	return base == null ? storage.remove(SERVER_KEY) : storage.write(SERVER_KEY, base);
}

/** The parameter a link uses to offer this browser a server, such as the link a
 * Rooms server prints for a page hosted elsewhere. */
const SERVER_OFFER = "server";

/** A server a link offers, read from `page` and taken out of it: `rest` is the
 * address without the offer, so a reload or a shared link does not repeat it.
 * `base` is null when the offer is not a server address or is already the
 * choice, so there is nothing to ask, and `unreadable` is the offer that was
 * not a server address, so the dropped offer is never silent. Null when the
 * link offers nothing. */
export function serverOffer(
	page: URL,
	chosen: string | null = chosenServer(),
): { base: string | null; unreadable: string | null; rest: URL } | null {
	const offered = page.searchParams.get(SERVER_OFFER);
	if (offered == null) return null;
	const rest = new URL(page);
	rest.searchParams.delete(SERVER_OFFER);
	const read = serverBase(offered);
	if (!("base" in read)) return { base: null, unreadable: offered, rest };
	return { base: read.base !== chosen ? read.base : null, unreadable: null, rest };
}

/** A server named the way a person typed it: its host, and its path when it
 * lives below the root. */
export function serverName(base: string): string {
	const url = new URL(base);
	return url.pathname === "/" ? url.host : url.host + url.pathname.replace(/\/$/, "");
}

/** A Rooms server as a page base, and whether this device chose it. */
export interface ServerInUse {
	base: string;
	chosen: boolean;
}

/** The Rooms server this browser uses. Null when it chose none and a static
 * host sent the page, which is no Rooms server. */
export function serverInUse(
	chosen: string | null = chosenServer(),
	page: URL = pageBase(),
	served: boolean = servedByRooms(),
): ServerInUse | null {
	if (chosen != null) return { base: chosen, chosen: true };
	return served ? { base: page.href, chosen: false } : null;
}
