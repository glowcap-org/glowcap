import { Ref, type Session } from "@pancake/stack";
import {
	DIRECTORY,
	ENTER,
	INTRODUCE,
	LEAVE,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OPEN,
	POST,
	REGISTER,
	SUBSCRIBE,
	WATCH,
} from "../lib/protocol.ts";
import {
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	PEER_OFFLINE,
	ROOM_EXISTS,
	RoomError,
	type RoomErrorCode,
	roomErrorOf,
} from "../lib/errors.ts";
import { MAX_NICK } from "../lib/limits.ts";
import { inboxOfferer } from "../lib/dm_inbox.ts";
import { Directory } from "../lib/room_client.ts";
import { dial, loopbackTcpDesignator, roomsHost } from "../lib/locator.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const SERVER = new URL("../server/main.ts", import.meta.url).pathname;
const RACKET_CLIENT = new URL("../clients/racket/client.rkt", import.meta.url).pathname;
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
		await dial(loopbackTcpDesignator(port)),
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
	const session = await dial(loopbackTcpDesignator(port));
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
	const session = await dial(loopbackTcpDesignator(port));
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
	const session = await dial(loopbackTcpDesignator(port));
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
		await dial(loopbackTcpDesignator(port)),
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
		const session = await dial(loopbackTcpDesignator(port));
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
		const session = await dial(loopbackTcpDesignator(port));
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

Deno.test("rooms server will not grant a name a connected member still answers to", async () => {
	// A name outlives a room membership: leaving a room does not give up the
	// registration a member is reached by, because a direct line is not the
	// room's. So the room must not hand that name to the next person while the
	// first is still connected — the roster would show one of them and an
	// introduction under the name would reach the other.
	await withServer(async (port) => {
		const holder = await dial(loopbackTcpDesignator(port));
		holder.serve().catch(() => {});
		try {
			const holderDir = await holder.fetch(DIRECTORY);
			const room = await enterOrOpen(holder, "lobby");
			await holder.send(room, SUBSCRIBE, ["ada", holder.spawn(() => null)]);
			await registerAndWatch(holder, holderDir, "ada", loopbackTcpDesignator(port));

			// Ada leaves the room. Her membership is gone; her registration is not,
			// because a direct line does not belong to the room that introduced it.
			await holder.send(room, LEAVE, []);

			const impostor = await trySubscribe(port, "lobby", "ada");
			assert(
				!impostor.ok,
				"the room granted a name a still-connected member answers to for direct " +
					"messages; an introduction from the roster would reach the wrong person",
			);
			assert(impostor.code === NICK_TAKEN, "the refusal should read as nick-taken");

			// Only the held name is refused; the rule costs nobody else the room.
			const other = await trySubscribe(port, "lobby", "grace");
			assert(other.ok, "an unheld name should still be granted");
			await other.leave();
		} finally {
			holder.close();
			await holder.serve().catch(() => {});
		}
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

		const session = await dial(loopbackTcpDesignator(port));
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
		const watcherConn = await dial(loopbackTcpDesignator(port));
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
		const session = await dial(loopbackTcpDesignator(port));
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

Deno.test("rooms directory registers a member and acknowledges the name", async () => {
	await withServer(async (port) => {
		const exporter = await dial(loopbackTcpDesignator(port));
		exporter.serve().catch(() => {});
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

Deno.test("rooms directory introduces only to the inbox a member minted for the caller", async () => {
	// The directory's own rules. That the offered inbox then carries a real direct
	// message is the `demo-rooms-dm` gate's job; here nothing dials, so the test
	// stays fast and needs no second listener.
	await withServer(async (port) => {
		const bobHost = roomsHost();
		const bob = await dial(loopbackTcpDesignator(port), bobHost);
		bob.serve().catch(() => {});
		const bobDir = await bob.fetch(DIRECTORY);
		let bobAck = false;
		let askedFor: string | null = null;
		const bobReg = bob.spawn((verb, args) => {
			if (verb !== NOTIFY) return null;
			if (args[0] === "registered") bobAck = true;
			if (args[0] === "mintInboxFor" && typeof args[1] === "string") askedFor = args[1];
			return null;
		});
		await bob.send(bobDir, REGISTER, ["bob", loopbackTcpDesignator(port), bobReg]);
		const bobDeadline = Date.now() + 3_000;
		while (!bobAck && Date.now() < bobDeadline) await delay(25);
		assert(bobAck, "bob should be registered");

		const carol = await dial(loopbackTcpDesignator(port));
		carol.serve().catch(() => {});
		const carolDir = await carol.fetch(DIRECTORY);
		let carolAck = false;
		let introducible = false;
		const carolReg = carol.spawn((verb, args) => {
			if (verb !== NOTIFY) return null;
			if (args[0] === "registered") carolAck = true;
			if (args[0] === "introducible" && args[1] === "bob") introducible = true;
			return null;
		});
		await carol.send(carolDir, REGISTER, ["carol", "127.0.0.1:1", carolReg]);
		const carolDeadline = Date.now() + 3_000;
		while (!carolAck && Date.now() < carolDeadline) await delay(25);
		assert(carolAck, "carol should be registered");

		// Bob has offered nothing, so this is refused and Bob is asked for an inbox
		// for Carol, by the name the directory reads off her connection.
		let refused: string | null = null;
		try {
			await carol.send(carolDir, INTRODUCE, ["bob"]);
		} catch (err) {
			refused = err instanceof Error ? err.message : String(err);
		}
		assert(refused !== null, "a first introduce should be refused");
		assert(
			RoomError.from(refused)?.code === INTRODUCTION_PENDING,
			`expected introduction-pending, got ${refused}`,
		);
		const askDeadline = Date.now() + 3_000;
		while (askedFor === null && Date.now() < askDeadline) await delay(25);
		assert(askedFor === "carol", `expected bob to be asked for carol, got ${askedFor}`);

		// Bob offers one; Carol is told she may ask again.
		bobHost.publishGiftable("inbox-for-carol", () => null);
		const offered = bob.publishedRef("inbox-for-carol");
		assert(offered !== null, "the giftable should hold a position on bob's room session");
		await bob.send(bobDir, OFFER_INBOX, ["carol", offered]);
		const okDeadline = Date.now() + 3_000;
		while (!introducible && Date.now() < okDeadline) await delay(25);
		assert(introducible, "carol should hear that bob is introducible");

		// An unregistered caller has no name an inbox could have been minted for.
		const stranger = await dial(loopbackTcpDesignator(port));
		stranger.serve().catch(() => {});
		const strangerDir = await stranger.fetch(DIRECTORY);
		let strangerRefused = false;
		try {
			await stranger.send(strangerDir, INTRODUCE, ["bob"]);
		} catch {
			strangerRefused = true;
		}
		assert(strangerRefused, "an unregistered caller should not be introduced");

		stranger.close();
		carol.close();
		bob.close();
		await Promise.allSettled([
			stranger.serve().catch(() => {}),
			carol.serve().catch(() => {}),
			bob.serve().catch(() => {}),
		]);
	});
});

/** Register `nick` and wait for the directory's ack, returning the reg-inbox
 * observations a DM test cares about: who the directory asked us to mint for, and
 * which peers it said were introducible. */
async function registerAndWatch(
	session: Session,
	directory: Ref,
	nick: string,
	locator: string,
): Promise<{ askedFor: string[]; introducible: string[] }> {
	const askedFor: string[] = [];
	const introducible: string[] = [];
	let acked = false;
	const inbox = session.spawn((verb, args) => {
		if (verb !== NOTIFY) return null;
		const peer = typeof args[1] === "string" ? args[1] : "";
		if (args[0] === "registered") acked = true;
		if (args[0] === "mintInboxFor" && peer) askedFor.push(peer);
		if (args[0] === "introducible" && peer) introducible.push(peer);
		return null;
	});
	await session.send(directory, REGISTER, [nick, locator, inbox]);
	const deadline = Date.now() + 3_000;
	while (!acked && Date.now() < deadline) await delay(25);
	assert(acked, `${nick} should be registered`);
	return { askedFor, introducible };
}

/** The room code a verb refused with, or null when it did not refuse. */
async function refusalCode(send: () => Promise<unknown>): Promise<string | null> {
	try {
		await send();
		return null;
	} catch (err) {
		return roomErrorOf(err)?.code ?? "untyped";
	}
}

Deno.test("rooms directory refuses a register whose nick is too long", async () => {
	// The one place this can be held. A registered nick becomes the key every
	// member files an inbox under and the seed of a bootstrap name they keep for
	// good, so an unbounded name here is an unbounded allocation the caller spends
	// in every member it is introduced to. Clients cap their own input; only the
	// directory caps everyone's.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const inbox = session.spawn(() => null);
		const code = await refusalCode(() =>
			session.send(directory, REGISTER, [
				"x".repeat(MAX_NICK + 1),
				loopbackTcpDesignator(port),
				inbox,
			])
		);
		assert(code === NICK_TOO_LONG, `expected nick-too-long, got ${code}`);

		// The directory is still serving, and a name at the limit is fine.
		const ok = await refusalCode(() =>
			session.send(directory, REGISTER, [
				"x".repeat(MAX_NICK),
				loopbackTcpDesignator(port),
				inbox,
			])
		);
		assert(ok === null, `a name at the limit should register, got ${ok}`);

		session.close();
		await session.serve().catch(() => {});
	});
});

Deno.test("rooms directory does not hand a nickname's next holder the last one's inbox", async () => {
	// A registered name outlives its holders, and the inboxes other members
	// offered for it are filed under the name, not the person. Leaving them behind
	// would introduce whoever claims the name next to a capability minted for
	// somebody else, and the caller's interface would paint their messages as that
	// person's with nothing left to doubt.
	await withServer(async (port) => {
		const carolHost = roomsHost();
		const carol = await dial(loopbackTcpDesignator(port), carolHost);
		carol.serve().catch(() => {});
		const carolDir = await carol.fetch(DIRECTORY);
		const carolSaw = await registerAndWatch(carol, carolDir, "carol", "127.0.0.1:1");

		const bob = await dial(loopbackTcpDesignator(port));
		bob.serve().catch(() => {});
		const bobDir = await bob.fetch(DIRECTORY);
		const bobSaw = await registerAndWatch(bob, bobDir, "bob", loopbackTcpDesignator(port));

		// Carol offers Bob an inbox, and Bob hears that she is introducible.
		carolHost.publishGiftable("carol-inbox-for-bob", () => null);
		const offered = carol.publishedRef("carol-inbox-for-bob");
		assert(offered !== null, "the giftable should hold a position on carol's session");
		await carol.send(carolDir, OFFER_INBOX, ["bob", offered]);
		const okDeadline = Date.now() + 3_000;
		while (bobSaw.introducible.length === 0 && Date.now() < okDeadline) await delay(25);
		assert(bobSaw.introducible.includes("carol"), "bob should hear carol is introducible");
		assert(carolSaw.askedFor.length === 0, "carol was not asked for that inbox");

		// Bob goes, and Mallory claims the name he gave up.
		bob.close();
		await bob.serve().catch(() => {});
		const goneDeadline = Date.now() + 3_000;
		let free: string | null = "held";
		const mallory = await dial(loopbackTcpDesignator(port));
		mallory.serve().catch(() => {});
		const malloryDir = await mallory.fetch(DIRECTORY);
		const malloryInbox = mallory.spawn(() => null);
		while (free !== null && Date.now() < goneDeadline) {
			free = await refusalCode(() =>
				mallory.send(malloryDir, REGISTER, ["bob", "127.0.0.1:2", malloryInbox])
			);
			if (free !== null) await delay(25);
		}
		assert(free === null, `mallory should get the freed name, refused ${free}`);

		// The inbox Carol minted for the real Bob is not Mallory's to be handed.
		const code = await refusalCode(() => mallory.send(malloryDir, INTRODUCE, ["carol"]));
		assert(code === INTRODUCTION_PENDING, `expected introduction-pending, got ${code}`);
		const askDeadline = Date.now() + 3_000;
		while (carolSaw.askedFor.length === 0 && Date.now() < askDeadline) await delay(25);
		assert(
			carolSaw.askedFor.includes("bob"),
			"carol should be asked to mint a fresh inbox for the new bob",
		);

		mallory.close();
		carol.close();
		await Promise.allSettled([
			mallory.serve().catch(() => {}),
			carol.serve().catch(() => {}),
		]);
	});
});

Deno.test("a member re-offers its inboxes after a second registration, minting none", async () => {
	// A re-register is a fresh start on the name, so the directory drops what the
	// previous registration collected and asks again. Both halves have to hold: the
	// offerer must answer that ask, or the member is permanently un-DM-able, and it
	// must answer with the inbox it already published, because nothing withdraws a
	// giftable and a second one would answer forever under a name nobody can take
	// back.
	await withServer(async (port) => {
		const asker = await dial(loopbackTcpDesignator(port));
		asker.serve().catch(() => {});
		const askerDir = await asker.fetch(DIRECTORY);
		const askerSaw = await registerAndWatch(asker, askerDir, "carol", "127.0.0.1:1");

		const memberHost = roomsHost();
		let dir: Directory | null = null;
		dir = await Directory.connect(
			loopbackTcpDesignator(port),
			(l) => dial(l, memberHost),
		);
		let mints = 0;
		const offerer = inboxOfferer({
			host: memberHost,
			dir: () => dir,
			behaviorFor: () => {
				mints += 1;
				return () => null;
			},
		});
		const locator = loopbackTcpDesignator(port);
		await dir.register("member", locator, offerer.offer);
		offerer.offer("carol");
		const first = Date.now() + 3_000;
		while (askerSaw.introducible.length < 1 && Date.now() < first) await delay(25);
		assert(askerSaw.introducible.includes("member"), "the first offer should land");
		assert(mints === 1, `expected one mint, saw ${mints}`);

		// Register again on the live session, the shipped path for a nick change.
		await dir.register("member", locator, offerer.offer);
		const code = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["member"]));
		assert(
			code === INTRODUCTION_PENDING,
			`the re-register should clear the offer, got ${code}`,
		);

		// That refusal asked the member again; the offerer answers with the same
		// published inbox.
		const second = Date.now() + 3_000;
		while (askerSaw.introducible.length < 2 && Date.now() < second) await delay(25);
		assert(askerSaw.introducible.length >= 2, "the member should offer again when asked");
		assert(mints === 1, `a re-offer must not mint a second inbox, saw ${mints}`);

		asker.close();
		await dir.close();
		await asker.serve().catch(() => {});
		memberHost.release();
	});
});

Deno.test("rooms directory keeps one registered nick per connection", async () => {
	// `registeredNickOf` reads a caller's own name off the registry, so a
	// connection holding two rows makes "you" a matter of which one is found
	// first. A nick change re-registers on the live session, so this is the
	// shipped path, not a hypothetical.
	await withServer(async (port) => {
		const member = await dial(loopbackTcpDesignator(port));
		member.serve().catch(() => {});
		const memberDir = await member.fetch(DIRECTORY);
		await registerAndWatch(member, memberDir, "alice", loopbackTcpDesignator(port));
		await registerAndWatch(member, memberDir, "alicia", loopbackTcpDesignator(port));

		const asker = await dial(loopbackTcpDesignator(port));
		asker.serve().catch(() => {});
		const askerDir = await asker.fetch(DIRECTORY);
		await registerAndWatch(asker, askerDir, "dave", "127.0.0.1:1");

		const stale = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["alice"]));
		assert(stale === PEER_OFFLINE, `the given-up name should be gone, got ${stale}`);
		const live = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["alicia"]));
		assert(live === INTRODUCTION_PENDING, `the held name should answer, got ${live}`);

		asker.close();
		member.close();
		await Promise.allSettled([
			asker.serve().catch(() => {}),
			member.serve().catch(() => {}),
		]);
	});
});

Deno.test("rooms directory refuses a nick another live connection holds", async () => {
	await withServer(async (port) => {
		const designator = loopbackTcpDesignator(port);

		const first = await dial(loopbackTcpDesignator(port));
		first.serve().catch(() => {});
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

		// Another connection asking for the same name is refused while the holder's
		// connection is open. A registration is what `introduce` routes on, so
		// granting this would hand callers the wrong member's capability.
		const second = await dial(loopbackTcpDesignator(port));
		second.serve().catch(() => {});
		const secondDir = await second.fetch(DIRECTORY);
		const secondInbox = second.spawn(() => null);
		let refused: string | null = null;
		try {
			await second.send(secondDir, REGISTER, ["bot", designator, secondInbox]);
		} catch (err) {
			refused = err instanceof Error ? err.message : String(err);
		}
		assert(refused !== null, "a second connection should be refused the held nick");
		assert(
			RoomError.from(refused)?.code === NICK_TAKEN,
			`expected nick-taken, got ${refused}`,
		);

		// A refresh of its own claim must not free the name in the middle of
		// itself. Fire the refresh and a rival's attempt together, so the rival
		// lands while the refresh is still awaiting its fetch: releasing the name
		// first made that window real, and the guard sees no holder inside it.
		const refresh = first.send(firstDir, REGISTER, ["bot", designator, firstInbox]);
		let racedIn: string | null = null;
		try {
			await second.send(secondDir, REGISTER, ["bot", designator, secondInbox]);
			racedIn = "granted";
		} catch {
			racedIn = null;
		}
		await refresh;
		assert(racedIn === null, "a rival must not slip in while the holder refreshes its claim");

		// And the name frees when its holder's connection ends.
		first.close();
		await first.serve().catch(() => {});
		let secondAck = false;
		const ackInbox = second.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") secondAck = true;
			return null;
		});
		const freeDeadline = Date.now() + 5_000;
		while (!secondAck && Date.now() < freeDeadline) {
			await second.send(secondDir, REGISTER, ["bot", designator, ackInbox]).catch(() => {});
			await delay(100);
		}
		assert(secondAck, "the nick should free once its holder's connection is gone");

		second.close();
		await second.serve().catch(() => {});
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
