// Canonical browser addresses for Rooms presentation state.

import type { Given } from "./intent.ts";

/** Keep only the page-startup choices that every navigable Rooms address
 * carries. Modal and pane state never belongs in a shared URL. */
export function pageSearch(): URLSearchParams {
	const here = new URLSearchParams(location.search);
	const kept = new URLSearchParams();
	for (const name of ["dm", "trace"]) {
		const value = here.get(name);
		if (value !== null) kept.set(name, value);
	}
	return kept;
}

export function withPageSearch(path: string, search: URLSearchParams = pageSearch()): string {
	const text = search.toString();
	return text === "" ? path : `${path}?${text}`;
}

export function roomAddress(
	name: string,
	options: { directory?: string; private?: boolean } = {},
): string {
	const search = pageSearch();
	if (options.directory != null) search.set("dir", options.directory);
	if (options.private === true) search.set("private", "1");
	return withPageSearch(`/room/${encodeURIComponent(name)}`, search);
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
 * `room` and `locator` are what the link named outright. `directory` is the
 * other way a card knows where it is: standing on a room address implies the
 * directory that room is on, whether or not anybody wrote it down, and that is
 * the same `dir=` a room address carries for the same fact. An empty `dir=` is
 * this page's own directory, which is how the card says "here", because the
 * store keeps that as an empty locator and the address has to round-trip what
 * the store holds or the two will keep correcting each other. */
export function joinAddress(options: { room?: string; locator?: string; directory?: string } = {}): string {
	const search = pageSearch();
	if (options.room != null) search.set("room", options.room);
	if (options.locator != null) search.set("locator", options.locator);
	if (options.directory != null) search.set("dir", options.directory);
	return withPageSearch("/join", search);
}

/** The address of the card as a filed act shows it, so the address mirror can
 * keep the two in step. Only what was named or implied goes in; a field the act
 * says nothing about is a field the address says nothing about. */
export function joinAddressOf(act: { room?: Given<string>; locator?: Given<string> }): string {
	return joinAddress({
		room: act.room?.firmness === "named" ? act.room.value : undefined,
		locator: act.locator?.firmness === "named" ? act.locator.value : undefined,
		directory: act.locator?.firmness === "implied" ? act.locator.value : undefined,
	});
}

/** This page's directory is `/directory`; any other is `/directory?dir=`. */
export function directoryAddress(options: { directory?: string } = {}): string {
	const search = pageSearch();
	if (options.directory != null) search.set("dir", options.directory);
	return withPageSearch("/directory", search);
}
