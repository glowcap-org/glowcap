// The relay contract's idle-timeout proof, parameterized over the relay program.
// ADR-0086's bounded-resources clause says the relay reclaims a stalled pair: a
// session that moves no bytes in either direction for the idle timeout is torn
// down, so a peer that connects and goes silent cannot pin relay resources
// forever. One harness pins this for every runtime's relay.
//
// It needs no browser peer or wasm. A silent TCP sink accepts the relay's dial
// and never sends; a raw WebSocket client upgrades through the relay and then
// goes quiet. With no chunk in either direction, the relay's idle timer (set low
// through `GLOWCAP_RELAY_IDLE_MS` for this proof) must fire and close the
// WebSocket. If it does not, the client's socket stays open past the ceiling and
// the harness fails — catching a runtime that dropped the idle timeout.

import { fail, kill, parseHarnessArgs, readToken, spawnRelay } from "./relay_harness_common.ts";

// The relay is launched with GLOWCAP_RELAY_IDLE_MS=500 (see the build row); the
// ceiling is generous so a slow scheduler never flakes, yet far below the 60s
// production default, so a relay that ignored the override cannot pass.
const CEILING_MS = 8000;

const inv = parseHarnessArgs(Deno.args);
const deadline = setTimeout(() => fail(`${inv.label} idle scenario timed out after 30s`), 30_000);

// A silent TCP sink: accept the relay's dial and hold the connection open without
// ever sending or reading, so the relayed pair is idle from the upgrade onward.
const sink = Deno.listen({ hostname: "127.0.0.1", port: 0 });
const sinkPort = (sink.addr as Deno.NetAddr).port;
(async () => {
	for await (const conn of sink) {
		void conn; // held open, deliberately silent
	}
})().catch(() => {});

const relayProcess = spawnRelay(inv);
const relayPort = Number(await readToken(relayProcess, new RegExp(`${inv.marker} (\\d+)`)));

try {
	// Raw WebSocket client that upgrades through the relay to the silent sink,
	// then goes quiet. No bytes flow, so the relay's idle timer runs unreset.
	const conn = await Deno.connect({ hostname: "127.0.0.1", port: relayPort });
	const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
	const upgrade = `GET /relay?to=127.0.0.1:${sinkPort} HTTP/1.1\r\n` +
		`Host: 127.0.0.1:${relayPort}\r\n` +
		`Upgrade: websocket\r\nConnection: Upgrade\r\n` +
		`Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`;
	await conn.write(new TextEncoder().encode(upgrade));
	const resp = new Uint8Array(1024);
	const n = await conn.read(resp);
	if (n === null || !new TextDecoder().decode(resp.subarray(0, n)).includes("101")) {
		fail("relay did not accept the WebSocket upgrade");
	}

	// The relay sends nothing but the idle close, so the next read landing before
	// the ceiling — a close frame or EOF — means the idle timeout fired. Nothing
	// landing means the relay held the idle session open, which fails the clause.
	const start = Date.now();
	const closed = await Promise.race([
		conn.read(new Uint8Array(1024)).then(() => true),
		new Promise<boolean>((r) => setTimeout(() => r(false), CEILING_MS)),
	]);
	const elapsed = Date.now() - start;
	if (!closed) {
		fail(
			`the ${inv.label} relay did not close an idle session within ${CEILING_MS}ms — ` +
				`the idle-timeout clause is not honored`,
		);
	}
	try {
		conn.close();
	} catch {
		// already closed by the relay
	}
	console.log(`OK: the ${inv.label} relay closed an idle session after ${elapsed}ms`);
	clearTimeout(deadline);
} catch (err) {
	fail(`${inv.label} idle scenario failed: ${err instanceof Error ? err.message : String(err)}`);
} finally {
	kill(relayProcess);
	try {
		sink.close();
	} catch {
		// already closed
	}
	Deno.exit(0);
}
