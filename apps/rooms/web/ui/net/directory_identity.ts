// User-directed identity changes for one held room directory.

import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { trouble } from "./common.ts";
import { dirs } from "./live.ts";

/** Release one directory-scoped nickname without discarding workspace intent.
 * The connection lifecycle clears the realized grant when it ends, then opens
 * an unnamed replacement while saved conversations await a later claim. */
export async function releaseDirectoryNick(dir: DirId): Promise<string> {
	const held = store.get().dirs.get(dir);
	if (held == null) return "That directory is no longer in this workspace.";
	store.setRequestedDirNick(dir, "");
	const live = dirs.get(dir);
	if (live == null) {
		store.setDirNick(dir, "");
		return "";
	}
	try {
		await live.dir.close();
	} catch (error) {
		// Clearing intent is the commit point. The terminal callback still owns
		// reconnection; this close consequence remains diagnostic.
		trouble("nickname release connection cleanup failed", error);
	}
	return "";
}
