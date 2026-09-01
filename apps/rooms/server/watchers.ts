// Directory-wide observers of live room and registration state.

import type { TroubleJournal } from "./journal.ts";
import { type Argument, type Ref, type Session } from "@pancake/runtime";
import { NOTIFY, type RoomRecordShape } from "../lib/protocol.ts";

/** One directory watcher per session, bounded so notification work cannot be
 * multiplied without limit by watcher registrations. */
export const MAX_WATCHERS = 256;

export type Watcher = {
	observer: Ref;
	session: Session;
	records: RoomRecordShape;
};

export class WatcherTable implements Iterable<Watcher> {
	readonly #bySession = new Map<Session, Watcher>();

	constructor(readonly journal: TroubleJournal) {}

	get length(): number {
		return this.#bySession.size;
	}

	push(watcher: Watcher): number {
		if (this.#bySession.size >= MAX_WATCHERS) {
			throw new Error(`this directory already has ${MAX_WATCHERS} watchers`);
		}
		this.#bySession.set(watcher.session, watcher);
		return this.#bySession.size;
	}

	delete(session: Session): Watcher | undefined {
		const watcher = this.#bySession.get(session);
		if (watcher === undefined) return undefined;
		this.#bySession.delete(session);
		return watcher;
	}

	[Symbol.iterator](): Iterator<Watcher> {
		return this.#bySession.values();
	}
}

/** Push one delta to every watcher. A failed notification is not liveness
 * authority: session retirement owns removal, while the exact failure remains
 * observable to the process that owns this server. */
export function notifyWatchers(
	watchers: WatcherTable,
	args: Argument[],
	publicationArgs: Argument[] = args,
): void {
	for (const watcher of [...watchers]) {
		const delivered = watcher.records === "publication" ? publicationArgs : args;
		watcher.session.tell(watcher.observer, NOTIFY, delivered).catch((error) => {
			if (!watcher.session.sessionOpen) {
				dropWatchers(watchers, watcher.session);
				return;
			}
			watchers.journal.note("a directory watcher notification failed", error);
		});
	}
}

export function dropWatchers(watchers: WatcherTable, session: Session): void {
	const watcher = watchers.delete(session);
	if (watcher === undefined) return;
	watchers.journal.release(watcher.session, watcher.observer, "directory watcher");
}
