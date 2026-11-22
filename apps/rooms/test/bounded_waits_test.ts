// A parent waits on a child it started: for the line that says where it
// listens, for its front to answer, for a condition to hold. Each wait is
// bounded as a whole, so a child that stays up and says nothing fails at the
// deadline, like one that exits.

import { readAnnouncement } from "../../_demo/orchestrator.ts";
import { assert, assertEquals } from "./assert.ts";
import { roomLocator } from "./support/rooms_server.ts";
import { until } from "./support/wait.ts";

const PATTERN = /ROOMS-SERVER-LISTENING (\S+)/;
const MISS = "rooms server never announced its locator";
const encoder = new TextEncoder();

/** A pipe that yields `chunks` and then stays open, or closes when `close` is set. */
function pipe(chunks: string[], close: boolean): ReadableStream<Uint8Array> {
	return new ReadableStream({
		start(controller) {
			for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
			if (close) controller.close();
		},
	});
}

async function refusal(read: Promise<unknown>): Promise<string> {
	try {
		await read;
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
	throw new Error("the read resolved without an announcement");
}

Deno.test("An announcement split across chunks resolves to its token", async () => {
	const [, token] = await readAnnouncement(
		pipe(["booting\nROOMS-SERVER-LIS", "TENING 4242\n"], false),
		PATTERN,
		MISS,
		1_000,
	);
	assertEquals(token, "4242");
});

Deno.test("A server that stays up without announcing fails at the deadline", async () => {
	const stream = pipe(["booting\n"], false);
	const started = performance.now();
	const message = await refusal(readAnnouncement(stream, PATTERN, MISS, 50));
	assert(performance.now() - started < 1_000, "the read outlived its deadline");
	assertEquals(message, `${MISS} within 50 ms\nbooting\n`);
	// The caller drains the pipe after the read, so the lock is released.
	assert(!stream.locked, "the stream stayed locked after the deadline");
});

Deno.test("A server that closes its output before announcing says so", async () => {
	const message = await refusal(readAnnouncement(pipe(["panic\n"], true), PATTERN, MISS, 1_000));
	assertEquals(message, `${MISS}: its output closed\npanic\n`);
});

Deno.test("A condition whose check never answers fails at the deadline", async () => {
	const started = performance.now();
	const message = await refusal(until(() => new Promise<boolean>(() => {}), "a check that never answers", 50));
	assert(performance.now() - started < 1_000, "the wait outlived its deadline");
	assertEquals(message, "timed out waiting for a check that never answers");
});

Deno.test("A front that accepts and never answers fails at the deadline", async () => {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const held: Deno.Conn[] = [];
	const accepting = (async () => {
		for await (const conn of listener) held.push(conn);
	})();
	try {
		const started = performance.now();
		const message = await refusal(roomLocator(listener.addr.port, "a silent front", 100));
		assert(performance.now() - started < 2_000, "the probe outlived its deadline");
		assertEquals(message, "a silent front did not answer with a room locator within 100 ms");
	} finally {
		listener.close();
		for (const conn of held) conn.close();
		await accepting.catch(() => {}); // tolerant: closing the listener ends the accept loop
	}
});
