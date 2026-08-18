// Directory-wide observers of live room and registration state.

import type { Ref, Session } from "@pancake/runtime";
import { NOTIFY } from "../lib/protocol.ts";
import { handBack } from "./registry.ts";

export const watchers: { observer: Ref; session: Session }[] = [];

/** Push one delta to every watcher. A failed notification is not liveness
 * authority: session retirement owns removal, while the exact failure remains
 * observable to the process that owns this server. */
export function notifyWatchers(event: string, name: string, count: number): void {
	for (const watcher of [...watchers]) {
		watcher.session.tell(watcher.observer, NOTIFY, [event, name, BigInt(count)]).catch((error) => {
			if (!watcher.session.sessionOpen) {
				dropWatchers(watcher.session);
				return;
			}
			console.error(`[rooms] directory watcher notification failed: ${error}`);
		});
	}
}

export function dropWatchers(session: Session): void {
	for (let i = watchers.length - 1; i >= 0; i -= 1) {
		if (watchers[i].session !== session) continue;
		const [watcher] = watchers.splice(i, 1);
		handBack(watcher.session, watcher.observer, "directory watcher");
	}
}
