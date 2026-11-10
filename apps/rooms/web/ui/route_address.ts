// Canonical browser addresses for Rooms presentation state.

import type { Given } from "./intent.ts";

/** Keep only the page-startup choices that every navigable Rooms address
 * carries. Modal and pane state never belongs in a shared URL. */
export function pageSearch(): URLSearchParams {
	const here = new URLSearchParams(location.search);
	const kept = new URLSearchParams();
	const dm = here.get("dm");
	if (dm !== null) kept.set("dm", dm);
	return kept;
}

export function withPageSearch(path: string, search: URLSearchParams = pageSearch()): string {
	const text = search.toString();
	return text === "" ? path : `${path}?${text}`;
}

/** `path` naming `fields` after `#`. A browser sends the page host an
 * address's path and query and keeps its fragment, and a directory or join
 * address may carry a capability. So the query holds only `pageSearch`, and
 * everything else an address names is a fragment field. */
function withFields(path: string, fields: URLSearchParams): string {
	const text = fields.toString();
	return withPageSearch(path) + (text === "" ? "" : `#${text}`);
}

/** The fields `withFields` wrote into an address. */
export function addressFields(at: { hash: string }): URLSearchParams {
	return new URLSearchParams(at.hash.slice(1));
}

/** A location as one address, in the form the functions here write. */
export function addressAt(at: { pathname: string; search: string; hash: string }): string {
	return `${at.pathname}${at.search}${at.hash}`;
}

export function roomAddress(
	name: string,
	options: { directory?: string; private?: boolean } = {},
): string {
	const fields = new URLSearchParams();
	if (options.directory != null) fields.set("dir", options.directory);
	if (options.private === true) fields.set("private", "1");
	return withFields(`/room/${encodeURIComponent(name)}`, fields);
}

/** The join card, and what it was asked to reach for.
 *
 * An address is a claim about what the reader is looking at, and a route that
 * names a room it cannot open does not stop being that claim just because it
 * failed. Landing on the card while the address still says `/room/lobby` makes
 * Back, Reload, and a copied link each promise a room the page never showed,
 * and the reader's own history records a visit that did not happen. So a route
 * that ends at the card says so, and `/join` is the one route that files the
 * act: the routes that fall back to the card only say where they landed.
 *
 * `room` and `address` are what the link named outright. `directory` is the
 * other way a card knows where it is: standing on a room address implies the
 * directory that room is on, whether or not anybody wrote it down, and that is
 * the same `dir=` a room address carries for the same fact. An empty `dir=` is
 * this page's own directory, which is how the card says "here", because the
 * store keeps that as an empty address and the address has to round-trip what
 * the store holds or the two will keep correcting each other. */
export function joinAddress(options: { room?: string; address?: string; directory?: string } = {}): string {
	const fields = new URLSearchParams();
	if (options.room != null) fields.set("room", options.room);
	if (options.address != null) fields.set("address", options.address);
	if (options.directory != null) fields.set("dir", options.directory);
	return withFields("/join", fields);
}

/** The address of the card as a filed act shows it, so the address mirror can
 * keep the two in step. Only what was named or implied goes in. A field the act
 * says nothing about is a field the address says nothing about. */
export function joinAddressOf(act: { room?: Given<string>; address?: Given<string> }): string {
	return joinAddress({
		room: act.room?.firmness === "named" ? act.room.value : undefined,
		address: act.address?.firmness === "named" ? act.address.value : undefined,
		directory: act.address?.firmness === "implied" ? act.address.value : undefined,
	});
}

/** A direct conversation, named by the nick it is with. */
export function dmAddress(nick: string): string {
	return withPageSearch(`/dm/${encodeURIComponent(nick)}`);
}

/** This page's directory is `/directory`; any other is `/directory#dir=`. */
export function directoryAddress(options: { directory?: string } = {}): string {
	const fields = new URLSearchParams();
	if (options.directory != null) fields.set("dir", options.directory);
	return withFields("/directory", fields);
}
