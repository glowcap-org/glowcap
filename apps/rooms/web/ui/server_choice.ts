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

/** The fragment key a link uses to offer a shared session's use link. The
 * link is a capability, so it rides in the fragment, which a browser never
 * sends to the page's host, and never in the query. */
export const SESSION_OFFER = "attach";

/** A shared session a link offers, read from `page` and taken out of it, the
 * way `serverOffer` takes the server. The offer is the whole fragment, so a
 * room route is never mistaken for one. Null when the link offers none. */
export function sessionOffer(page: URL): { capability: string; rest: URL } | null {
	if (!page.hash.startsWith(`#${SESSION_OFFER}=`)) return null;
	const capability = new URLSearchParams(page.hash.slice(1)).get(SESSION_OFFER) ?? "";
	const rest = new URL(page);
	rest.hash = "";
	return { capability: capability.trim(), rest };
}

/** `page` offering `capability` the way `sessionOffer` reads it. */
export function withSessionOffer(page: URL, capability: string): URL {
	const offered = new URL(page);
	offered.hash = new URLSearchParams({ [SESSION_OFFER]: capability }).toString();
	return offered;
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

/** What a server at `base` says to this page before anything is saved, or
 * `blocked`: this browser stands between a page from the public internet and
 * a server on the person's own computer or network until they allow it. */
export type ServerProbe =
	| { readonly kind: "answers"; readonly directory: string }
	| { readonly kind: "elsewhere" }
	| { readonly kind: "refuses" }
	| { readonly kind: "silent" }
	| { readonly kind: "blocked"; readonly permission: LocalNetworkRefusal };

/** The browser's answer on reaching the local network from this page: asked
 * on the first try, refused, allowed, or null in a browser that never asks. */
export type LocalNetworkPermission = LocalNetworkRefusal | "granted" | null;
/** The two answers under which the browser lets nothing through. */
export type LocalNetworkRefusal = "prompt" | "denied";

/** The one question asked of the browser's permissions. The name is a
 * string because lib.dom lags the names browsers answer to. */
export interface PermissionsQuery {
	query(descriptor: { name: string }): Promise<{ state: PermissionState }>;
}

/** Where a host stands to the browser: this computer, the person's own
 * network, or the public internet, by the host name or address alone. */
export type AddressSpace = "loopback" | "local" | "public";

export function addressSpace(hostname: string): AddressSpace {
	const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
	if (host === "localhost" || host.endsWith(".localhost") || host === "::1") return "loopback";
	const v4 = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
	if (v4 != null) {
		const [a, b] = [Number(v4[1]), Number(v4[2])];
		if (a === 127) return "loopback";
		const local = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
			(a === 169 && b === 254);
		return local ? "local" : "public";
	}
	return /^f[cd][0-9a-f]{2}:/.test(host) || /^fe[89ab][0-9a-f]:/.test(host) ? "local" : "public";
}

/** Nearer to the person is more private. */
const PRIVACY: Record<AddressSpace, number> = { loopback: 0, local: 1, public: 2 };

/** Whether reaching `target` from this page crosses into a more private
 * space (a public page to the person's network or computer, or a page on the
 * network to this computer), which a browser may guard. */
export function reachesLocalNetwork(target: URL, page: string | undefined = globalThis.location?.hostname): boolean {
	return page != null && PRIVACY[addressSpace(target.hostname)] < PRIVACY[addressSpace(page)];
}

/** Why a browser on a page from the public internet may be the reason a local
 * server does not answer: its local network permission, when reaching
 * `target` crosses into the local network, else null. Chrome asks the person
 * on the first read and refuses in silence until they allow it; a browser
 * without the permission answers null. */
export function localNetworkBlock(
	target: URL,
	{ page = globalThis.location?.hostname, permissions = globalThis.navigator?.permissions }: {
		page?: string;
		permissions?: PermissionsQuery;
	} = {},
): Promise<LocalNetworkPermission> {
	if (permissions == null || !reachesLocalNetwork(target, page)) return Promise.resolve(null);
	return permissions.query({ name: "local-network-access" }).then((status) => status.state, () => null);
}

/** What a server probe reaches through, each replaceable in a test. */
export interface ProbeEffects {
	read?: (address: URL, init: RequestInit) => Promise<Response>;
	timeoutMs?: number;
	blocked?: (target: URL) => Promise<LocalNetworkPermission>;
}

/** How long a test waits for a server to answer. */
export const PROBE_TIMEOUT_MS = 5_000;

/** Ask the server at `base` for its directory the way the session will. A
 * read this page may see answers with the directory `names` accepts. A Rooms
 * server always has one, or answers 503 while it starts, so any other reply is
 * from somewhere else, or from a server still starting.
 * A browser hides why a cross-origin read failed, so an opaque read of the
 * same route tells the two causes apart: it resolves whenever something
 * answers, so the server is there and turned this page away. When neither
 * resolves, nothing answered, unless this browser is what stands in the way. */
export async function probeServer(
	base: string,
	names: (text: string) => boolean,
	{ read = fetch, timeoutMs = PROBE_TIMEOUT_MS, blocked = localNetworkBlock }: ProbeEffects = {},
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
		// tolerant: the browser's own answer below says whether it is the cause.
	}
	const permission = await blocked(locator);
	return permission === "prompt" || permission === "denied" ? { kind: "blocked", permission } : { kind: "silent" };
}
