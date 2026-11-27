// A tab pins the workspace it has open. The choice on this browser survives
// the tab and selects the next cold launch. Neither record contains access.
import { LocalRefusal } from "../../lib/text/failure.ts";
import { coverForReload, finishCoveredReload } from "./boot.ts";
import { localArea, type PageStorage, sessionArea } from "./page_storage.ts";

const TAB = "rooms.managed-tab";
const LAST = "rooms.last-workspace";
const PREFIX = "rooms.workspace-choice.";
const validId = (id: string) => /^[a-zA-Z0-9-]{1,64}$/.test(id);

export function pinWorkspace(id: string): LocalRefusal | null {
	if (!validId(id)) return new LocalRefusal("tab-identity-invalid");
	return sessionArea.write(TAB, id);
}

/** Switch the browser's view without detaching or resetting its current
 * session. A new tab identity takes setup to the chooser. */
export function chooseWorkspace(id: string | null, toFront = false): LocalRefusal | null {
	const prior = sessionArea.read(TAB);
	const refused = pinWorkspace(id ?? crypto.randomUUID());
	if (refused) return refused;
	if (id !== null) {
		const choice = recordWorkspaceChoice(true);
		if (choice) {
			const rollback = prior === null ? sessionArea.remove(TAB) : pinWorkspace(prior);
			return rollback ?? choice;
		}
	}
	coverForReload();
	finishCoveredReload(toFront);
	return null;
}

export function tabIdentity(storage: PageStorage = sessionArea): string {
	let id = storage.read(TAB);
	if (id === null) {
		id = crypto.randomUUID();
		const refused = storage.write(TAB, id);
		if (refused) throw refused;
	}
	if (!validId(id)) throw new LocalRefusal("tab-identity-invalid");
	return id;
}

// The previous release already recorded these choices. They are an index
// into IndexedDB, where the session identity and its access actually live.
export function pinnedWorkspace(): string | null {
	const id = sessionArea.read(TAB);
	return id !== null && validId(id) && localArea.read(PREFIX + id) === "yes" ? id : null;
}

export function workspaceChosen(): boolean {
	return pinnedWorkspace() !== null;
}

export function recordWorkspaceChoice(chosen: boolean): LocalRefusal | null {
	if (chosen) return localArea.write(PREFIX + tabIdentity(), "yes");
	const id = sessionArea.read(TAB);
	return id === null ? null : localArea.remove(PREFIX + id);
}

/** Fallback when this browser cannot list its databases. Opening a candidate
 * still requires the existing private identity and committed workspace. */
export function markedWorkspaces(): string[] {
	return localArea.keys().filter((key) => key.startsWith(PREFIX) && localArea.read(key) === "yes")
		.map((key) => key.slice(PREFIX.length)).filter(validId).sort();
}

export function lastWorkspace(): string | null {
	const last = localArea.read(LAST);
	return last !== null && validId(last) ? last : null;
}

export function coldWorkspace(): string | null {
	if (sessionArea.read(TAB) !== null) return null;
	const last = lastWorkspace();
	return last !== null && localArea.read(PREFIX + last) === "yes" ? last : null;
}

/** Remember only a workspace that actually opened, including its saved access. */
export function rememberOpenWorkspace(): LocalRefusal | null {
	const id = tabIdentity();
	return localArea.read(LAST) === id ? null : localArea.write(LAST, id);
}
