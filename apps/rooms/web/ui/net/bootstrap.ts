// How the page finds the directory it belongs to, and how long it waits before
// trying again.
//
// A tab is served by one room server and may hold several directories, so
// "which directory" has three different answers depending on who is asking: the
// page's own, the one a reader typed, and the one already in hand. Keeping them
// side by side is the point — each is a different question, and answering one
// with another is how a room ends up opened against the wrong server.

import { INVALID_ARGUMENT } from "@pancake/abi";
import type { WebRuntime } from "@pancake/web";
import { type Locator, PancakeError } from "@pancake/runtime";
import { parseRoomsSturdyref, roomsAddress, roomsLocator } from "../../../lib/locator.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import * as store from "../store.ts";
import * as prefs from "../prefs.ts";
import { type DirId, dirId } from "../types.ts";
import { anyLive, dirAddress, directoryLocators, dirs, type Live } from "./live.ts";
import type { Given } from "../intent.ts";

/** The one live directory, or null when there are several.
 *
 * With more than one open there is no such thing as "the" directory, and the
 * first one is this page's own — so a reader who joined somebody else's room
 * had every direct message they *started* signaled through a directory that had
 * never heard of the person they were writing to, while messages started from
 * the other side arrived perfectly well. Only a dial with no redeem behind it
 * reads this; the rest are routed by `signalingRoute`. */
export function soleLive(): Live | null {
	return dirs.size === 1 ? anyLive() : null;
}

/** The page's own directory, discovered from `/locator` and refreshed after its
 * live session ends. There is no companion holding whichever directory was
 * reached most recently: which directory the join card is about follows from
 * the act that put it up, and nothing outside it has a use for a "current"
 * directory that is neither this page's nor the one a surface was opened
 * about. */
let homeDirectoryLocator: string | null = null;

/** Name a directory by authority, excluding mutable routing hints, or null when
 * the shared grammar specifically refuses the text as an invalid argument.
 * Callers use null to reject an ordinary join-field mistake in the card; it is
 * not permission to continue with that text. Runtime, archive, and Wasm failures
 * propagate unchanged, because reporting those as malformed input hides the
 * broken component and sends the reader back to an address that was valid.
 *
 * The shared locator parser remains the grammar authority. Rooms files every
 * identity-proving transport under the same Host key; weak transports keep
 * their own transport/designator authority. */
export function directoryId(locator: string): DirId | null {
	// Empty text is the join field's resting state, not an address to parse:
	// asking the grammar about it made every fresh render a refusal.
	if (locator.trim() === "") return null;
	try {
		return directoryAuthority(roomsLocator(locator));
	} catch (err) {
		return invalidArgumentOrThrow(err);
	}
}

/** Turn the parser's one ordinary input refusal into the UI's null result.
 * Everything else still means the parser failed, not that its input was bad. */
function invalidArgumentOrThrow(error: unknown): null {
	if (error instanceof PancakeError && error.code === INVALID_ARGUMENT) return null;
	throw error;
}

/** The authority half of a parsed locator, which is what one directory is. */
function directoryAuthority(locator: Locator): DirId {
	return dirId(roomsPeerAuthority(locator));
}

/** The directory a room link belongs to: which one it is, and the address to
 * reach it at. Null only when the shared grammar rejects the text as an
 * invalid argument. Runtime, archive, and Wasm failures remain failures; a
 * valid link must never be reported as malformed because its parser is broken.
 *
 * A link is a sturdyref, so it carries its own peer. That is what makes it
 * reachable from a tab that has never heard of the server hosting the room.
 * Both halves come back because they answer different questions: the authority
 * says whether this tab already holds that directory, and the address is what a
 * dial needs if it does not. */
export function linkDirectory(link: string): { id: DirId; address: string } | null {
	try {
		const { locator } = parseRoomsSturdyref(link.trim());
		return { id: directoryAuthority(locator), address: roomsAddress(locator) };
	} catch (err) {
		return invalidArgumentOrThrow(err);
	}
}

/** What a person is told when what they typed is not an address. One wording, so
 * the join card and the status line cannot describe the same mistake
 * differently. */
export function notALocator(locator: string): string {
	return "That does not look like an address: " + locator.trim();
}

export async function homeLocator(): Promise<string> {
	if (homeDirectoryLocator !== null) return homeDirectoryLocator;
	const locator = await prefs.directoryLocator();
	if (locator === null) throw new Error("rooms: locator not ready");
	homeDirectoryLocator = locator;
	return locator;
}

export async function requestedLocator(locator: string): Promise<string> {
	return locator.trim() || await homeLocator();
}

/** A directory an act carries, said the way the join card says directories.
 *
 * The card's locator field has its own vocabulary, and an act has to be filed
 * in it or the card answers a question nobody asked. This page's own directory
 * is the empty field, which is how the card says "here"; any other is the
 * freshest hinted route this tab holds, because the field's value is what a
 * submit dials and the hints are part of what makes it reachable. Text that is
 * not an address passes through untouched, since telling somebody so is the
 * card's job rather than this one's.
 *
 * The rule is enforced twice on purpose, and the two halves are not the same
 * rule. This one knows identity: it parses, so a bare authority, a hinted
 * route, and this page's own address are one answer. `thisDirectoryLocator`
 * over in `joining.ts` is the textual half, which is all a pure resolver can
 * do, and it covers what the reader typed. A locator every act carried through
 * here would still be one an act filed elsewhere could get wrong, which is why
 * every filer goes through this. */
export function actLocator(given: Given<string>): Given<string> {
	if (given.value.trim() === "") return given;
	const known = directoryId(given.value);
	if (known === null) return given;
	if (known === store.get().homeDir) return { ...given, value: "" };
	return { ...given, value: dirAddress(known) };
}

/** The address of the directory this page came from, and only that one.
 *
 * Settings is the one thing that asks, and Settings is about *this* directory:
 * the one the page was served by. Leaving its session does not change that
 * address. It used to answer with whichever directory the conversation on
 * screen happened to be on, so opening Settings while reading a room somewhere
 * else showed that somewhere else's address under a heading saying "this
 * directory" — two different directories, one label, and no way to tell which
 * you were looking at. Every other directory is described by its own card,
 * which is handed the one it is about. */
export function directoryLocator(): string | null {
	const home = store.get().homeDir;
	return (home === null ? null : directoryLocators.get(home)) ?? homeDirectoryLocator;
}

/** The directory a control acts on when nothing else names one.
 *
 * The conversation on screen answers it, because that is what a reader means by
 * "here"; with the join card up and nothing open, the first directory this tab
 * holds does. A caller that already holds the session it is acting for takes the
 * directory from that session instead and never asks this. */

let selectionReservedByAddress = false;

/** Keep reconnect/re-entry from choosing a conversation before an explicit
 * page address has acted. A later reader pick still wins through
 * An explicit join carries its own selection intent; this only distinguishes
 * an address-owned empty selection from an unclaimed front page. */
export function reserveSelectionForAddress(): void {
	selectionReservedByAddress = true;
}

export function automaticSelectionAvailable(): boolean {
	return !selectionReservedByAddress;
}

let runtimeReady: Promise<WebRuntime> | null = null;

/** The runtime this page drives, opened once and re-awaited afterwards.
 *
 * `open` is passed in rather than imported, so which wasm module and which
 * connectors compose the runtime stays a decision of the layer that composes
 * them. A rejected attempt is not kept: the wasm asset can lose a race against
 * the module that wants it, and a cached failure would make every reconnect
 * re-await that same failure forever instead of trying once the asset is live. */
export function readyRuntime(open: () => Promise<WebRuntime>): Promise<WebRuntime> {
	if (runtimeReady === null) {
		const attempt = open();
		attempt.catch(() => {
			if (runtimeReady === attempt) runtimeReady = null;
		});
		runtimeReady = attempt;
	}
	return runtimeReady;
}
export const FIRST_BACKOFF_MS = 500;
// A session must survive this long before its handshake counts as a stable
// connection worth resetting the backoff to 500. Below it, a server that accepts
// then drops keeps the exponential backoff climbing instead of storming.
export const BACKOFF_STABLE_MS = 10_000;
// The longest we wait between attempts. A room server being restarted is back in
// seconds, so a slower retry than this only makes the page look dead when it is
// not.
export const BACKOFF_CEILING_MS = 5_000;

/** Settles when the directory has answered with its first list of rooms.
 *
 * The rail waits on this before it says anything about which rooms exist,
 * because "no rooms" and "we have not asked yet" are different facts and only
 * one of them is ever true at load. It settles once and is never replaced, so a
 * later reconnect leaves the last known list on screen instead of blanking it. */
let announceDirectory: () => void = () => {};
export const directoryReady: Promise<void> = new Promise((resolve) => {
	announceDirectory = resolve;
});

/** Remember the address the page's own directory answered at, so Settings and a
 * later reconnect can still name it once that session has been retired. */
export function noteHomeDirectoryLocator(locator: string | null): void {
	homeDirectoryLocator = locator;
}

/** What that address was, if the page has learned it. */
export function heldHomeLocator(): string | null {
	return homeDirectoryLocator;
}

/** Say the page's directory is up, for whoever is waiting on `directoryReady`. */
export function announceDirectoryReady(): void {
	announceDirectory();
}
