// Starting the installed `rooms-web` front for a test, and reaching the room
// it supervises the way the page does, through its `/relay`.

import { bareLocator, Session, webSocketChannel } from "@glowcap/runtime";
import { roomsHost } from "../../lib/locator.ts";
import { DIRECTORY, LIST } from "../../lib/protocol.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { ROOT, WEB } from "../support/paths.ts";
import { freePort } from "../support/ports.ts";
import { delay, within } from "../support/wait.ts";

export { delay, ROOT, WEB };

function remaining(deadline: number, what: string): number {
	const ms = deadline - Date.now();
	if (ms <= 0) throw new Error(`timed out waiting for ${what}`);
	return ms;
}

function before<T>(start: () => Promise<T>, what: string, deadline: number): Promise<T> {
	const wait = remaining(deadline, what);
	return within(start(), what, wait);
}

/** Fetch the served index page once the web UI answers on `port`. Not the
 * `/locator` readiness probe in support: this reads the page body. */
export async function waitForIndex(port: number, deadline = Date.now() + 10_000): Promise<string> {
	let lastError: unknown;
	while (Date.now() < deadline) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/`, {
				signal: AbortSignal.timeout(remaining(deadline, "rooms web UI")),
			});
			return await before(() => response.text(), "rooms web UI body", deadline);
		} catch (err) {
			lastError = err;
			if (Date.now() < deadline) await delay(Math.min(50, remaining(deadline, "rooms web UI")));
		}
	}
	throw new Error(`rooms web UI did not start: ${lastError}`);
}

export function spawnWeb(httpPort: number, roomPort: number): Deno.ChildProcess {
	return spawnOwned(WEB, {
		args: ["--transport=tcp", String(httpPort), String(roomPort)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

export async function withWeb(
	fn: (httpPort: number, roomPort: number) => Promise<void>,
): Promise<void> {
	const httpPort = freePort();
	const roomPort = freePort();
	const proc = spawnWeb(httpPort, roomPort);
	try {
		await fn(httpPort, roomPort);
	} finally {
		await stopOwned(proc);
	}
}

/** Reach the room server the way the page does: dial its tcp locator through
 * `rooms-web`'s `/relay` and list the directory. Resolves the room count on
 * success, throws otherwise. */
export async function reachRoomThroughRelay(
	httpPort: number,
	roomPort: number,
	deadline = Date.now() + 10_000,
): Promise<number> {
	const ws = new WebSocket(
		`ws://127.0.0.1:${httpPort}/relay?target=127.0.0.1:${roomPort}`,
	);
	let host: ReturnType<typeof roomsHost> | null = null;
	let session: Session | null = null;
	let serving: Promise<void> | null = null;
	// A wire fault the inbound loop ends with, kept until the cleanup below
	// can report it as this call's failure rather than as a stray rejection.
	let servedFault: unknown = null;
	let outcome: { ok: true; roomCount: number } | { ok: false; error: unknown };
	try {
		await before(
			() =>
				new Promise<void>((resolve, reject) => {
					ws.onopen = () => resolve();
					ws.onerror = () => reject(new Error("relay ws failed to open"));
				}),
			"relay WebSocket open",
			deadline,
		);
		const openedHost = roomsHost(crypto.getRandomValues(new Uint8Array(32)));
		host = openedHost;
		const openedSession = await before(
			() =>
				Session.establishDialedLocator(
					openedHost,
					bareLocator("tcp", `127.0.0.1:${roomPort}`),
					webSocketChannel(ws),
				),
			"relay CapTP handshake",
			deadline,
		);
		session = openedSession;
		serving = openedSession.serve().catch((error: unknown) => {
			servedFault = error;
		});
		const directory = await before(() => openedSession.fetch(DIRECTORY), "relay directory fetch", deadline);
		const rooms = await before(
			() => openedSession.send(directory, LIST, []) as Promise<unknown[]>,
			"relay directory list",
			deadline,
		);
		outcome = { ok: true, roomCount: rooms.length };
	} catch (error) {
		outcome = { ok: false, error };
	}

	const sessionCleanupDeadline = Date.now() + 2_000;
	const retirements: Promise<unknown>[] = [];
	if (session !== null) retirements.push(session.close());
	if (serving !== null) retirements.push(serving);
	let cleanupFailure: unknown | null = null;
	try {
		const settled = await before(
			() => Promise.allSettled(retirements),
			"relay session cleanup",
			sessionCleanupDeadline,
		);
		const rejected = settled.find((result) => result.status === "rejected");
		if (rejected?.status === "rejected") cleanupFailure ??= rejected.reason;
	} catch (error) {
		cleanupFailure ??= error;
	}
	try {
		ws.close();
	} catch (error) {
		cleanupFailure ??= error;
	}
	if (host !== null) {
		const closingHost = host;
		try {
			await before(() => closingHost.close(), "relay Host cleanup", Date.now() + 2_000);
		} catch (error) {
			cleanupFailure ??= error;
		}
	}
	if (!outcome.ok) throw outcome.error;
	if (cleanupFailure !== null) throw cleanupFailure;
	if (servedFault !== null) throw servedFault;
	return outcome.roomCount;
}
