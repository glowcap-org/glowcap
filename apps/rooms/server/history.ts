// What a room keeps of its own conversation, when this server keeps any.
//
// Retention is a stated policy, not a silent default: nothing records until
// the operator starts the server with `--history`, and the client's divider
// names the room as the keeper wherever these lines stand back up. Retention
// follows stable room identity rather than public visibility. A private room
// therefore keeps history only when the same explicit server policy is on.
//
// Retention semantics live here — what is kept, how many, when a copy is
// forgotten — and a backend only persists. The narrow verbs a backend
// answers (restore, append, replace) are the seam `storage.ts` composes at
// boot from the implementations under `storage/`; nothing outside that
// composer knows which one is running, and nothing at all when the operator
// named none. Text lines only: a file's bytes already have a bounded owner
// in `files.ts`, and its caption arrives as an ordinary line.

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

/** One room server's complete retained-history lifetime. Constructing another
 * server constructs another index, backend slot, and write queue; closing one
 * cannot stop or erase the other. */
export class RoomHistory {
	#backend: HistoryBackend | null = null;
	#enabled = false;
	readonly #index = new HistoryIndex();
	readonly #report: (source: string, error: unknown) => void;
	/** Every backend call chains here, one at a time. The PostgreSQL backend's
	 * rewrite is several statements in one transaction on one connection, so a
	 * concurrent append would land inside it and vanish with a rollback; the
	 * file backend's append during a compaction rename loses the line the same
	 * way. One chain serializes them all — history traffic is a person typing,
	 * so the ordering costs nothing and the interleave can never happen. */
	#persisting: Promise<void> = Promise.resolve();

	constructor(report: (source: string, error: unknown) => void) {
		this.#report = report;
	}

	#persist(act: string, room: string, work: (persist: HistoryBackend) => Promise<void>): void {
		if (this.#backend === null) return;
		const held = this.#backend;
		this.#persisting = this.#persisting.then(() => work(held)).catch((error) => {
			this.#report(`could not ${act} for ${room}`, error);
		});
	}

	/** Turn history on or off and hand over the backend that persists it. Called
	 * once at startup, before any room exists. */
	async open(persist: HistoryBackend | null, keep: boolean): Promise<void> {
		await this.close();
		if (!keep) {
			persist?.close();
			return;
		}
		this.#backend = persist;
		if (persist !== null) {
			try {
				await persist.restore(this.#index);
				for (const room of this.#index.takeEvicted()) await persist.replace(room, []);
			} catch (error) {
				persist.close();
				this.#backend = null;
				this.#index.clear();
				throw error;
			}
		}
		this.#enabled = true;
	}

	/** Whether this server keeps history at all, which is what the room verb
	 * answers to. */
	get enabled(): boolean {
		return this.#enabled;
	}

	/** Keep one line for a room. Fire-and-forget from the post path: the line is
	 * already broadcast, and losing a remembered copy can never be worth
	 * refusing the post. */
	record(room: string, line: KeptLine): void {
		if (!this.#enabled) return;
		const evicted = this.#index.record(room, line);
		this.#persist("keep a line", room, (held) => held.append(room, line, evicted));
	}

	/** A line was withdrawn: the kept copy goes with it, in memory and behind
	 * the backend. */
	forget(room: string, line: LiveKeptLine): void {
		if (!this.#enabled) return;
		const snapshot = this.#index.forget(room, line);
		if (snapshot !== null) this.#persist("forget a withdrawn line", room, (held) => held.replace(room, snapshot));
	}

	/** A line was edited: the kept copy says the new words. */
	update(room: string, line: LiveKeptLine, text: string): void {
		if (!this.#enabled) return;
		const snapshot = this.#index.update(room, line, text);
		if (snapshot !== null) this.#persist("update an edited line", room, (held) => held.replace(room, snapshot));
	}

	/** The last `limit` kept lines for a room, oldest first. */
	read(room: string, limit: number): Promise<KeptLine[]> {
		if (!this.#enabled) return Promise.resolve([]);
		return Promise.resolve(this.#index.read(room, limit));
	}

	/** Stop admitting retained work, settle everything already admitted, then
	 * release the backend. */
	async close(): Promise<void> {
		this.#enabled = false;
		await this.#persisting;
		this.#backend?.close();
		this.#backend = null;
		this.#persisting = Promise.resolve();
		this.#index.clear();
	}
}
