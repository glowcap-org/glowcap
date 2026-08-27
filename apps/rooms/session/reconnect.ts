// Bounded retry timing for durable Rooms reconciliation.

import type { RoomsSessionState } from "../lib/rooms_state.ts";

const RECONNECT_FLOOR_MS = 1_000;
const RECONNECT_CEILING_MS = 30_000;

interface ConnectedDirectories {
	has(directory: string): boolean;
}

export function roomsReconciliationNeedsRetry(
	checkpoint: RoomsSessionState | null,
	connected: ConnectedDirectories,
	issueSubjects: Iterable<string>,
	closed: boolean,
): boolean {
	if (checkpoint == null || closed) return false;
	for (const directory of checkpoint.directories) if (!connected.has(directory.id)) return true;
	for (const subject of issueSubjects) {
		if (
			subject === "runtime" || subject === "archive" || subject.startsWith("direct:") ||
			subject.startsWith("direct-inbox:") || subject.startsWith("room:") ||
			subject.startsWith("room-irc:") || subject.startsWith("standing:") || subject.startsWith("peering:") ||
			(subject.startsWith("capability:") && !subject.startsWith("capability:viz\u0000"))
		) return true;
	}
	return false;
}

export class ReconnectSchedule<T> {
	#current: T | null = null;
	#timer: ReturnType<typeof setTimeout> | null = null;
	#delay = RECONNECT_FLOOR_MS;
	#closed = false;

	get current(): T | null {
		return this.#current;
	}

	update(value: T, resetBackoff = true): void {
		this.#current = value;
		if (!resetBackoff) return;
		if (this.#timer != null) clearTimeout(this.#timer);
		this.#timer = null;
		this.#delay = RECONNECT_FLOOR_MS;
	}

	settled(needsRetry: boolean, retry: (value: T) => Promise<void>): void {
		if (needsRetry) this.schedule(retry);
		else {
			if (this.#timer != null) clearTimeout(this.#timer);
			this.#timer = null;
			this.#delay = RECONNECT_FLOOR_MS;
		}
	}

	schedule(retry: (value: T) => Promise<void>): void {
		if (this.#closed || this.#timer != null || this.#current == null) return;
		const delay = this.#delay;
		this.#delay = Math.min(this.#delay * 2, RECONNECT_CEILING_MS);
		this.#timer = setTimeout(() => {
			this.#timer = null;
			const current = this.#current;
			if (current != null) {
				void retry(current).catch(() => {
					// The runtime reconciliation tail converts this failure into the
					// next bounded retry before the returned promise rejects.
				});
			}
		}, delay);
	}

	close(): void {
		this.#closed = true;
		if (this.#timer != null) clearTimeout(this.#timer);
		this.#timer = null;
	}
}
