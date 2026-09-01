// Stop and restore this tab's local directory sessions around in-tab hosting.
// Drain does not leave rooms or forget holdings. DurableRoomsRuntime then
// takes the live directory sessions as the same Host identity. A failed Share
// puts local net back only after those sessions have closed: one session per peer.

import * as store from "../store.ts";
import { forgetOfferer } from "./reachable.ts";
import { openDirectory, releaseSession } from "./connection.ts";
import { FIRST_BACKOFF_MS } from "./bootstrap.ts";
import type { RoomsPageContext } from "../page.ts";
import type { AdoptedDirectory } from "../../../session/directory_adopt.ts";

/** Take this tab's live directory sessions without closing them, so the hosted
 * runtime can keep the same Host sessions DMs already signal through. The
 * granted nick travels with each session: the checkpoint stores the request,
 * and re-registering that when a suffix was granted is nick-taken. */
export function stealHeldDirectories(page: RoomsPageContext): Map<string, AdoptedDirectory> {
	page.connections.drainAll();
	const stolen = new Map<string, AdoptedDirectory>();
	for (const live of [...page.live.dirs.values()]) {
		stolen.set(live.id, {
			directory: live.dir,
			nick: store.dirNick(page.projection, live.id),
		});
		releaseSession(live, { keepTransport: true });
	}
	for (const dir of [...page.reachable.offerers.keys()]) forgetOfferer(page, dir);
	return stolen;
}

export function reconnectHeldDirectories(page: RoomsPageContext): void {
	void openDirectory(page, null, FIRST_BACKOFF_MS);
	const home = page.projection.get().homeDir;
	for (const directory of page.projection.get().dirs.values()) {
		if (directory.id === home) continue;
		void openDirectory(page, directory.locator, FIRST_BACKOFF_MS);
	}
}
