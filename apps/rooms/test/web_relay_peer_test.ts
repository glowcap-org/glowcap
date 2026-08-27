import * as tcp from "@pancake/tcp";
// The rooms browser-peer proof:
// a wasm browser peer drives the real room-directory capabilities through
// serve.ts's `/relay` byte pipe, with no native dlopen anywhere in this process.
//
// This is the load-bearing slice — it retires the one real risk in
// moving the browser onto the runtime. Like `bindings/ts/web/test/web_peer_test.ts`,
// it is its own process so the wasm adapter and any native runtime never share a
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
// The profile constants only — importing `lib/locator.ts` would pull
// `@pancake/runtime` in before `init` installs the wasm adapter, and the runtime
// binds its adapter at load. So the browser peer's Host is minted from the
// `init` returns, wearing the same pair every other rooms peer wears.
import { CAPTP_VERSION, CODEC } from "../lib/protocol.ts";
import { reapOwned, spawnOwned } from "./support/children.ts";
import { freePort, waitForHttp } from "./support/rooms_server.ts";
import { fail } from "./support/page.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const WASM = new URL("../../../zig-out/wasm/pancake_host.wasm", import.meta.url);

const deadline = setTimeout(() => fail("relay-peer scenario timed out after 30s"), 30_000);

const httpPort = freePort();
const roomPort = freePort();
spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
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
});

try {
	await waitForHttp(httpPort);

	// Load the runtime over the wasm peer, dialing every locator through the
	// relay: host:port becomes ws://<web-host>/relay?target=host:port.
	const runtime = await init({
		wasm: await Deno.readFile(WASM),
		wsUrl: (host, port) => `ws://127.0.0.1:${httpPort}/relay?target=${host}:${port}`,
		codec: CODEC,
		captpVersion: CAPTP_VERSION,
	});

	// A plain tcp locator to the room server, dialed through the relay. The
	// keyed handshake terminates inside the wasm session.
	const session = await runtime.connect(tcp.locator("127.0.0.1", roomPort));
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
	await reapOwned();
}
Deno.exit(0);
