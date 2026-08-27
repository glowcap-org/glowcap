// The state-directory storage backend: one JSONL file per room. The
// boring default, deliberately — zero operational surface, and the shape
// `--storage` keeps when the operator names a directory instead of a
// database. Retention semantics live in `history.ts`; this file only
// persists.

import * as z from "zod/mini";
import { type HistoryBackend, type KeptLine, LINES_KEPT } from "../history.ts";
import { assertValidKeptLine, HISTORY_ROOMS_KEPT, type HistoryRestoreTarget } from "../history_index.ts";
import { MAX_LINE, MAX_NICK } from "../../lib/limits.ts";
import { appendSynced, atomicWrite, readBoundedText } from "../../lib/durable_file.ts";
import { boundedText, nonnegativeSafeInteger } from "../../lib/schema.ts";

/** Past this many lines on disk, the file is rewritten to the kept tail. */
const COMPACT_AT = LINES_KEPT * 2;
/** JSON escaping can expand one admitted text byte to six disk bytes. The
 * logical index is far smaller; this is the pre-read crash/corruption ceiling. */
export const HISTORY_DISK_BYTES = 512 * 1024 * 1024;
/** One pre-compaction room file at the worst JSON escaping expansion. This
 * bounds the single allocation made by `readTextFile`, independently of the
 * whole-directory ceiling. */
export const HISTORY_FILE_BYTES = 64 * 1024 * 1024;
const OPEN_PROBE = ".open-check.tmp";
/** Append and whole-room deletion are two filesystem operations. A crash may
 * leave the triggering room and its victim standing together; startup admits
 * exactly that one surplus so the shared index can choose and delete it. */
const HISTORY_ROOM_FILES = HISTORY_ROOMS_KEPT + 1;
const LINE_VERSION = 1;
const encoder = new TextEncoder();

const KeptLineShape = {
	from: boundedText(MAX_NICK),
	text: boundedText(MAX_LINE),
	at: nonnegativeSafeInteger,
};

export const RoomHistoryLineSchema = z.strictObject({ version: z.literal(LINE_VERSION), ...KeptLineShape });
type RoomHistoryLine = z.infer<typeof RoomHistoryLineSchema>;

function encodeLine(line: KeptLine): string {
	return JSON.stringify(
		{ version: LINE_VERSION, from: line.from, text: line.text, at: line.at } satisfies RoomHistoryLine,
	);
}

/** One JSONL file per room: appended in place, and compacted back to the
 * kept tail once the file has grown past `COMPACT_AT`, through a temp
 * rename so a crash mid-compact leaves the old file whole. */
export class FileHistoryBackend implements HistoryBackend {
	#directory: string;
	#grown = new Map<string, number>();

	constructor(stateDirectory: string) {
		this.#directory = stateDirectory;
	}

	#fileFor(room: string): string {
		return `${this.#directory}/history/${encodeURIComponent(room)}.jsonl`;
	}

	async restore(into: HistoryRestoreTarget): Promise<void> {
		const directory = `${this.#directory}/history`;
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		const probe = `${directory}/${OPEN_PROBE}`;
		await Deno.remove(probe).catch((error) => {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
		});
		const opened = await Deno.open(probe, { createNew: true, write: true, mode: 0o600 });
		try {
			// Opening the file is the writability probe; no bytes become state.
		} finally {
			opened.close();
			await Deno.remove(probe);
		}

		const rooms: string[] = [];
		let diskBytes = 0;
		for await (const entry of Deno.readDir(directory)) {
			if (!entry.isFile) throw new Error(`room history contains unexpected entry ${JSON.stringify(entry.name)}`);
			if (entry.name.endsWith(".jsonl.tmp")) {
				const standing = `${directory}/${entry.name.slice(0, -4)}`;
				try {
					await Deno.stat(standing);
				} catch (error) {
					if (error instanceof Deno.errors.NotFound) {
						throw new Error(`room history contains an orphaned compaction ${JSON.stringify(entry.name)}`);
					}
					throw error;
				}
				await Deno.remove(`${directory}/${entry.name}`);
				continue;
			}
			if (!entry.name.endsWith(".jsonl")) {
				throw new Error(`room history contains unexpected file ${JSON.stringify(entry.name)}`);
			}
			const encoded = entry.name.slice(0, -".jsonl".length);
			let name: string;
			try {
				name = decodeURIComponent(encoded);
			} catch (error) {
				throw new Error(`room history has an invalid filename ${JSON.stringify(entry.name)}`, { cause: error });
			}
			if (encodeURIComponent(name) !== encoded) {
				throw new Error(`room history has a non-canonical filename ${JSON.stringify(entry.name)}`);
			}
			const bytes = (await Deno.stat(`${directory}/${entry.name}`)).size;
			if (bytes > HISTORY_FILE_BYTES) {
				throw new Error(`room history file ${JSON.stringify(entry.name)} exceeds ${HISTORY_FILE_BYTES} bytes`);
			}
			diskBytes += bytes;
			if (diskBytes > HISTORY_DISK_BYTES) {
				throw new Error(`room history exceeds its ${HISTORY_DISK_BYTES}-byte disk ceiling`);
			}
			rooms.push(name);
			if (rooms.length > HISTORY_ROOM_FILES) {
				throw new Error(`room history contains more than ${HISTORY_ROOM_FILES} recoverable room files`);
			}
		}
		rooms.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
		for (const room of rooms) {
			into.restoreRoom(room, await this.#load(room));
		}
	}

	async #load(room: string): Promise<KeptLine[]> {
		const tail: KeptLine[] = [];
		let text: string;
		try {
			text = await readBoundedText(this.#fileFor(room), HISTORY_FILE_BYTES, `room history for ${room}`);
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			this.#grown.set(room, 0);
			return tail;
		}
		const rows = text.split("\n");
		let count = 0;
		for (let at = 0; at < rows.length; at++) {
			const encoded = rows[at];
			if (encoded === "") {
				if (at === rows.length - 1) continue;
				throw new Error(`room history for ${room} contains an empty row`);
			}
			let row: unknown;
			try {
				row = JSON.parse(encoded);
			} catch (error) {
				// An append can tear only at the file's unfinished final row. Every
				// complete row is state, and corrupt state is never silently skipped.
				if (at === rows.length - 1 && !text.endsWith("\n")) break;
				throw new Error(`room history for ${room} contains invalid JSON`, { cause: error });
			}
			if (typeof row === "object" && row != null && "version" in row && row.version !== LINE_VERSION) {
				throw new Error(`room history for ${room} has unsupported line version ${String(row.version)}`);
			}
			const current = z.safeParse(RoomHistoryLineSchema, row);
			if (!current.success) throw new Error(`room history for ${room} contains an invalid line`);
			const line = { from: current.data.from, text: current.data.text, at: current.data.at };
			assertValidKeptLine(room, line);
			tail.push(line);
			if (tail.length > LINES_KEPT) tail.shift();
			count++;
		}
		this.#grown.set(room, count);
		return tail;
	}

	async append(room: string, line: KeptLine, evictedRoom: string | null): Promise<void> {
		await Deno.mkdir(`${this.#directory}/history`, { recursive: true, mode: 0o700 });
		const count = (this.#grown.get(room) ?? 0) + 1;
		if (count >= COMPACT_AT) {
			const tail = await this.#load(room);
			tail.push(line);
			if (tail.length > LINES_KEPT) tail.splice(0, tail.length - LINES_KEPT);
			await this.replace(room, tail);
		} else {
			this.#grown.set(room, count);
			await appendSynced(this.#fileFor(room), encoder.encode(encodeLine(line) + "\n"));
		}
		if (evictedRoom !== null) await this.replace(evictedRoom, []);
	}

	async replace(room: string, tail: readonly KeptLine[]): Promise<void> {
		await Deno.mkdir(`${this.#directory}/history`, { recursive: true, mode: 0o700 });
		const path = this.#fileFor(room);
		if (tail.length === 0) {
			await Deno.remove(path).catch((error) => {
				if (!(error instanceof Deno.errors.NotFound)) throw error;
			});
			this.#grown.delete(room);
			return;
		}
		await atomicWrite(path, encoder.encode(tail.map(encodeLine).join("\n") + "\n"));
		this.#grown.set(room, tail.length);
	}

	close(): void {
		// Files hold nothing open between verbs.
	}
}
