// Internal: what library resolution had to settle for, and where it goes.
//
// A resolution that soft-fails (a download that did not finish, a cache lock
// it could not take) or falls back to a bare library name still returns a
// path. Each such note becomes a `library-resolution` event in the runtime
// failure journal, so `takeRuntimeFailures()` reports it, and it stays beside
// the path it produced, so a load of that path that then fails carries the
// notes in its error. Nothing here prints.

import { INTERNAL } from "@glowcap/abi";
import { recordRuntimeFailure } from "../../failure_journal.ts";

/** Notes one resolution keeps for its load. A resolution makes at most a few,
 * and the journal holds every one. */
const NOTES_PER_PATH = 8;

let collecting: string[] | null = null;
// Keyed by the resolved path, so it holds one entry per archive this process
// resolves, and a later clean resolution of the same path clears it.
const notesByPath = new Map<string, readonly string[]>();

/** Record what the resolution under way had to settle for. */
export function noteResolution(message: string): void {
	if (collecting !== null && collecting.length < NOTES_PER_PATH) collecting.push(message);
	recordRuntimeFailure({
		layer: "binding",
		scope: "process",
		operation: "library-resolution",
		primaryName: "Error",
		primaryResult: INTERNAL,
		primaryMessage: message,
	});
}

/** Run one resolution and keep the notes it made beside the path it returns. */
export function resolveNoting(resolve: () => string): string {
	const notes: string[] = [];
	const outer = collecting;
	collecting = notes;
	let path: string;
	try {
		path = resolve();
	} finally {
		collecting = outer;
	}
	if (notes.length > 0) notesByPath.set(path, notes);
	else notesByPath.delete(path);
	return path;
}

/** Open `path` with `open`. A failure to open a path whose resolution made
 * notes is rethrown naming them, with the open's own error as its cause. */
export function openNoting<T>(path: string, open: () => T): T {
	try {
		return open();
	} catch (error) {
		const notes = notesByPath.get(path);
		if (notes == null) throw error;
		throw new Error(`glowcap: ${path} did not load; library resolution noted: ${notes.join("; ")}`, {
			cause: error,
		});
	}
}
