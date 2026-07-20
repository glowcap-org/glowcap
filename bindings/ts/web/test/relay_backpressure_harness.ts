// The relay contract's backpressure proof, parameterized over the relay program.
// A stalled reader on the browser-bound leg must stall the far sender, so the
// relay never buffers unbounded. This is the one non-optional clause of the
// ADR-0086 contract — it catches a runtime whose WebSocket `send` returns before
// its buffer drains — and one harness pins it for every runtime's relay.
//
// It needs no browser peer or wasm: the relay moves opaque bytes, so a raw bulk
// TCP sender and a raw stalled WebSocket client exercise the pump directly.
//
// Shape: a bulk TCP sender floods whatever connects to it, counting bytes it
// manages to write. The relay dials that sender. A raw WebSocket client upgrades
// through the relay, then never reads — its OS receive buffer fills, closing the
// window to the relay, whose browser-bound send then blocks, so it stops reading
// the sender, whose write then blocks. If that chain holds, the sender is stuck
// after a few buffers' worth. If the relay drained the sender into an unbounded
// queue instead, the sender would run to its cap.

import { fail, kill, parseHarnessArgs, readToken, spawnRelay } from "./relay_harness_common.ts";

const BULK_CHUNK = 64 * 1024;
const HARD_CAP = 256 * 1024 * 1024; // sender's own safety stop
const BACKPRESSURE_BOUND = 32 * 1024 * 1024; // pass if the sender stalls below this
const STALL_OBSERVE_MS = 2500;

const inv = parseHarnessArgs(Deno.args);
const deadline = setTimeout(
	() => fail(`${inv.label} backpressure scenario timed out after 60s`),
	60_000,
);

// 1. Bulk TCP sender: floods every connection as fast as it drains, counting the
//    bytes it actually got written (i.e. that were not backpressured).
let bulkWritten = 0;
const bulkListener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
const bulkPort = (bulkListener.addr as Deno.NetAddr).port;
(async () => {
	for await (const conn of bulkListener) {
		const chunk = new Uint8Array(BULK_CHUNK);
		(async () => {
			try {
				while (bulkWritten < HARD_CAP) {
					await conn.write(chunk); // blocks once the far side stops draining
					bulkWritten += chunk.length;
				}
			} catch {
				// connection torn down
			}
		})();
	}
})().catch(() => {});

// 2. The relay program under test.
const relayProcess = spawnRelay(inv);
const relayPort = Number(await readToken(relayProcess, new RegExp(`${inv.marker} (\\d+)`)));

try {
	// 3. Raw WebSocket client that upgrades through the relay to the bulk sender,
	//    then stalls: it reads the 101 response once and never reads again, so the
	//    relay's forwarded frames pile up in this socket's OS receive buffer.
	const conn = await Deno.connect({ hostname: "127.0.0.1", port: relayPort });
	const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
	const upgrade = `GET /relay?to=127.0.0.1:${bulkPort} HTTP/1.1\r\n` +
		`Host: 127.0.0.1:${relayPort}\r\n` +
		`Upgrade: websocket\r\nConnection: Upgrade\r\n` +
		`Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`;
	await conn.write(new TextEncoder().encode(upgrade));
	const resp = new Uint8Array(1024);
	const n = await conn.read(resp);
	if (n === null || !new TextDecoder().decode(resp.subarray(0, n)).includes("101")) {
		fail("relay did not accept the WebSocket upgrade");
	}
	// Deliberately never read from `conn` again — this is the stall.

	// 4. Give the flood time to run, then check the sender was backpressured.
	await new Promise((r) => setTimeout(r, STALL_OBSERVE_MS));
	const wrote = bulkWritten;
	if (wrote >= BACKPRESSURE_BOUND) {
		fail(
			`no backpressure: the far sender wrote ${(wrote / 1024 / 1024).toFixed(0)} MiB ` +
				`into a stalled reader (bound ${BACKPRESSURE_BOUND / 1024 / 1024} MiB) — ` +
				`the relay buffered unbounded instead of stalling the sender`,
		);
	}
	try {
		conn.close();
	} catch {
		// already closed
	}
	console.log(
		`OK: a stalled reader backpressured the far sender through the ${inv.label} relay ` +
			`(sender stuck at ${(wrote / 1024 / 1024).toFixed(1)} MiB)`,
	);
	clearTimeout(deadline);
} catch (err) {
	fail(
		`${inv.label} backpressure scenario failed: ${
			err instanceof Error ? err.message : String(err)
		}`,
	);
} finally {
	kill(relayProcess);
	try {
		bulkListener.close();
	} catch {
		// already closed
	}
	Deno.exit(0);
}
