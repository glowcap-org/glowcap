// Monotonic revision and bounded OCapN observers for the Rooms operator's
// cross-owner inventory. One instance belongs to one RoomServer.

import { type Ref, type Session } from "@glowcap/runtime";
import { OPERATOR_CHANGED } from "../../lib/protocol_operator.ts";
import { settleCapabilityCleanup } from "../../lib/capability_cleanup.ts";

/** One callback per attached operator session. The callback is a capability
 * held by the server until the operator holder explicitly unsubscribes or the
 * session closes. */
export const MAX_OPERATOR_WATCHERS = 256;

type OperatorWatcher = { session: Session; observer: Ref; stopClose: () => void };

export class OperatorRevision {
	#revision = 0n;
	readonly #watchers = new Map<Session, OperatorWatcher>();
	#holding = 0;
	#missed = false;

	get current(): bigint {
		return this.#revision;
	}

	async watch(session: Session, observer: Ref): Promise<bigint> {
		this.dropWatcher(session);
		if (this.#watchers.size >= MAX_OPERATOR_WATCHERS) {
			releaseObserver(session, observer);
			throw new Error(`this Rooms operator already has ${MAX_OPERATOR_WATCHERS} watchers`);
		}
		const watcher: OperatorWatcher = { session, observer, stopClose: () => {} };
		try {
			watcher.stopClose = session.onClose(() => this.dropWatcher(session));
		} catch (error) {
			releaseObserver(session, observer);
			throw error;
		}
		this.#watchers.set(session, watcher);
		// Closing the registration race: the holder gets the revision that was
		// current when its watch became authoritative, even if no later mutation
		// occurs before its first refresh.
		try {
			await session.tell(observer, OPERATOR_CHANGED, [this.#revision]);
			if (this.#watchers.get(session) !== watcher) {
				throw new Error("the Rooms operator watch ended during admission");
			}
			return this.#revision;
		} catch (error) {
			if (this.#watchers.get(session) === watcher) this.dropWatcher(session);
			throw error;
		}
	}

	dropWatcher(session: Session): void {
		const watcher = this.#watchers.get(session);
		if (watcher == null) return;
		this.#watchers.delete(session);
		release(watcher);
	}

	/** How many bulk acts are running. While one is, the revision still advances
	 * on every row — it is the inventory's authority and cannot be batched — but
	 * watchers are told once at the end instead of once per row. A sweep over a
	 * hundred thousand rows would otherwise send a hundred thousand notices, and
	 * every one of them asks its holder to read the inventory again. */
	async holdNotices<T>(run: () => Promise<T>): Promise<T> {
		this.#holding += 1;
		try {
			return await run();
		} finally {
			this.#holding -= 1;
			if (this.#holding === 0 && this.#missed) {
				this.#missed = false;
				this.#announce();
			}
		}
	}

	noteChange(): void {
		this.#revision += 1n;
		if (this.#holding > 0) {
			this.#missed = true;
			return;
		}
		this.#announce();
	}

	#announce(): void {
		for (const watcher of this.#watchers.values()) {
			watcher.session.tell(watcher.observer, OPERATOR_CHANGED, [this.#revision]).catch((error) => {
				console.error(
					`rooms: operator watcher notification failed: ${error instanceof Error ? error.message : error}`,
				);
				this.dropWatcher(watcher.session);
			});
		}
	}
}

function releaseObserver(session: Session, observer: Ref): void {
	settleCapabilityCleanup("operator watcher release failed", () => session.release(observer));
}

function release(watcher: OperatorWatcher): void {
	settleCapabilityCleanup("operator watcher close observer cleanup failed", () => watcher.stopClose());
	releaseObserver(watcher.session, watcher.observer);
}
