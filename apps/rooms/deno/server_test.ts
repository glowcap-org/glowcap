import { connect, type Ref, type Session, tcpLocator } from "@pancake/stack";
import {
	DIRECTORY,
	ENTER,
	LEAVE,
	LIST,
	NOTIFY,
	OPEN,
	POST,
	REGISTER,
	SUBSCRIBE,
	WATCH,
} from "../lib/protocol.ts";
import { NICK_TAKEN, NO_SUCH_ROOM, ROOM_EXISTS, type RoomErrorCode } from "../lib/errors.ts";
import { roomErrorOf } from "./lib/errors.ts";
import { dial, loopbackTcpDesignator } from "./lib/locator.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const SERVER = new URL("./server.ts", import.meta.url).pathname;
const RACKET_CLIENT = new URL("../racket/client.rkt", import.meta.url).pathname;
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];
// iroh dials through the sidecar over nonblocking FFI, which needs broader
// permissions and --unstable-ffi; the server reads its own lib path.
const IROH_FLAGS = ["run", "-A", "--unstable-ffi"];

// The optional iroh ABI companion library (`zig build iroh-abi`, needs cargo).
// The iroh tests below skip when it is absent, matching the demo's
// join-when-available posture, so this suite stays green without cargo.
const IROH_LIB = new URL(
	`../../../zig-out/lib/${
		Deno.build.os === "darwin"
			? "libpancake_net_transport_iroh.dylib"
			: Deno.build.os === "windows"
			? "pancake_net_transport_iroh.dll"
			: "libpancake_net_transport_iroh.so"
	}`,
	import.meta.url,
).pathname;

function irohLibPresent(): boolean {
	try {
		Deno.statSync(IROH_LIB);
		return true;
	} catch {
		return false; // not built (no cargo), skip the iroh tests
	}
}

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

function assertMatch(value: string, pattern: RegExp): void {
	if (!pattern.test(value)) {
		throw new Error(`expected ${JSON.stringify(value)} to match ${pattern}`);
	}
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function onPath(cmd: string): Promise<boolean> {
	try {
		const out = await new Deno.Command(cmd, {
			args: ["--version"],
			stdout: "null",
			stderr: "null",
		}).output();
		return out.success;
	} catch {
		return false;
	}
}

async function readPort(proc: Deno.ChildProcess): Promise<number> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 10_000;
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			const chunk = await Promise.race([
				reader.read(),
				delay(remaining).then(() => undefined),
			]);
			if (chunk === undefined) break;
			const { value, done } = chunk;
			if (done) break;
			buf += decoder.decode(value, { stream: true });
			const match = buf.match(/ROOMS-SERVER-LISTENING (\d+)/);
			if (match) return Number(match[1]);
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error("rooms server never announced its port");
}

async function withServer(fn: (port: number) => Promise<void>): Promise<void> {
	const proc = new Deno.Command("deno", {
		args: [...DENO_FLAGS, SERVER, "0"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	try {
		await fn(await readPort(proc));
	} finally {
		try {
			proc.kill("SIGTERM");
		} catch {
			// Already gone.
		}
		await proc.status;
	}
}

/** Read the server's announce token (`ROOMS-SERVER-LISTENING <token>`), the iroh
 * ocapn:// URI a client dials. Like `readPort`, but the token is a URI, not a
 * port. */
async function readAnnounce(proc: Deno.ChildProcess): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 10_000;
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			const chunk = await Promise.race([
				reader.read(),
				delay(remaining).then(() => undefined),
			]);
			if (chunk === undefined) break;
			const { value, done } = chunk;
			if (done) break;
			buf += decoder.decode(value, { stream: true });
			const match = buf.match(/ROOMS-SERVER-LISTENING (\S+)/);
			if (match) return match[1];
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error("rooms server never announced its locator");
}

/** Run the rooms server over iroh and hand its dialable ocapn:// URI to `fn`. */
async function withIrohServer(
	fn: (uri: string) => Promise<void>,
): Promise<void> {
	const proc = new Deno.Command("deno", {
		args: [...IROH_FLAGS, SERVER, "--transport=iroh"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	try {
		await fn(await readAnnounce(proc));
	} finally {
		try {
			proc.kill("SIGTERM");
		} catch {
			// Already gone.
		}
		await proc.status;
	}
}

/** Enter the named room over `session`, opening it if it does not exist, the
 * directory dance every client does, inlined here so the tests drive the same
 * wire the clients do. */
async function enterOrOpen(session: Session, room: string): Promise<Ref> {
	const directory = await session.fetch(DIRECTORY);
	try {
		return await session.send(directory, ENTER, [room]) as Ref;
	} catch (err) {
		if (roomErrorOf(err)?.code !== NO_SUCH_ROOM) throw err;
	}
	try {
		return await session.send(directory, OPEN, [room]) as Ref;
	} catch (err) {
		if (roomErrorOf(err)?.code !== ROOM_EXISTS) throw err;
		return await session.send(directory, ENTER, [room]) as Ref;
	}
}

/** Subscribe one member to a room over an already-dialed connection, return its
 * welcome, and close. The transport (TCP or iroh) is whatever the connection
 * rides. */
async function subscribeOnceConn(
	session: Session,
	room: string,
	nick: string,
): Promise<string> {
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	// The welcome + roster arrive as the first `notify` (a "roster" line), not as the
	// subscribe return, so capture it off the inbox.
	let resolveWelcome!: (w: string) => void;
	const welcome = new Promise<string>((r) => (resolveWelcome = r));
	const inbox = session.spawn((verb, args) => {
		if (verb === NOTIFY && args[2] === "roster" && typeof args[1] === "string") {
			resolveWelcome(args[1]);
		}
		return null;
	});
	await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
	const text = await welcome;
	session.close();
	await session.serve().catch(() => {});
	return text;
}

async function subscribeOnce(
	port: number,
	room: string,
	nick: string,
): Promise<string> {
	return subscribeOnceConn(
		await connect(tcpLocator("127.0.0.1", port)),
		room,
		nick,
	);
}

async function subscribeOnceIroh(
	uri: string,
	room: string,
	nick: string,
): Promise<string> {
	return subscribeOnceConn(await dial(uri), room, nick);
}

async function trySubscribe(port: number, room: string, nick: string): Promise<{
	ok: boolean;
	code?: RoomErrorCode | null;
	leave: () => Promise<void>;
}> {
	const session = await connect(tcpLocator("127.0.0.1", port));
	session.serve().catch(() => {});
	try {
		const roomRef = await enterOrOpen(session, room);
		const inbox = session.spawn(() => null);
		await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
		return {
			ok: true,
			leave: async () => {
				session.close();
				await session.serve().catch(() => {});
			},
		};
	} catch (err) {
		session.close();
		await session.serve().catch(() => {});
		return {
			ok: false,
			code: roomErrorOf(err)?.code ?? null,
			leave: async () => {},
		};
	}
}

async function subscribeTwiceAndClose(
	port: number,
	room: string,
): Promise<void> {
	const session = await connect(tcpLocator("127.0.0.1", port));
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn(() => null);
	await session.send(roomRef, SUBSCRIBE, ["first-a", inbox]);
	await session.send(roomRef, SUBSCRIBE, ["first-b", inbox]);
	session.close();
	await session.serve().catch(() => {});
}

async function resubscribeAndHold(port: number, room: string): Promise<{
	leave: () => Promise<void>;
}> {
	const session = await connect(tcpLocator("127.0.0.1", port));
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn(() => null);
	await session.send(roomRef, SUBSCRIBE, ["first-a", inbox]);
	await session.send(roomRef, SUBSCRIBE, ["first-b", inbox]);
	return {
		leave: async () => {
			session.close();
			await session.serve().catch(() => {});
		},
	};
}

async function waitForMatch(
	getValue: () => Promise<string>,
	pattern: RegExp,
): Promise<string> {
	const deadline = Date.now() + 2_000;
	let last = "";
	while (Date.now() < deadline) {
		last = await getValue();
		if (pattern.test(last)) return last;
		await delay(25);
	}
	throw new Error(`expected ${JSON.stringify(last)} to match ${pattern}`);
}

async function watchRoomConn(
	session: Session,
	room: string,
	nick: string,
): Promise<{
	lines: string[];
	leave: () => Promise<void>;
}> {
	session.serve().catch(() => {});
	const lines: string[] = [];
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn((_verb, args) => {
		const from = typeof args[0] === "string" ? args[0] : "?";
		const text = typeof args[1] === "string" ? args[1] : "";
		lines.push(`${from}: ${text}`);
		return null;
	});
	await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
	return {
		lines,
		leave: async () => {
			session.close();
			await session.serve().catch(() => {});
		},
	};
}

async function watchRoom(port: number, room: string, nick: string) {
	return watchRoomConn(
		await connect(tcpLocator("127.0.0.1", port)),
		room,
		nick,
	);
}

async function watchRoomIroh(uri: string, room: string, nick: string) {
	return watchRoomConn(await dial(uri), room, nick);
}

async function waitForLine(lines: string[], pattern: RegExp): Promise<string> {
	const deadline = Date.now() + 2_000;
	while (Date.now() < deadline) {
		const found = lines.find((line) => pattern.test(line));
		if (found) return found;
		await delay(25);
	}
	throw new Error(`expected ${JSON.stringify(lines)} to contain ${pattern}`);
}

Deno.test("rooms directory opens a room and rejects opening it twice", async () => {
	await withServer(async (port) => {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			const room = await session.send(directory, OPEN, ["lounge"]);
			assert(room !== null, "open should return a room reference");

			let duplicateError = "";
			try {
				await session.send(directory, OPEN, ["lounge"]);
			} catch (err) {
				duplicateError = err instanceof Error ? err.message : String(err);
			}
			assertMatch(duplicateError, /room "lounge" already exists/);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

Deno.test("rooms directory rejects entering a room that does not exist", async () => {
	await withServer(async (port) => {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			let missingError = "";
			try {
				await session.send(directory, ENTER, ["nowhere"]);
			} catch (err) {
				missingError = err instanceof Error ? err.message : String(err);
			}
			assertMatch(missingError, /no room named "nowhere"/);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

Deno.test("rooms in different rooms do not see each other's posts", async () => {
	await withServer(async (port) => {
		const lounge = await watchRoom(port, "lounge", "in-lounge");
		const garden = await watchRoom(port, "garden", "in-garden");
		await waitForLine(lounge.lines, /^room: in-lounge joined/);
		await waitForLine(garden.lines, /^room: in-garden joined/);

		const talker = await watchRoom(port, "lounge", "talker");
		await waitForLine(lounge.lines, /^room: talker joined \(2 here\)$/);

		// The garden never hears the lounge fill up, and the same nick is free there.
		await delay(150);
		assert(
			!garden.lines.some((line) => /talker/.test(line)),
			`garden should not see lounge traffic, got ${JSON.stringify(garden.lines)}`,
		);

		await lounge.leave();
		await talker.leave();
		await garden.leave();
	});
});

Deno.test("rooms server frees a room name once its last member leaves", async () => {
	await withServer(async (port) => {
		// Opening a room then leaving empties it; the name is reusable, and a fresh
		// room starts the count over at 1.
		assertMatch(
			await subscribeOnce(port, "ephemeral", "first"),
			/1 in the room: first$/,
		);
		await waitForMatch(
			() => subscribeOnce(port, "ephemeral", "second"),
			/1 in the room: second$/,
		);
	});
});

Deno.test("rooms server grants each live nickname once per room", async () => {
	await withServer(async (port) => {
		const first = await trySubscribe(port, "lobby", "Claimed");
		assert(first.ok, "first claim should succeed");
		const duplicate = await trySubscribe(port, "lobby", "claimed");
		assert(!duplicate.ok, "duplicate live claim should fail");
		assert(duplicate.code === NICK_TAKEN, "duplicate live claim should be nick-taken");

		// The same nickname is free in a different room.
		const elsewhere = await trySubscribe(port, "annex", "claimed");
		assert(elsewhere.ok, "the same nick should be free in another room");
		await elsewhere.leave();

		await first.leave();

		const reclaimed = await trySubscribe(port, "lobby", "CLAIMED");
		assert(reclaimed.ok, "released name should be claimable again");
		await reclaimed.leave();
	});
});

Deno.test("rooms server removes members that close cleanly", async () => {
	await withServer(async (port) => {
		assertMatch(
			await subscribeOnce(port, "general", "first"),
			/1 in the room: first$/,
		);

		await waitForMatch(
			() => subscribeOnce(port, "general", "second"),
			/1 in the room: second$/,
		);
	});
});

Deno.test("rooms server removes every membership for a closed connection", async () => {
	await withServer(async (port) => {
		await subscribeTwiceAndClose(port, "general");

		await waitForMatch(
			() => subscribeOnce(port, "general", "second"),
			/1 in the room: second$/,
		);
	});
});

Deno.test("rooms server resubscribe replaces one connection's claimed nickname", async () => {
	await withServer(async (port) => {
		const holder = await resubscribeAndHold(port, "general");

		const oldName = await trySubscribe(port, "general", "first-a");
		assert(oldName.ok, "old name should be released by resubscribe");
		const currentName = await trySubscribe(port, "general", "first-b");
		assert(
			!currentName.ok,
			"new name should remain claimed while holder lives",
		);
		assert(currentName.code === NICK_TAKEN, "held nick should be rejected as nick-taken");

		await oldName.leave();
		await holder.leave();
	});
});

Deno.test("rooms server announces members leaving", async () => {
	await withServer(async (port) => {
		const watcher = await watchRoom(port, "general", "watcher");
		const leaver = await watchRoom(port, "general", "leaver");
		await waitForLine(watcher.lines, /^room: leaver joined \(2 here\)$/);

		await leaver.leave();

		await waitForLine(watcher.lines, /^room: leaver left \(1 here\)$/);
		await watcher.leave();
	});
});

/** The directory's live room list as `[name, count]` pairs (counts arrive as
 * bigint), over an already-serving connection. */
async function listRooms(session: Session): Promise<Array<[string, number]>> {
	const directory = await session.fetch(DIRECTORY);
	const raw = await session.send(directory, LIST, []) as unknown[];
	return raw.map((pair) => {
		const p = pair as unknown[];
		return [String(p[0]), Number(p[1])];
	});
}

/** Register a directory watcher over `session` and collect its `notify(event, name,
 * count)` deltas as `"event name count"` strings, returning the baseline
 * snapshot too. */
async function watchDirectory(session: Session): Promise<{
	events: string[];
	snapshot: Array<[string, number]>;
}> {
	session.serve().catch(() => {});
	const directory = await session.fetch(DIRECTORY);
	const events: string[] = [];
	const observer = session.spawn((_verb, args) => {
		events.push(`${args[0]} ${args[1]} ${Number(args[2])}`);
		return null;
	});
	const raw = await session.send(directory, WATCH, [observer]) as unknown[];
	return {
		events,
		snapshot: raw.map((pair) => {
			const p = pair as unknown[];
			return [String(p[0]), Number(p[1])];
		}),
	};
}

Deno.test("rooms directory lists the live rooms with member counts", async () => {
	await withServer(async (port) => {
		const alpha = await watchRoom(port, "alpha", "a1");
		const beta = await watchRoom(port, "beta", "b1");
		const beta2 = await watchRoom(port, "beta", "b2");
		await waitForLine(beta.lines, /^room: b2 joined \(2 here\)$/);

		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		try {
			const rooms = new Map(await listRooms(session));
			assert(
				rooms.get("alpha") === 1,
				`alpha should have 1 member, got ${rooms.get("alpha")}`,
			);
			assert(
				rooms.get("beta") === 2,
				`beta should have 2 members, got ${rooms.get("beta")}`,
			);

			// A room opened but not yet subscribed has no members, so it stays out of
			// the live list until someone is actually in it.
			const directory = await session.fetch(DIRECTORY);
			await session.send(directory, OPEN, ["ghost"]);
			const afterOpen = new Map(await listRooms(session));
			assert(
				!afterOpen.has("ghost"),
				"an empty just-opened room must not be listed",
			);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}

		await alpha.leave();
		await beta.leave();
		await beta2.leave();
	});
});

Deno.test("rooms directory pushes open/count/close deltas to a watcher", async () => {
	await withServer(async (port) => {
		const watcherConn = await connect(tcpLocator("127.0.0.1", port));
		const watch = await watchDirectory(watcherConn);

		const m1 = await watchRoom(port, "wroom", "m1");
		await waitForLine(watch.events, /^opened wroom 1$/);
		const m2 = await watchRoom(port, "wroom", "m2");
		await waitForLine(watch.events, /^count wroom 2$/);

		await m2.leave();
		await waitForLine(watch.events, /^count wroom 1$/);
		await m1.leave();
		await waitForLine(watch.events, /^closed wroom 0$/);

		watcherConn.close();
		await watcherConn.serve().catch(() => {});
	});
});

Deno.test("a room leave drops just that membership, keeping the connection", async () => {
	await withServer(async (port) => {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		try {
			const one = await enterOrOpen(session, "one");
			const two = await enterOrOpen(session, "two");
			const inbox = session.spawn(() => null);
			await session.send(one, SUBSCRIBE, ["solo", inbox]);
			await session.send(two, SUBSCRIBE, ["solo", inbox]);

			// Leaving "one" (its only member) closes it; "two" survives on the same
			// still-open session.
			await session.send(one, LEAVE, []);
			const rooms = new Map(await listRooms(session));
			assert(!rooms.has("one"), "left room should be gone");
			assert(
				rooms.get("two") === 1,
				"the other room should remain on this session",
			);

			// The connection is still usable: we can post in the room we kept.
			await session.send(two, POST, ["still here"]);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

Deno.test("racket one-shot client exits by its deadline while unrelated traffic continues", async () => {
	if (!(await onPath("racket"))) return;

	await withServer(async (port) => {
		const proc = new Deno.Command("racket", {
			args: [
				"-y",
				RACKET_CLIENT,
				loopbackTcpDesignator(port),
				"general",
				"rkt-alan",
				"hello from racket",
				"rkt-alan,missing",
				"250",
			],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		}).spawn();

		let keepNoising = true;
		const noise = (async () => {
			for (let i = 0; keepNoising; i += 1) {
				await subscribeOnce(port, "general", `noise-${i}`).catch(() => {});
				await delay(40);
			}
		})();

		const timedOut = { kind: "timed out" } as const;
		const result = await Promise.race([
			proc.output(),
			delay(2_000).then(() => timedOut),
		]);
		keepNoising = false;
		await noise;
		if ("kind" in result) {
			try {
				proc.kill("SIGTERM");
			} catch {
				// Already gone.
			}
			await proc.status;
			throw new Error(
				"racket client did not exit when the roster could not complete",
			);
		}

		const stderr = new TextDecoder().decode(result.stderr);
		assert(
			!result.success,
			"racket client should fail for an impossible roster",
		);
		assertMatch(stderr, /roster did not complete/);
		assertMatch(stderr, /missing: missing/);
		assert(
			!stderr.includes("missing: rkt-alan"),
			"local member should not be reported missing",
		);
	});
});

// The same room semantics over iroh's encrypted QUIC instead of TCP. These dial
// the server's announced ocapn:// URI through the iroh ABI companion library, so they
// skip cleanly when that optional library is not built (no cargo). The room's
// wire and behavior are identical, only the transport differs.

Deno.test("rooms directory survives a failed register when dm is unpublished", async () => {
	// Register fetch("dm") fails when the member did not publish; CapTP must stay up.
	await withServer(async (port) => {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const inbox = session.spawn(() => null);
		await session.send(directory, REGISTER, [
			"ghost",
			"127.0.0.1:1",
			inbox,
		]);
		await delay(1_500);
		const listed = await session.send(directory, LIST, []);
		assert(Array.isArray(listed), "directory list should still answer after a failed register");
		session.close();
		await session.serve().catch(() => {});
	});
});

Deno.test("rooms directory registers a member that publishes dm on the registrar session", async () => {
	await withServer(async (port) => {
		const exporter = await connect(tcpLocator("127.0.0.1", port));
		exporter.serve().catch(() => {});
		exporter.publish("dm", () => null);
		const exporterDir = await exporter.fetch(DIRECTORY);
		let registered = false;
		const regInbox = exporter.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") registered = true;
			return null;
		});
		await exporter.send(exporterDir, REGISTER, [
			"bot",
			loopbackTcpDesignator(port),
			regInbox,
		]);
		const deadline = Date.now() + 3_000;
		while (!registered && Date.now() < deadline) await delay(25);
		assert(registered, "member should receive notify(registered)");

		exporter.close();
		await exporter.serve().catch(() => {});
	});
});

Deno.test("rooms directory replace-on-re-register notifies the new registrar", async () => {
	await withServer(async (port) => {
		const designator = loopbackTcpDesignator(port);

		const first = await connect(tcpLocator("127.0.0.1", port));
		first.serve().catch(() => {});
		first.publish("dm", () => "first");
		const firstDir = await first.fetch(DIRECTORY);
		let firstAck = false;
		const firstInbox = first.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") firstAck = true;
			return null;
		});
		await first.send(firstDir, REGISTER, ["bot", designator, firstInbox]);
		const firstDeadline = Date.now() + 3_000;
		while (!firstAck && Date.now() < firstDeadline) await delay(25);
		assert(firstAck, "first registrar should receive notify(registered)");

		const second = await connect(tcpLocator("127.0.0.1", port));
		second.serve().catch(() => {});
		second.publish("dm", () => "second");
		const secondDir = await second.fetch(DIRECTORY);
		let secondAck = false;
		const secondInbox = second.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") secondAck = true;
			return null;
		});
		await second.send(secondDir, REGISTER, ["bot", designator, secondInbox]);
		const secondDeadline = Date.now() + 3_000;
		while (!secondAck && Date.now() < secondDeadline) await delay(25);
		assert(secondAck, "second registrar should receive notify(registered) after replace");

		first.close();
		second.close();
		await Promise.all([
			first.serve().catch(() => {}),
			second.serve().catch(() => {}),
		]);
	});
});

Deno.test("rooms server over iroh welcomes a subscriber by its ocapn:// URI", async () => {
	if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
	await withIrohServer(async (uri) => {
		assertMatch(uri, /^ocapn:\/\/[0-9a-f]+\.iroh/);
		assertMatch(
			await subscribeOnceIroh(uri, "general", "iroh-first"),
			/1 in the room: iroh-first$/,
		);
		// A name freed by a clean close is grantable again to the next dialer.
		await waitForMatch(
			() => subscribeOnceIroh(uri, "general", "iroh-second"),
			/1 in the room: iroh-second$/,
		);
	});
});

Deno.test("rooms server over iroh broadcasts joins and leaves through the capability callback", async () => {
	if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
	await withIrohServer(async (uri) => {
		const watcher = await watchRoomIroh(uri, "general", "iroh-watcher");
		const leaver = await watchRoomIroh(uri, "general", "iroh-leaver");
		await waitForLine(watcher.lines, /^room: iroh-leaver joined \(2 here\)$/);

		await leaver.leave();

		await waitForLine(watcher.lines, /^room: iroh-leaver left \(1 here\)$/);
		await watcher.leave();
	});
});
