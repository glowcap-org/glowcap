// User-directed identity changes for one held room directory.

import * as store from "../store.ts";
import { trouble } from "./common.ts";
import type { RoomsPageContext } from "../page.ts";
import type { DirId } from "../types.ts";
/** Release one directory-scoped nickname without discarding workspace intent.
 * The connection lifecycle clears the realized grant when it ends, then opens
 * an unnamed replacement while saved conversations await a later claim. */
export async function releaseDirectoryNick(page: RoomsPageContext, dir: DirId): Promise<string> {
	const held = page.projection.get().dirs.get(dir);
	if (held == null) return "That directory is no longer in this workspace.";
	store.setRequestedDirNick(page.projection, dir, "");
	const live = page.live.dirs.get(dir);
	if (live == null) {
		store.setDirNick(page.projection, dir, "");
		return "";
	}
	try {
		await live.dir.close();
	} catch (error) {
		// Clearing intent is the commit point. The terminal callback still owns
		// reconnection; this close consequence remains diagnostic.
		trouble(page.projection, "nickname release connection cleanup failed", error);
	}
	return "";
}
