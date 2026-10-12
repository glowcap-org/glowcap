// Stopping a file that is already going.
//
// A message is posted before its files are filled, that order is what lets a
// bubble appear before its pictures do, so a reader who picked the wrong large
// file cannot un-say the message. What they can do is stop paying for it, and
// what makes that possible is the shape of the write: one bounded chunk per
// round trip, so stopping is a matter of not starting the next one.
//
// That is the whole mechanism, and it is pinned here rather than in a browser
// because the browser proof cannot reach it. Its files are a few bytes, so they
// are gone in a single chunk and there is no moment at which a stop could be
// pressed. Driving a sixty-megabyte file through a headless relay to reach the
// same fact would be slower, flakier, and no more convincing.

import { BLOB_CHUNK } from "../lib/limits.ts";
import { type AttachmentSource, fillUpload, UploadStopped } from "../lib/attachment.ts";
import { Unanswered } from "../lib/deadline.ts";
import { assertEquals } from "./assert.ts";

/** A session that counts writes and answers instantly, standing in for the one
 * `fillUpload` sends through. Only `send` is reached, so only `send` is here. */
function countingSession(onWrite: () => void) {
	return {
		send(..._args: unknown[]): Promise<unknown> {
			onWrite();
			return Promise.resolve(undefined);
		},
		// deno-lint-ignore no-explicit-any
	} as any;
}

/** A file of `chunks` whole chunks, carried as bytes the way an in-memory
 * caller supplies one. */
function sourceOf(chunks: number): AttachmentSource {
	return {
		name: "big.bin",
		mime: "application/octet-stream",
		bytes: new Uint8Array(BLOB_CHUNK * chunks),
	};
}

Deno.test("an upload whose chunk is never taken gives up saying so", async () => {
	// A stop is checked between chunks, so a chunk that is never answered is
	// never between: pressing the mark on the bubble does nothing at all, and the
	// message sits sending for the life of the tab. The room here is whatever
	// directory somebody typed, so this is not a hypothetical partner.
	const parking = {
		send(..._args: unknown[]): Promise<unknown> {
			return new Promise(() => {});
		},
		// deno-lint-ignore no-explicit-any
	} as any;
	let stalled: unknown = null;
	try {
		await fillUpload(parking, {} as never, sourceOf(2), undefined, undefined, 50);
	} catch (error) {
		stalled = error;
	}
	assertEquals(
		stalled instanceof Unanswered,
		true,
		`a write nobody answered ended as ${stalled}`,
	);
	assertEquals(String(stalled).includes("0 of"), true, `it did not say how far it got: ${stalled}`);
});

Deno.test("an upload nobody stops writes every chunk", async () => {
	let writes = 0;
	await fillUpload(countingSession(() => writes++), {} as never, sourceOf(4));
	assertEquals(writes, 4);
});

Deno.test("a stopped upload stops writing, and says it was stopped", async () => {
	let writes = 0;
	const stop = new AbortController();
	// Tripped partway through, the way a reader presses the mark on their own
	// bubble while the transfer is running.
	const session = countingSession(() => {
		writes++;
		if (writes === 2) stop.abort();
	});
	let stopped: unknown = null;
	try {
		await fillUpload(session, {} as never, sourceOf(100), undefined, stop.signal);
	} catch (error) {
		stopped = error;
	}
	if (!(stopped instanceof UploadStopped)) {
		throw new Error(`expected the stop to be named as one, got ${String(stopped)}`);
	}
	// The chunk already in the air finishes; the next one never starts. So a
	// hundred-chunk file costs two chunks after a stop, not a hundred, which is
	// the whole point, and what a check on the error alone would not show.
	assertEquals(writes, 2);
	// What the file's row says afterwards is the reader's own decision, not a
	// fault they have to interpret.
	assertEquals((stopped as Error).message, "Stopped");
});

Deno.test("a stop that arrives before the first chunk sends nothing", async () => {
	let writes = 0;
	const stop = new AbortController();
	stop.abort();
	let stopped: unknown = null;
	try {
		await fillUpload(countingSession(() => writes++), {} as never, sourceOf(8), undefined, stop.signal);
	} catch (error) {
		stopped = error;
	}
	if (!(stopped instanceof UploadStopped)) throw new Error("a stop before the first chunk was not honoured");
	assertEquals(writes, 0);
});
