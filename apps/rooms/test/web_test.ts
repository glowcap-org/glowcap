// Tests for serve.ts's non-page surface: the byte relay a browser peer dials the
// room server through, and the room-server supervision (attach, take-over).
//
// The page itself is a browser peer now — its end-to-end proof is
// `zig build rooms-web-page` (a real headless Chromium joining a room and
// round-tripping a line over the room capability). There is no JSON bridge
// left to test here; reachability is checked the way the page reaches the
// room: a keyed OCapN session established over `/relay`.

import { bareLocator, Session } from "@pancake/runtime";
import { classifyRelayTarget } from "../web/relay_target.ts";
import { nextRestartWait, RESTART_FIRST_WAIT_MS, RESTART_MAX_WAIT_MS, RESTART_STEADY_MS } from "../web/restart.ts";
import { roomsHost } from "../lib/locator.ts";
import { webSocketChannel } from "@pancake/runtime";
import { DIRECTORY, LIST } from "../lib/protocol.ts";
import {
	parseTcpPeers,
	relayAllowed,
	relayOriginAllowed,
	relaySessionAdmitted,
	rendezvousAdmitted,
	type TcpPeer,
} from "../web/relay.ts";
import { assertEquals } from "./assert.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const DENO_FLAGS = [
	"run",
	"--allow-ffi",
	"--allow-read",
	"--allow-write",
	"--allow-net",
	"--allow-run",
	"--allow-env",
];

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

async function waitForHttp(port: number): Promise<string> {
	const deadline = Date.now() + 10_000;
	let lastError: unknown;
	while (Date.now() < deadline) {
		try {
			return await fetch(`http://127.0.0.1:${port}/`).then((response) => response.text());
		} catch (err) {
			lastError = err;
			await delay(50);
		}
	}
	throw new Error(`rooms web UI did not start: ${lastError}`);
}

async function withWeb(
	fn: (httpPort: number, roomPort: number) => Promise<void>,
): Promise<void> {
	const httpPort = freePort();
	const roomPort = freePort();
	const proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await fn(httpPort, roomPort);
	} finally {
		await stopOwned(proc);
	}
}

/** Reach the room server the way the page does: dial its tcp locator through
 * serve.ts's `/relay` and list the directory. Resolves the room count on
 * success, throws otherwise. */
async function reachRoomThroughRelay(
	httpPort: number,
	roomPort: number,
): Promise<number> {
	const ws = new WebSocket(
		`ws://127.0.0.1:${httpPort}/relay?target=127.0.0.1:${roomPort}`,
	);
	await new Promise<void>((resolve, reject) => {
		ws.onopen = () => resolve();
		ws.onerror = () => reject(new Error("relay ws failed to open"));
	});
	const host = roomsHost(crypto.getRandomValues(new Uint8Array(32)));
	const session = await Session.establishDialedLocator(
		host,
		bareLocator("tcp", `127.0.0.1:${roomPort}`),
		webSocketChannel(ws),
	);
	try {
		const serving = session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const rooms = await session.send(directory, LIST, []) as unknown[];
		session.close();
		await serving;
		return rooms.length;
	} finally {
		await host.close();
	}
}

Deno.test("the relay allow-list and origin check refuse what they must", () => {
	// The web handler classifies the target through the shared core primitive,
	// then admits it; an unparseable locator fails the classify and is refused.
	const admits = (
		target: string,
		roomPort: number,
		peers: TcpPeer[] = [],
		roomOnion: string | null = null,
	): boolean => {
		try {
			return relayAllowed(classifyRelayTarget(target), roomPort, peers, roomOnion);
		} catch {
			return false;
		}
	};
	// A stand-in peer key: 64 hex digits, the shape the core validates a key
	// designator against (an iroh node id or a keyed-tcp key).
	const key = "a".repeat(64);
	// TCP is allowed only to the room server itself.
	assert(
		admits("127.0.0.1:9099", 9099),
		"the room server's port should be allowed",
	);
	assert(
		!admits("127.0.0.1:22", 9099),
		"another loopback port should be refused",
	);
	assert(
		!admits("10.0.0.8:9099", 9099),
		"a non-loopback host should be refused",
	);
	// iroh is any node; the keyed handshake carries the authority.
	assert(
		admits(`ocapn://${key}.iroh`, 9099),
		"an ocapn:// iroh URI should be allowed",
	);
	assert(
		!admits("https://example.com/", 9099),
		"a non-ocapn URI should be refused",
	);
	assert(
		!admits("ocapn://abc.iroh", 9099),
		"an iroh URI with a malformed node id should be refused",
	);
	// A keyed-tcp URI classifies to a TCP dial of its hint address, so the
	// room-only pin refuses one that names anything but the room server.
	assert(
		!admits(`ocapn://${key}.keyed-tcp?direct-addresses=10.0.0.8:9099`, 9099),
		"a keyed-tcp URI naming a non-room address should be refused",
	);
	// An onion target is allowed only when it names the room server this
	// process supervises; the relay holds no Tor client, so a foreign service
	// is not reachable through it at all.
	const serviceId = "a".repeat(56);
	assert(
		admits(`ocapn://${serviceId}.onion`, 9099, [], serviceId),
		"the supervised room's own onion service should be allowed",
	);
	assert(
		!admits(`ocapn://${"b".repeat(56)}.onion`, 9099, [], serviceId),
		"a foreign onion service should be refused",
	);
	assert(
		!admits(`ocapn://${serviceId}.onion`, 9099),
		"an onion target should be refused when the room is not an onion service",
	);

	// An operator names the cleartext-TCP peers a browser may direct-message —
	// a Goblins vat on a TCP netlayer is the ordinary one. Only the addresses
	// named are opened, and naming one opens nothing else on that host.
	const vat: TcpPeer[] = [{ hostname: "127.0.0.1", port: 9200 }];
	assert(
		admits("127.0.0.1:9200", 9099, vat),
		"a named TCP peer should be allowed",
	);
	assert(
		!admits("127.0.0.1:9201", 9099, vat),
		"an unnamed port on that host should be refused",
	);
	assert(
		!admits("127.0.0.1:22", 9099, vat),
		"a local service should still be refused",
	);
	assert(
		admits("127.0.0.1:9099", 9099, vat),
		"the room server is still allowed beside them",
	);

	// The list is read from one `host:port,host:port` string, and an entry that
	// cannot be read is dropped rather than taking the rest of the list with it.
	assertEquals(parseTcpPeers("127.0.0.1:9200, 10.0.0.8:9201"), [
		{ hostname: "127.0.0.1", port: 9200 },
		{ hostname: "10.0.0.8", port: 9201 },
	]);
	assertEquals(parseTcpPeers("[::1]:9200"), [{
		hostname: "[::1]",
		port: 9200,
	}]);
	assertEquals(
		parseTcpPeers("nonsense,127.0.0.1:0,127.0.0.1:70000,,127.0.0.1:9200"),
		[
			{ hostname: "127.0.0.1", port: 9200 },
		],
	);
	assertEquals(parseTcpPeers(""), []);
	assertEquals(parseTcpPeers(undefined), []);

	// Absent Origin (non-browser clients) passes; a mismatched or unparseable
	// Origin is refused before the WebSocket upgrade.
	assert(
		relayOriginAllowed(null, "127.0.0.1:8000"),
		"no Origin header should pass",
	);
	assert(
		relayOriginAllowed("http://127.0.0.1:8000", "127.0.0.1:8000"),
		"a same-origin page should pass",
	);
	assert(
		!relayOriginAllowed("http://evil.example:1234", "127.0.0.1:8000"),
		"a cross-origin page should be refused",
	);
	assert(
		!relayOriginAllowed("null", "127.0.0.1:8000"),
		"an opaque Origin should be refused",
	);
});

Deno.test("the relay capacity caps admit under the ceiling and refuse at it", () => {
	// The live-session cap (ADR-0086 bounded resources): admit below the ceiling,
	// refuse at or above it, so a slow-reader pileup cannot pin unbounded sessions.
	assert(relaySessionAdmitted(0, 100), "an idle relay admits a session");
	assert(relaySessionAdmitted(99, 100), "the last slot admits");
	assert(!relaySessionAdmitted(100, 100), "a full relay refuses");
	assert(!relaySessionAdmitted(101, 100), "an over-full relay refuses");

	// Registration admission counts held sockets, globally and per identity.
	assert(
		rendezvousAdmitted(0, 0, 200, 4),
		"an empty relay admits a registration",
	);
	assert(
		rendezvousAdmitted(199, 3, 200, 4),
		"the last global and identity slot admits",
	);
	assert(!rendezvousAdmitted(200, 0, 200, 4), "the global socket cap refuses");
	assert(
		!rendezvousAdmitted(10, 4, 200, 4),
		"one identity cannot bypass the global budget",
	);
});

Deno.test("a pancake peer reaches the room server through the /relay byte pipe", async () => {
	await withWeb(async (httpPort, roomPort) => {
		await waitForHttp(httpPort);
		// The relay refuses targets off the allow-list before upgrading.
		const refused = await fetch(
			`http://127.0.0.1:${httpPort}/relay?target=127.0.0.1:22`,
		);
		await refused.body?.cancel();
		assert(refused.status === 403, "off-list relay target should be refused");

		// A cross-origin page must not drive the relay, even at an allowed target.
		const crossOrigin = await fetch(
			`http://127.0.0.1:${httpPort}/relay?target=127.0.0.1:${roomPort}`,
			{ headers: { origin: "http://evil.example:1234" } },
		);
		await crossOrigin.body?.cancel();
		assert(
			crossOrigin.status === 403,
			"cross-origin relay upgrade should be refused",
		);

		const count = await reachRoomThroughRelay(httpPort, roomPort);
		assert(count >= 0, "the directory list should answer over the relay");
	});
});

Deno.test("a room server that will not start is waited on, one that was serving is not", () => {
	// The front brings its room server back when it exits. A server that had been
	// serving and then died is an accident and comes straight back; one that
	// cannot bind its port says so and exits at once, and starting it again as
	// fast as it can fail buries that message under thousands of copies of
	// itself. So the wait is a function of how long the last one ran.
	assert(nextRestartWait(0, RESTART_STEADY_MS) === 0, "a server that had been serving should come straight back");
	assert(
		nextRestartWait(RESTART_MAX_WAIT_MS, RESTART_STEADY_MS + 1) === 0,
		"a long run should clear the wait a run of refusals had built up",
	);

	let wait = nextRestartWait(0, 5);
	assert(wait === RESTART_FIRST_WAIT_MS, `the first wait after a refusal was ${wait}`);
	const seen = [wait];
	for (let i = 0; i < 12; i++) {
		const next = nextRestartWait(wait, 5);
		assert(next > wait || next === RESTART_MAX_WAIT_MS, `waiting stopped growing at ${wait} before its ceiling`);
		wait = next;
		seen.push(wait);
	}
	assert(wait === RESTART_MAX_WAIT_MS, `waiting grew past its ceiling to ${wait}`);
	assert(
		seen.every((ms) => ms <= RESTART_MAX_WAIT_MS),
		`a wait went past the ceiling: ${JSON.stringify(seen)}`,
	);
});

Deno.test("the web front reports a room server that cannot start, and stops", async () => {
	// The one failure a shutdown has to survive is the one that called it. This
	// path — the supervised room server refusing to start — was the only way into
	// `stop` before the rest of the file had finished evaluating, and `stopping`
	// is a `let`: the front announced the failure correctly and then died of a
	// ReferenceError inside its own clean shutdown, leaving the operator a stack
	// trace where a sentence belongs.
	const dir = await Deno.makeTempDir();
	try {
		await Deno.writeTextFile(
			`${dir}/rooms.json`,
			JSON.stringify({ version: 1, identitySeed: "zz", roomLinkSecret: "zz", linkedRooms: [] }) + "\n",
		);
		const proc = spawnOwned("deno", {
			args: [...DENO_FLAGS, `--allow-write=${dir}`, WEB, String(freePort()), String(freePort())],
			cwd: ROOT,
			env: { PANCAKE_ROOMS_STATE: dir },
			stdout: "piped",
			stderr: "piped",
		});
		const [status, said] = await Promise.all([
			proc.status,
			new Response(proc.stderr).text(),
			new Response(proc.stdout).text(),
		]);
		assert(!status.success, `the front exited ${status.code} when its room server could not start`);
		assert(
			said.includes("the room server did not start"),
			`the front did not say why it stopped: ${said}`,
		);
		assert(
			!said.includes("Cannot access") && !said.includes("ReferenceError"),
			`the front failed inside its own shutdown: ${said}`,
		);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

Deno.test("rooms web UI attaches to a room server already on its port", async () => {
	// Sharing a room port used to be fatal: the second instance's child could not
	// bind and the process failed to start. Now the second attaches to the first.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const spawnWeb = (httpPort: number) =>
		spawnOwned("deno", {
			args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		});

	const first = spawnWeb(httpFirst);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForHttp(httpFirst); // the first now owns roomPort
		second = spawnWeb(httpSecond);
		const page = await waitForHttp(httpSecond);
		assert(
			page.includes("pancake rooms"),
			"the attached instance should serve the page",
		);
		// A peer dialing through the second instance reaches the shared room.
		await reachRoomThroughRelay(httpSecond, roomPort);
	} finally {
		for (const proc of [second, first]) {
			if (proc) await stopOwned(proc);
		}
	}
});

Deno.test("rooms web UI takes over when an attached room server dies", async () => {
	// Attach must not leave the second instance forever pointing at a dead locator
	// after the owning serve.ts exits and tears down the shared child.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const spawnWeb = (httpPort: number) =>
		spawnOwned("deno", {
			args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		});

	const first = spawnWeb(httpFirst);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForHttp(httpFirst);
		second = spawnWeb(httpSecond);
		await waitForHttp(httpSecond);

		try {
			first.kill("SIGINT");
		} catch {
			// Already gone.
		}
		await first.status;

		// The second must take over the room and stay reachable through its relay.
		const deadline = Date.now() + 15_000;
		let reached = false;
		let lastError: unknown;
		while (Date.now() < deadline) {
			try {
				await reachRoomThroughRelay(httpSecond, roomPort);
				reached = true;
				break;
			} catch (err) {
				lastError = err;
				await delay(250);
			}
		}
		assert(
			reached,
			`attached web did not take over after owner exit: ${lastError}`,
		);
	} finally {
		for (const proc of [second, first]) {
			if (proc) await stopOwned(proc);
		}
	}
});
