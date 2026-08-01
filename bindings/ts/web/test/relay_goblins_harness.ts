// The live Goblins leg of the relay proof. A wasm browser peer holds a keyed
// OCapN session with a real Spritely Goblins vat when its WebSocket routes
// through the byte-transparent Deno reference relay to the vat's TCP port.
//
// Three processes: the conformance Goblins vat on a fixed loopback TCP port,
// the reference relay forwarding WebSocket ↔ TCP, and the browser peer (wasm)
// dialing through it. The relay links no codec and never parses a frame, so
// byte transparency is structural; what this harness observes is its
// consequence. The keyed handshake is signature-verified end to end — a relay
// that re-framed, re-encoded, or reordered one byte would fail it — and then
// the enliven settles, the echo returns the exact bytes sent, and a repeat
// enliven of the same swiss-num dedups to the same import (ADR-0012), so the
// proof covers more than one frame shape.
//
// Needs `racket` + `goblins` on PATH; `zig build goblins-relay`. The vat's
// fixed port defaults to 22160; `--port=N` (from -Dport=N) moves it.

import { init } from "@pancake/web";
import { fail, kill, readToken, ROOT, WASM } from "./relay_harness_common.ts";

let goblinsPort = 22160;
for (const a of Deno.args) {
	if (a.startsWith("--port=")) goblinsPort = Number(a.slice("--port=".length));
	else fail(`unknown argument "${a}"`);
}
if (!Number.isInteger(goblinsPort) || goblinsPort < 1 || goblinsPort > 65535) {
	fail("--port must be an integer in 1..65535");
}

const deadline = setTimeout(() => fail("Goblins relay scenario timed out after 60s"), 60_000);

// 1. The conformance Goblins vat — the same one `goblins-interop` dials —
// publishing its echo cap and printing the swiss-num on an NDJSON line.
const goblinsProcess = new Deno.Command("racket", {
	args: ["conformance/goblins-peer/racket/goblins-host.rkt", "127.0.0.1", String(goblinsPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const swiss = await readToken(goblinsProcess, /"swiss":"([^"]+)"/);

// 2. The Deno reference relay on an ephemeral port.
const relayProcess = new Deno.Command(Deno.execPath(), {
	args: ["run", "--allow-net", "--allow-read", "--allow-env", "bindings/ts/relay/serve.ts", "0"],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const relayPort = await readToken(relayProcess, /DENO-RELAY-READY (\d+)/);

try {
	// 3. Load the wasm browser peer; every dial's WebSocket routes through the
	// relay, which is told the target via `?to=host:port`.
	const stack = await init({
		wasm: await Deno.readFile(WASM),
		wsUrl: (host, port) => `ws://127.0.0.1:${relayPort}/relay?to=${host}:${port}`,
	});

	// 4. Dial the vat through the relay. Goblins speaks plain `tcp` (not
	// `keyed-tcp`), and `connect` completes the keyed `op:start-session`:
	// reaching the next line means Goblins accepted our signed hello through
	// the relay and we accepted its.
	const locator = stack.tcpLocator("127.0.0.1", goblinsPort);
	const conn = await stack.connect(locator);
	conn.serve().catch(() => {}); // the partner hanging up ends the serve loop

	// 5. Enliven the echo cap and prove the round-trip content survives. The
	// echo actor is `(lambda args args)`, so assert the bytes, not mere
	// settlement. Goblins invokes a cap positionally, hence verb "".
	const sturdyref = `${locator}/s/${swiss}`;
	const echo = await conn.enliven(sturdyref);
	const reply = await conn.send(echo, "", [new TextEncoder().encode("relay-ping")]);
	if (!Array.isArray(reply) || reply.length !== 1 || !(reply[0] instanceof Uint8Array)) {
		fail(`echo reply is not a one-bytes list: ${JSON.stringify(reply)}`);
	}
	const text = new TextDecoder().decode(reply[0] as Uint8Array);
	if (text !== "relay-ping") fail(`echo returned ${JSON.stringify(text)}, expected "relay-ping"`);

	// 6. A repeat enliven of the same swiss-num returns the same far import
	// (the ADR-0012 dedup cache), exercising a second frame shape through the
	// relay.
	const again = await conn.enliven(sturdyref);
	if (
		echo.id !== again.id
	) {
		fail("repeat enliven did not return the same far import (dedup miss)");
	}

	console.log("OK: browser peer held a keyed session with live Goblins through the relay");
	clearTimeout(deadline);
	conn.close();
} catch (err) {
	fail(`Goblins relay scenario failed: ${err instanceof Error ? err.message : String(err)}`);
} finally {
	kill(relayProcess);
	kill(goblinsProcess);
	Deno.exit(0);
}
