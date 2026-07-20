// Tests for web.ts's non-page surface: the byte relay a browser peer dials the
// room server through, and the room-server supervision (attach, take-over).
//
// The page itself is a browser peer now — its end-to-end proof is
// `zig build rooms-web-page` (a real headless Chromium joining a room and
// round-tripping a line over the room capability). There is no JSON bridge
// left to test here; reachability is checked the way the page reaches the
// room: a keyed OCapN session established over `/relay`.

import { Host as PancakeHost, Session } from "@pancake/stack";
import { webSocketChannel } from "@pancake/web/channel";
import { DIRECTORY, LIST } from "../lib/protocol.ts";
import { relayAllowed, relayOriginAllowed } from "./relay_server.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const WEB = new URL("./web.ts", import.meta.url).pathname;
const DENO_FLAGS = [
	"run",
	"--allow-ffi",
	"--allow-read",
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
	const proc = new Deno.Command("deno", {
		args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	try {
		await fn(httpPort, roomPort);
	} finally {
		try {
			proc.kill("SIGINT");
		} catch {
			// Already gone.
		}
		await proc.status;
	}
}

/** Reach the room server the way the page does: dial its tcp locator through
 * web.ts's `/relay` and list the directory. Resolves the room count on
 * success, throws otherwise. */
async function reachRoomThroughRelay(httpPort: number, roomPort: number): Promise<number> {
	const ws = new WebSocket(`ws://127.0.0.1:${httpPort}/relay?to=127.0.0.1:${roomPort}`);
	await new Promise<void>((resolve, reject) => {
		ws.onopen = () => resolve();
		ws.onerror = () => reject(new Error("relay ws failed to open"));
	});
	const host = new PancakeHost(crypto.getRandomValues(new Uint8Array(32)));
	const session = await Session.establishDialedLocator(
		host,
		"tcp",
		`127.0.0.1:${roomPort}`,
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
		host.release();
	}
}

Deno.test("the relay allow-list and origin check refuse what they must", () => {
	// TCP is allowed only to the room server itself.
	assert(relayAllowed("127.0.0.1:9099", 9099), "the room server's port should be allowed");
	assert(!relayAllowed("127.0.0.1:22", 9099), "another loopback port should be refused");
	assert(!relayAllowed("10.0.0.8:9099", 9099), "a non-loopback host should be refused");
	// iroh is any ocapn:// URI; the keyed handshake carries the authority.
	assert(relayAllowed("ocapn://abc.iroh", 9099), "an ocapn:// URI should be allowed");
	assert(!relayAllowed("https://example.com/", 9099), "a non-ocapn URI should be refused");

	// Absent Origin (non-browser clients) passes; a mismatched or unparseable
	// Origin is refused before the WebSocket upgrade.
	assert(relayOriginAllowed(null, "127.0.0.1:8000"), "no Origin header should pass");
	assert(
		relayOriginAllowed("http://127.0.0.1:8000", "127.0.0.1:8000"),
		"a same-origin page should pass",
	);
	assert(
		!relayOriginAllowed("http://evil.example:1234", "127.0.0.1:8000"),
		"a cross-origin page should be refused",
	);
	assert(!relayOriginAllowed("null", "127.0.0.1:8000"), "an opaque Origin should be refused");
});

Deno.test("a pancake peer reaches the room server through the /relay byte pipe", async () => {
	await withWeb(async (httpPort, roomPort) => {
		await waitForHttp(httpPort);
		// The relay refuses targets off the allow-list before upgrading.
		const refused = await fetch(`http://127.0.0.1:${httpPort}/relay?to=127.0.0.1:22`);
		await refused.body?.cancel();
		assert(refused.status === 403, "off-list relay target should be refused");

		// A cross-origin page must not drive the relay, even at an allowed target.
		const crossOrigin = await fetch(
			`http://127.0.0.1:${httpPort}/relay?to=127.0.0.1:${roomPort}`,
			{ headers: { origin: "http://evil.example:1234" } },
		);
		await crossOrigin.body?.cancel();
		assert(crossOrigin.status === 403, "cross-origin relay upgrade should be refused");

		const count = await reachRoomThroughRelay(httpPort, roomPort);
		assert(count >= 0, "the directory list should answer over the relay");
	});
});

Deno.test("rooms web UI attaches to a room server already on its port", async () => {
	// Sharing a room port used to be fatal: the second instance's child could not
	// bind and the process failed to start. Now the second attaches to the first.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const spawnWeb = (httpPort: number) =>
		new Deno.Command("deno", {
			args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		}).spawn();

	const first = spawnWeb(httpFirst);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForHttp(httpFirst); // the first now owns roomPort
		second = spawnWeb(httpSecond);
		const page = await waitForHttp(httpSecond);
		assert(page.includes("pancake rooms"), "the attached instance should serve the page");
		// A peer dialing through the second instance reaches the shared room.
		await reachRoomThroughRelay(httpSecond, roomPort);
	} finally {
		for (const proc of [second, first]) {
			if (!proc) continue;
			try {
				proc.kill("SIGINT");
			} catch {
				// Already gone.
			}
			await proc.status;
		}
	}
});

Deno.test("rooms web UI takes over when an attached room server dies", async () => {
	// Attach must not leave the second instance forever pointing at a dead locator
	// after the owning web.ts exits and tears down the shared child.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const spawnWeb = (httpPort: number) =>
		new Deno.Command("deno", {
			args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		}).spawn();

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
		assert(reached, `attached web did not take over after owner exit: ${lastError}`);
	} finally {
		for (const proc of [second, first]) {
			if (!proc) continue;
			try {
				proc.kill("SIGINT");
			} catch {
				// Already gone.
			}
			try {
				await proc.status;
			} catch {
				// Already reaped.
			}
		}
	}
});
