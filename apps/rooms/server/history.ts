// What a room keeps of its own conversation, when this server keeps any.
//
// Retention is a stated policy, not a silent default: nothing records until
// the operator starts the server with `--history`, and the client's divider
// names the room as the keeper wherever these lines stand back up. Only
// listed rooms record. A private room is reference-only by design, and
// widening its retention is a decision its holders never made; the module
// head is where that boundary lives so the next reader finds it stated.
//
// The backend is deliberately boring: one JSONL file per room under the
// state directory, an in-memory tail bounded per room, the file compacted
// back to the tail when it has grown past twice the bound. The narrow verbs
// here — record, read — are the seam a heavier backend would stand behind;
// nothing outside this file knows lines live in files. Without a state
// directory the tail still serves, for the life of the process. Text lines
// only: a file's bytes already have a bounded owner in `files.ts`, and its
// caption arrives as an ordinary line.

import { noteTrouble } from "./journal.ts";

/** One kept line, exactly what a member needs to see it stand again. The
 * room's own line id rides along so an edit or a withdrawal reaches the kept
 * copy: history that outlives a takedown would break the promise withdraw
 * makes everywhere else. */
export interface KeptLine {
	readonly from: string;
	readonly text: string;
	readonly at: number;
	readonly id?: number;
}

/** How many lines one room keeps; the oldest fall off. */
const LINES_KEPT = 500;
/** Past this many lines on disk, the file is rewritten to the kept tail. */
const COMPACT_AT = LINES_KEPT * 2;

let directory: string | null = null;
let enabled = false;
const tails = new Map<string, KeptLine[]>();
const grown = new Map<string, number>();

/** Turn history on or off for this process, and say where the files live.
 * Called once at startup, before any room exists. */
export function initHistory(stateDirectory: string | null, keep: boolean): void {
	directory = stateDirectory;
	enabled = keep;
}

/** Whether this server keeps history at all, which is what the room verb
 * answers to. */
export function historyEnabled(): boolean {
	return enabled;
}

function fileFor(room: string): string | null {
	if (directory === null) return null;
	return `${directory}/history/${encodeURIComponent(room)}.jsonl`;
}

async function loadTail(room: string): Promise<KeptLine[]> {
	const held = tails.get(room);
	if (held !== undefined) return held;
	const tail: KeptLine[] = [];
	const path = fileFor(room);
	if (path !== null) {
		try {
			const text = await Deno.readTextFile(path);
			let count = 0;
			for (const line of text.split("\n")) {
				if (line === "") continue;
				count++;
				try {
					const row = JSON.parse(line);
					if (typeof row.from === "string" && typeof row.text === "string") {
						tail.push({
							from: row.from,
							text: row.text,
							at: typeof row.at === "number" ? row.at : 0,
							id: typeof row.id === "number" ? row.id : undefined,
						});
					}
				} catch {
					/* tolerant: one unreadable row loses one remembered line */
				}
			}
			grown.set(room, count);
			if (tail.length > LINES_KEPT) tail.splice(0, tail.length - LINES_KEPT);
		} catch {
			// A room with no file yet is a room with nothing kept.
			grown.set(room, 0);
		}
	}
	tails.set(room, tail);
	return tail;
}

/** Keep one line for a room. Fire-and-forget from the post path: the line is
 * already broadcast, and losing a remembered copy can never be worth
 * refusing the post. */
export function recordRoomLine(room: string, line: KeptLine): void {
	if (!enabled) return;
	void (async () => {
		try {
			const tail = await loadTail(room);
			tail.push(line);
			if (tail.length > LINES_KEPT) tail.shift();
			const path = fileFor(room);
			if (path === null) return;
			await Deno.mkdir(`${directory}/history`, { recursive: true, mode: 0o700 });
			const count = (grown.get(room) ?? 0) + 1;
			if (count >= COMPACT_AT) {
				// Rewrite to the kept tail through a temp file, so a crash
				// mid-compact leaves the old file whole rather than half of one.
				const temp = `${path}.tmp`;
				await Deno.writeTextFile(temp, tail.map((row) => JSON.stringify(row)).join("\n") + "\n");
				await Deno.rename(temp, path);
				grown.set(room, tail.length);
				return;
			}
			grown.set(room, count);
			await Deno.writeTextFile(path, JSON.stringify(line) + "\n", { append: true });
		} catch (error) {
			noteTrouble(`could not keep a line for ${room}`, error);
		}
	})();
}

/** Rewrite a room's file to its current tail, through a temp rename so a
 * crash mid-write leaves the old file whole. */
async function rewrite(room: string, tail: KeptLine[]): Promise<void> {
	const path = fileFor(room);
	if (path === null) return;
	await Deno.mkdir(`${directory}/history`, { recursive: true, mode: 0o700 });
	const temp = `${path}.tmp`;
	await Deno.writeTextFile(temp, tail.map((row) => JSON.stringify(row)).join("\n") + (tail.length > 0 ? "\n" : ""));
	await Deno.rename(temp, path);
	grown.set(room, tail.length);
}

/** A line was withdrawn: the kept copy goes with it, in memory and on disk.
 * Fire-and-forget for the same reason recording is. */
export function forgetRoomLine(room: string, id: number): void {
	if (!enabled) return;
	void (async () => {
		try {
			const tail = await loadTail(room);
			const at = tail.findIndex((line) => line.id === id);
			if (at === -1) return;
			tail.splice(at, 1);
			await rewrite(room, tail);
		} catch (error) {
			noteTrouble(`could not forget a withdrawn line for ${room}`, error);
		}
	})();
}

/** A line was edited: the kept copy says the new words. */
export function updateRoomLine(room: string, id: number, text: string): void {
	if (!enabled) return;
	void (async () => {
		try {
			const tail = await loadTail(room);
			const at = tail.findIndex((line) => line.id === id);
			if (at === -1) return;
			tail[at] = { ...tail[at], text };
			await rewrite(room, tail);
		} catch (error) {
			noteTrouble(`could not update an edited line for ${room}`, error);
		}
	})();
}

/** The last `limit` kept lines for a room, oldest first. */
export async function readRoomLines(room: string, limit: number): Promise<KeptLine[]> {
	if (!enabled) return [];
	const tail = await loadTail(room);
	return tail.slice(-limit);
}
