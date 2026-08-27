// Monotonic revision and bounded OCapN observers for the Rooms operator's
// cross-owner inventory.

import { type Ref, type Session } from "@pancake/runtime";
import { OPERATOR_CHANGED } from "../../lib/protocol.ts";
import { settleCapabilityCleanup } from "../../lib/capability_cleanup.ts";

let revision = 0n;

/** One callback per attached operator session. The callback is a capability
 * held by the server until the operator holder explicitly unsubscribes or the
 * session closes. */
export const MAX_OPERATOR_WATCHERS = 256;
type OperatorWatcher = { session: Session; observer: Ref; stopClose: () => void };
const watchers = new Map<Session, OperatorWatcher>();

function releaseObserver(session: Session, observer: Ref): void {
	settleCapabilityCleanup("operator watcher release failed", () => session.release(observer));
}

function release(watcher: OperatorWatcher): void {
	settleCapabilityCleanup("operator watcher close observer cleanup failed", () => watcher.stopClose());
	releaseObserver(watcher.session, watcher.observer);
}

export async function watchOperator(session: Session, observer: Ref): Promise<bigint> {
	dropOperatorWatcher(session);
	if (watchers.size >= MAX_OPERATOR_WATCHERS) {
		releaseObserver(session, observer);
		throw new Error(`this Rooms operator already has ${MAX_OPERATOR_WATCHERS} watchers`);
	}
	const watcher: OperatorWatcher = { session, observer, stopClose: () => {} };
	try {
		watcher.stopClose = session.onClose(() => dropOperatorWatcher(session));
	} catch (error) {
		releaseObserver(session, observer);
		throw error;
	}
	watchers.set(session, watcher);
	// Closing the registration race: the holder gets the revision that was
	// current when its watch became authoritative, even if no later mutation
	// occurs before its first refresh.
	try {
		await session.tell(observer, OPERATOR_CHANGED, [revision]);
		if (watchers.get(session) !== watcher) throw new Error("the Rooms operator watch ended during admission");
		return revision;
	} catch (error) {
		if (watchers.get(session) === watcher) dropOperatorWatcher(session);
		throw error;
	}
}

export function dropOperatorWatcher(session: Session): void {
	const watcher = watchers.get(session);
	if (watcher == null) return;
	watchers.delete(session);
	release(watcher);
}

/** How many bulk acts are running. While one is, the revision still advances
 * on every row — it is the inventory's authority and cannot be batched — but
 * watchers are told once at the end instead of once per row. A sweep over a
 * hundred thousand rows would otherwise send a hundred thousand notices, and
 * every one of them asks its holder to read the inventory again. */
let holding = 0;
let missed = false;

export async function holdOperatorNotices<T>(run: () => Promise<T>): Promise<T> {
	holding += 1;
	try {
		return await run();
	} finally {
		holding -= 1;
		if (holding === 0 && missed) {
			missed = false;
			announceOperatorChange();
		}
	}
}

function announceOperatorChange(): void {
	for (const watcher of watchers.values()) {
		watcher.session.tell(watcher.observer, OPERATOR_CHANGED, [revision]).catch((error) => {
			console.error(
				`rooms: operator watcher notification failed: ${error instanceof Error ? error.message : error}`,
			);
			dropOperatorWatcher(watcher.session);
		});
	}
}

export function noteOperatorChange(): void {
	revision += 1n;
	if (holding > 0) {
		missed = true;
		return;
	}
	announceOperatorChange();
}

export function operatorRevision(): bigint {
	return revision;
}
