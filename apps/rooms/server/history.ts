// What a room keeps of its own conversation, when this server keeps any.
//
// Retention is a stated policy, not a silent default: nothing records until
// the operator starts the server with `--history`, and the client's divider
// names the room as the keeper wherever these lines stand back up. Only
// listed rooms record. A private room is reference-only by design, and
// widening its retention is a decision its holders never made; the module
// head is where that boundary lives so the next reader finds it stated.
//
// Retention semantics live here — what is kept, how many, when a copy is
// forgotten — and a backend only persists. The narrow verbs a backend
// answers (restore, append, replace) are the seam `storage.ts` composes at
// boot from the implementations under `storage/`; nothing outside that
// composer knows which one is running, and nothing at all when the operator
// named none. Text lines only: a file's bytes already have a bounded owner
// in `files.ts`, and its caption arrives as an ordinary line.

import { noteTrouble } from "./journal.ts";
import { HistoryIndex, type HistoryRestoreTarget, type KeptLine, type LiveKeptLine } from "./history_index.ts";
export {
	HISTORY_LINES_KEPT,
	HISTORY_ROOMS_KEPT,
	type KeptLine,
	LINES_KEPT,
	type LiveKeptLine,
	liveKeptLine,
} from "./history_index.ts";
/** Where kept lines persist. Retention policy never lives behind this seam:
 * a backend is handed lines the policy already admitted and answers with
 * lines the policy will trim again. Every verb may reject; the caller owns
 * turning that into a journal entry, because losing a remembered copy is
 * never worth refusing the post it remembers. */
export interface HistoryBackend {
	/** Restore every persisted room through the shared policy owner. */
	restore(into: HistoryRestoreTarget): Promise<void>;
	/** One more line. Ordinary posts never copy the room's whole tail across
	 * this seam; a backend that compacts owns that occasional work. */
	append(room: string, line: KeptLine, evictedRoom: string | null): Promise<void>;
	/** The kept tail changed shape (a withdrawal or an edit): persist it as
	 * it now stands. */
	replace(room: string, tail: readonly KeptLine[]): Promise<void>;
	close(): void;
}

let backend: HistoryBackend | null = null;
let enabled = false;
const index = new HistoryIndex();
/** Every backend call chains here, one at a time. The PostgreSQL backend's
 * rewrite is several statements in one transaction on one connection, so a
 * concurrent append would land inside it and vanish with a rollback; the
 * file backend's append during a compaction rename loses the line the same
 * way. One chain serializes them all — history traffic is a person typing,
 * so the ordering costs nothing and the interleave can never happen. */
let persisting: Promise<void> = Promise.resolve();

function persist(act: string, room: string, work: (persist: HistoryBackend) => Promise<void>): void {
	if (backend === null) return;
	const held = backend;
	persisting = persisting.then(() => work(held)).catch((error) => {
		noteTrouble(`could not ${act} for ${room}`, error);
	});
}

/** Turn history on or off for this process and hand over the backend that
 * persists it, or null for memory only. Called once at startup, before any
 * room exists; `storage.ts` composes which backend, and `main.ts` answers
 * for a destination that cannot be opened. */
export async function initHistory(persist: HistoryBackend | null, keep: boolean): Promise<void> {
	await closeHistory();
	if (!keep) {
		persist?.close();
		return;
	}
	backend = persist;
	if (persist !== null) {
		try {
			await persist.restore(index);
			for (const room of index.takeEvicted()) await persist.replace(room, []);
		} catch (error) {
			persist.close();
			backend = null;
			index.clear();
			throw error;
		}
	}
	enabled = true;
}

/** Whether this server keeps history at all, which is what the room verb
 * answers to. */
export function historyEnabled(): boolean {
	return enabled;
}

/** Keep one line for a room. Fire-and-forget from the post path: the line is
 * already broadcast, and losing a remembered copy can never be worth
 * refusing the post. */
export function recordRoomLine(room: string, line: KeptLine): void {
	if (!enabled) return;
	const evicted = index.record(room, line);
	persist("keep a line", room, (held) => held.append(room, line, evicted));
}

/** A line was withdrawn: the kept copy goes with it, in memory and behind
 * the backend. Fire-and-forget for the same reason recording is. */
export function forgetRoomLine(room: string, line: LiveKeptLine): void {
	if (!enabled) return;
	const snapshot = index.forget(room, line);
	if (snapshot !== null) persist("forget a withdrawn line", room, (held) => held.replace(room, snapshot));
}

/** A line was edited: the kept copy says the new words. */
export function updateRoomLine(room: string, line: LiveKeptLine, text: string): void {
	if (!enabled) return;
	const snapshot = index.update(room, line, text);
	if (snapshot !== null) persist("update an edited line", room, (held) => held.replace(room, snapshot));
}

/** The last `limit` kept lines for a room, oldest first. The in-memory index
 * always reflects the latest write, so this read is synchronous; the Promise is
 * the boundary a durable backend read fills later without touching callers. */
export function readRoomLines(room: string, limit: number): Promise<KeptLine[]> {
	if (!enabled) return Promise.resolve([]);
	return Promise.resolve(index.read(room, limit));
}

/** Stop admitting retained work, settle everything already admitted, then
 * release the backend. A controlled process shutdown awaits this boundary. */
export async function closeHistory(): Promise<void> {
	enabled = false;
	await persisting;
	backend?.close();
	backend = null;
	persisting = Promise.resolve();
	index.clear();
}
