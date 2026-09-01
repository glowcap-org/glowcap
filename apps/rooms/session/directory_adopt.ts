// Hand a live directory session to DurableRoomsRuntime instead of redialing it.
// A Host keeps one session per peer; closing and reconnecting is what dropped
// the WebRTC inbox DMs already had filed. The granted nick travels with the
// session so hosted re-register keeps the name this tab already is.

import type { Directory } from "../lib/room/client.ts";
import { roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";

export interface AdoptedDirectory {
	readonly directory: Directory;
	readonly nick: string;
}

let pendingAdopted: Map<string, AdoptedDirectory> | null = null;

export function adoptDirectories(directories: Map<string, AdoptedDirectory>): void {
	pendingAdopted = directories;
}

/** The name hosted re-register must use: the grant Share stole, else the checkpoint request. */
export function adoptedRegistrationNick(
	savedNick: string,
	adopted: AdoptedDirectory | undefined,
): string {
	if (adopted != null && adopted.nick !== "") return adopted.nick;
	return savedNick;
}

export function takeAdoptedDirectory(id: string, locator?: string): AdoptedDirectory | undefined {
	const held = pendingAdopted;
	if (held == null) return undefined;
	const existing = held.get(id) ?? takeByLocator(held, locator);
	if (existing != null) {
		for (const [key, row] of held) {
			if (row === existing || row.directory === existing.directory) held.delete(key);
		}
	}
	return existing;
}

function takeByLocator(
	held: Map<string, AdoptedDirectory>,
	locator: string | undefined,
): AdoptedDirectory | undefined {
	if (locator == null || locator === "") return undefined;
	try {
		return held.get(roomsPeerAuthority(roomsLocator(locator)));
	} catch {
		return undefined;
	}
}
