// The in-memory authority for retained room lines.
//
// Storage adapters feed their current rows through this one index at startup,
// then persist only transitions the index has admitted. That gives memory,
// JSONL, and PostgreSQL one retention policy: 500 lines per room, a bounded
// number of rooms and lines for the whole server, and whole-room eviction at
// the global edge so a busy server does not rewrite another room on every
// post. This module performs no I/O.

import { lineCost, MAX_LINE, MAX_NICK, MAX_ROOM } from "../lib/limits.ts";

/** One immutable retained row. */
export interface KeptLine {
	readonly from: string;
	readonly text: string;
	readonly at: number;
}

/** A row made by this live process. Its token is the line capability's exact
 * mutation authority. At most one exists per retained live line (4,096 for the
 * server); storage projects only KeptLine's durable fields, so restored rows
 * have no token and no later room generation can govern them. */
export interface LiveKeptLine extends KeptLine {
	readonly token: symbol;
}

export function liveKeptLine(from: string, text: string, at: number): LiveKeptLine {
	return { from, text, at, token: Symbol() };
}

/** One room's visible tail. */
export const LINES_KEPT = 500;
/** Whole-server resident bounds. At MAX_LINE, the text held below is at most
 * 32 MiB of UTF-8 plus bounded names and object overhead. */
export const HISTORY_LINES_KEPT = 4_096;
export const HISTORY_ROOMS_KEPT = 256;

export interface HistoryRestoreTarget {
	/** Transfer one parsed room tail, oldest first, into the policy owner. */
	restoreRoom(room: string, lines: KeptLine[]): void;
}

interface KeptRoom {
	readonly name: string;
	readonly lines: KeptLine[];
}

function validateRoom(room: string): void {
	if (room.length === 0 || room.length > MAX_ROOM) {
		throw new Error(`room history has an invalid room name ${JSON.stringify(room)}`);
	}
}

/** Refuse persisted or newly admitted state that no room could have produced.
 * File storage calls this while streaming over old compactable rows too, so an
 * invalid row cannot hide just beyond the visible tail. */
export function assertValidKeptLine(room: string, line: KeptLine): void {
	if (
		line.from.length === 0 || line.from.length > MAX_NICK || lineCost(line.text) > MAX_LINE ||
		!Number.isSafeInteger(line.at) || line.at < 0
	) {
		throw new Error(`room history for ${room} contains an invalid line`);
	}
}

/** The one live tail owner. All mutators answer the room names whose complete
 * retained tail left at the global edge; adapters delete those rooms after
 * persisting the triggering operation. */
export class HistoryIndex implements HistoryRestoreTarget {
	readonly #rooms = new Map<string, KeptRoom>();
	#lines = 0;
	readonly #evicted = new Map<string, string>();
	readonly #restored = new Set<string>();

	clear(): void {
		this.#rooms.clear();
		this.#evicted.clear();
		this.#restored.clear();
		this.#lines = 0;
	}

	restoreRoom(room: string, lines: KeptLine[]): void {
		validateRoom(room);
		const key = room.toLowerCase();
		if (this.#restored.has(key)) throw new Error(`room history repeats ${JSON.stringify(room)}`);
		this.#restored.add(key);
		for (const line of lines) {
			assertValidKeptLine(room, line);
		}
		if (lines.length > LINES_KEPT) lines.splice(0, lines.length - LINES_KEPT);
		if (lines.length === 0) return;
		this.#rooms.set(key, { name: room, lines });
		this.#lines += lines.length;
		this.#enforceBounds();
	}

	record(room: string, line: KeptLine): string | null {
		validateRoom(room);
		assertValidKeptLine(room, line);
		const key = room.toLowerCase();
		let kept = this.#rooms.get(key);
		if (kept === undefined) {
			kept = { name: room, lines: [] };
			this.#rooms.set(key, kept);
		}
		kept.lines.push(line);
		this.#lines++;
		if (kept.lines.length > LINES_KEPT) {
			kept.lines.shift();
			this.#lines--;
		}
		if (this.#rooms.size > HISTORY_ROOMS_KEPT || this.#lines > HISTORY_LINES_KEPT) {
			return this.#evictOldest();
		}
		return null;
	}

	/** Forget only the exact row retained by the calling line capability. */
	forget(room: string, target: LiveKeptLine): KeptLine[] | null {
		const kept = this.#rooms.get(room.toLowerCase());
		if (kept === undefined) return null;
		const at = kept.lines.findIndex((line) => "token" in line && line.token === target.token);
		if (at === -1) return null;
		kept.lines.splice(at, 1);
		this.#lines--;
		if (kept.lines.length === 0) this.#rooms.delete(room.toLowerCase());
		return [...kept.lines];
	}

	/** Edit only the exact row retained by the calling line capability. */
	update(room: string, target: LiveKeptLine, text: string): KeptLine[] | null {
		if (lineCost(text) > MAX_LINE) throw new Error(`room history for ${room} contains an oversized edit`);
		const kept = this.#rooms.get(room.toLowerCase());
		if (kept === undefined) return null;
		const at = kept.lines.findIndex((line) => "token" in line && line.token === target.token);
		if (at === -1) return null;
		kept.lines[at] = { ...kept.lines[at], text };
		return [...kept.lines];
	}

	read(room: string, limit: number): KeptLine[] {
		return this.#rooms.get(room.toLowerCase())?.lines.slice(-limit) ?? [];
	}

	takeEvicted(): string[] {
		const names = [...this.#evicted.values()];
		this.#evicted.clear();
		return names;
	}

	#enforceBounds(): void {
		while (this.#rooms.size > HISTORY_ROOMS_KEPT || this.#lines > HISTORY_LINES_KEPT) {
			const evicted = this.#evictOldest();
			if (evicted === null) return;
			this.#evicted.set(evicted.toLowerCase(), evicted);
		}
	}

	#evictOldest(): string | null {
		let oldest: KeptRoom | null = null;
		for (const room of this.#rooms.values()) {
			if (oldest === null) oldest = room;
			else {
				const roomAt = room.lines.at(-1)!.at;
				const oldestAt = oldest.lines.at(-1)!.at;
				if (roomAt < oldestAt || (roomAt === oldestAt && room.name < oldest.name)) oldest = room;
			}
		}
		if (oldest === null) return null;
		this.#rooms.delete(oldest.name.toLowerCase());
		this.#lines -= oldest.lines.length;
		return oldest.name;
	}
}
