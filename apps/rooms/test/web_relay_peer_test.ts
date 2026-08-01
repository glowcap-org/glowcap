// The rooms-web browser-peer proof:
// a wasm browser peer drives the real room-directory capabilities through
// serve.ts's `/relay` byte pipe, with no native dlopen anywhere in this process.
//
// This is the load-bearing slice — it retires the one real risk in
// moving the browser onto the stack. Like `bindings/ts/web/test/web_peer_test.ts`,
// it is its own process so the wasm adapter and any native stack never share a
// module graph: this process loads ONLY `@pancake/web`; the room server and
// serve.ts's relay run as child processes with their own native graphs. If this
// is green, the served-page work that remains (bundle the graph, swap the
// DOM wiring, delete the JSON bridge) is wiring over a proven mechanism.
//
// The trick is one line: the wasm binding dials by mapping a locator's
// host:port to a WebSocket URL (`wsUrl`), so pointing that at
// `ws://<web-host>/relay?target=host:port` sends the whole keyed OCapN session
// through the relay to the room's TCP socket. The browser peer holds the
// directory capability itself; the relay only moves bytes.

import { init } from "@pancake/web";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const WASM = new URL("../../../zig-out/wasm/pancake_host.wasm", import.meta.url);

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 200; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200 || res.status === 503) return;
		} catch {
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer on its HTTP port");
}

const deadline = setTimeout(() => fail("relay-peer scenario timed out after 30s"), 30_000);

const httpPort = freePort();
const roomPort = freePort();
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

try {
	await waitForHttp(httpPort);

	// Load the stack over the wasm peer, dialing every locator through the
	// relay: host:port becomes ws://<web-host>/relay?target=host:port.
	const stack = await init({
		wasm: await Deno.readFile(WASM),
		wsUrl: (host, port) => `ws://127.0.0.1:${httpPort}/relay?target=${host}:${port}`,
	});

	// A plain tcp locator to the room server, dialed through the relay. The
	// keyed handshake terminates inside the wasm session.
	const session = await stack.connect(stack.tcpLocator("127.0.0.1", roomPort));
	session.serve().catch(() => {});
	try {
		// The real room vocabulary, as a capability call from the wasm peer —
		// no JSON bridge in the path.
		const directory = await session.fetch("directory");
		const rooms = await session.send(directory, "list", []);
		if (!Array.isArray(rooms)) {
			fail(`directory list did not answer an array: ${JSON.stringify(rooms)}`);
		}
	} finally {
		session.close();
	}

	console.log(
		"PASS: a wasm browser peer fetched the room directory and listed rooms " +
			"through serve.ts's /relay byte pipe (no dlopen, no JSON bridge)",
	);
} finally {
	clearTimeout(deadline);
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
