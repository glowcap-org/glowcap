import * as tcp from "@glowcap/tcp";
// The TCP relay proof, parameterized over the relay program. A wasm browser peer
// holds a keyed OCapN session when its WebSocket routes through a byte-transparent
// relay to a native TCP host. One harness proves this for every runtime's relay
// (Deno, Python, Rust, …); the relay under test is named on the command line.
// See `relay_harness_common.ts` for the argument shape.
//
// Three processes: a native TCP host, the relay forwarding WebSocket ↔ TCP, and
// the browser peer (wasm) dialing through it. The relay never parses a frame, so
// the keyed handshake and the greet round-trip succeed end to end.

import { init } from "@glowcap/web";
import { fail, kill, parseHarnessArgs, readToken, spawnRelay, WASM } from "./relay_harness_common.ts";

const inv = parseHarnessArgs(Deno.args);
const deadline = setTimeout(() => fail(`${inv.label} relay scenario timed out after 60s`), 60_000);

// 1. Native host on an ephemeral loopback TCP port, printing its JSON line.
const hostProcess = new Deno.Command(Deno.execPath(), {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		import.meta.dirname + "/serve_ws_host.ts",
		"--tcp-only",
		"127.0.0.1:0",
	],
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const hostReady = JSON.parse(await readToken(hostProcess, /(\{"ready".*\})\n/)) as {
	port: number;
	designator: string;
};

// 2. The relay program under test, spawned from the root with its environment.
const relayProcess = spawnRelay(inv);
const relayPort = await readToken(relayProcess, new RegExp(`${inv.marker} (\\d+)`));

try {
	// 3. Load the wasm browser peer; every dial's WebSocket routes through the
	// relay, which is told the target via `?to=host:port`.
	const runtime = await init({
		wasm: await Deno.readFile(WASM),
		wsUrl: (host, port) => `ws://127.0.0.1:${relayPort}/relay?to=${host}:${port}`,
	});

	// 4. Dial the host's keyed locator through the relay, then prove the session
	// end to end.
	const session = await runtime.connect(
		tcp.keyed.locator(hostReady.designator, "127.0.0.1", hostReady.port),
	);
	const greeter = await session.fetch("greeter");
	const reply = await session.send(greeter, "greet", [`${inv.label} Relay`]);
	const expected = `hello ${inv.label} Relay`;
	if (reply !== expected) fail(`expected "${expected}", got "${String(reply)}"`);

	console.log(`OK: browser peer held a keyed session through the ${inv.label} relay`);
	clearTimeout(deadline);
	await session.close();
} catch (err) {
	fail(`${inv.label} relay scenario failed: ${err instanceof Error ? err.message : String(err)}`);
} finally {
	kill(relayProcess);
	kill(hostProcess);
	Deno.exit(0);
}
