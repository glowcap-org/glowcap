// Direct-message history, kept on this device.
//
// A direct line is end-to-end encrypted, so its plaintext must never land
// server-side; the only honest home for its history is the reader's own
// browser. IndexedDB holds it, under the same posture as `storage.ts`: a
// private window, a profile with site data off, or a refused write means the
// page carries on as though nothing had been kept. Every verb here swallows
// its own failure because every stored line is a convenience; losing one can
// never be worth a failure path.
//
// Keeping history at all is the reader's visible choice (the Advanced
// switch), on by default because a chat that forgets everything on reload
// surprises more than it protects. Turning it off wipes what was kept. Text
// only: an attachment's bytes live with whoever serves them, so a hydrated
// line stands with its words and not its files. A withdrawn line's kept copy
// goes with it, and an edit reaches it, because history that outlives a
// takedown would break the promise withdraw makes everywhere else; a
// withdrawal arriving after a re-introduction cannot reach copies kept
// before it, which is the same boundary any kept log has.

const DB = "rooms-history";
const STORE = "lines";
const PAIR_INDEX = "pair";
const KEEP_KEY = "rooms.keep-history";
/** How many lines one conversation pair keeps; the oldest fall off. */
const LINES_KEPT = 500;

/** One remembered line, exactly what a bubble needs to stand again. */
export interface StoredLine {
	readonly from: string;
	readonly text: string;
	readonly mine: boolean;
	readonly at: number;
}

/** Whether this device keeps direct-message history. Storage that cannot be
 * read answers as the default, the way every remembered fact does. */
export function historyKept(): boolean {
	try {
		return localStorage.getItem(KEEP_KEY) !== "off";
	} catch {
		return true;
	}
}

/** Flip the choice. Turning it off erases what was kept, in the same breath,
 * because "stop keeping history" that leaves history behind kept it. */
export function setHistoryKept(keep: boolean): void {
	try {
		localStorage.setItem(KEEP_KEY, keep ? "on" : "off");
	} catch {
		/* tolerant: a profile that refuses the preference still gets the wipe */
	}
	if (!keep) void wipeHistory();
}

let opened: Promise<IDBDatabase | null> | null = null;

function db(): Promise<IDBDatabase | null> {
	if (opened !== null) return opened;
	opened = new Promise((resolve) => {
		try {
			const req = indexedDB.open(DB, 1);
			req.onupgradeneeded = () => {
				const store = req.result.createObjectStore(STORE, { autoIncrement: true });
				store.createIndex(PAIR_INDEX, "pair");
			};
			req.onsuccess = () => resolve(req.result);
			req.onerror = () => resolve(null);
			req.onblocked = () => resolve(null);
		} catch {
			resolve(null);
		}
	});
	return opened;
}

/** Append one line under a conversation pair, trimming that pair to its cap.
 * Fire-and-forget: the caller has already drawn the line. */
export function recordDmLine(pair: string, line: StoredLine): void {
	if (!historyKept()) return;
	void (async () => {
		const held = await db();
		if (held === null) return;
		try {
			const tx = held.transaction(STORE, "readwrite");
			const store = tx.objectStore(STORE);
			store.add({ pair, ...line });
			const index = store.index(PAIR_INDEX);
			const keys = index.getAllKeys(pair);
			keys.onsuccess = () => {
				const over = keys.result.length - LINES_KEPT;
				for (let at = 0; at < over; at++) store.delete(keys.result[at]);
			};
		} catch {
			/* tolerant: a refused write loses one remembered line */
		}
	})();
}

/** Everything remembered for a pair, oldest first. */
export function readDmLines(pair: string): Promise<StoredLine[]> {
	return (async () => {
		const held = await db();
		if (held === null) return [];
		try {
			const tx = held.transaction(STORE, "readonly");
			const rows = tx.objectStore(STORE).index(PAIR_INDEX).getAll(pair);
			return await new Promise<StoredLine[]>((resolve) => {
				rows.onsuccess = () =>
					resolve(rows.result.map((row) => ({
						from: String(row.from ?? ""),
						text: String(row.text ?? ""),
						mine: row.mine === true,
						at: typeof row.at === "number" ? row.at : 0,
					})));
				rows.onerror = () => resolve([]);
			});
		} catch {
			return [];
		}
	})();
}

function matchKey(row: { from?: unknown; at?: unknown }, line: { from: string; at: number }): boolean {
	return row.from === line.from && row.at === line.at;
}

/** A line was withdrawn: the kept copy goes with it. Matched by author and
 * timestamp, the two facts a bubble keeps for its whole life. */
export function forgetDmLine(pair: string, line: { from: string; at: number }): void {
	void (async () => {
		const held = await db();
		if (held === null) return;
		try {
			const tx = held.transaction(STORE, "readwrite");
			const index = tx.objectStore(STORE).index(PAIR_INDEX);
			const walk = index.openCursor(pair);
			walk.onsuccess = () => {
				const cursor = walk.result;
				if (cursor === null) return;
				if (matchKey(cursor.value, line)) cursor.delete();
				cursor.continue();
			};
		} catch {
			/* tolerant: a copy that cannot be reached was already a convenience */
		}
	})();
}

/** A line was edited: the kept copy says the new words. */
export function updateDmLine(pair: string, line: { from: string; at: number }, text: string): void {
	void (async () => {
		const held = await db();
		if (held === null) return;
		try {
			const tx = held.transaction(STORE, "readwrite");
			const index = tx.objectStore(STORE).index(PAIR_INDEX);
			const walk = index.openCursor(pair);
			walk.onsuccess = () => {
				const cursor = walk.result;
				if (cursor === null) return;
				if (matchKey(cursor.value, line)) cursor.update({ ...cursor.value, text });
				cursor.continue();
			};
		} catch {
			/* tolerant: a copy that cannot be reached was already a convenience */
		}
	})();
}

/** Forget everything this device kept. */
export function wipeHistory(): Promise<void> {
	return new Promise((resolve) => {
		try {
			opened = null;
			const req = indexedDB.deleteDatabase(DB);
			req.onsuccess = () => resolve();
			req.onerror = () => resolve();
			req.onblocked = () => resolve();
		} catch {
			resolve();
		}
	});
}
