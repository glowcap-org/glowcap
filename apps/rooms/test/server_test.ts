import { currentSession, DURABLE_SWISS_ENTROPY_BYTES, Ref } from "@pancake/runtime";
import type { Argument, Host, Runtime, Session } from "@pancake/runtime";
import { Reachability } from "@pancake/iroh";
import {
	ATTACH,
	DIRECTORY,
	DM,
	ENTER,
	INTRODUCE,
	LEAVE,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OFFER_SIGNALING,
	OPEN,
	POST,
	POST_FILES,
	READ,
	REGISTER,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIG_REJECT,
	SIGNAL_ANSWER,
	SIGNAL_DONE,
	SIGNAL_OFFER,
	SUBSCRIBE,
	WATCH,
	WRITE,
} from "../lib/protocol.ts";
import {
	ATTACHMENT_REFUSED,
	BAD_ATTACHMENT,
	BLOB_EXPIRED,
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	PEER_OFFLINE,
	ROOM_EXISTS,
	ROOM_LINKS_FULL,
	ROOM_TOO_LONG,
	RoomError,
	type RoomErrorCode,
	roomErrorOf,
	UPLOAD_INCOMPLETE,
} from "../lib/errors.ts";
import {
	BLOB_CHUNK,
	MAX_ATTACHMENT_BYTES,
	MAX_AWAY,
	MAX_BLOB_READERS,
	MAX_DIRECT_ATTACHMENTS,
	MAX_MESSAGE_FILES,
	MAX_NICK,
	MAX_ROOM,
	MAX_ROOM_ATTACHMENTS,
	MAX_ROOM_LINKS,
	MAX_SERVER_PENDING_BYTES,
	MAX_SIGNAL_EXCHANGES,
	MAX_TOPIC,
} from "../lib/limits.ts";
import { type Attachment, attachmentArgs, fetchBlob, readAttachments, sendWithAttachments } from "../lib/attachment.ts";
import { Unanswered } from "../lib/deadline.ts";
import { inboxOfferer } from "../lib/dm_inbox.ts";
import { Directory, type Message, Room } from "../lib/room_client.ts";
import {
	dial as dialWithRuntime,
	isUriLocator,
	loopbackTcpDesignator,
	roomsHost,
	roomsListen,
} from "../lib/locator.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { RoomServerState } from "../server/state.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const SERVER = new URL("../server/main.ts", import.meta.url).pathname;
const RACKET_CLIENT = new URL("../clients/racket/client.rkt", import.meta.url).pathname;
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];
// iroh dials through the sidecar over nonblocking FFI, which needs broader
// permissions and --unstable-ffi; the server reads its own lib path.
const IROH_FLAGS = ["run", "-A", "--unstable-ffi"];

class TestRuntimeScope {
	readonly #byHost = new Map<Host, Promise<Runtime>>();
	readonly #runtimes = new Set<Runtime>();

	async dial(locator: string, host = roomsHost()): Promise<Session> {
		let pending = this.#byHost.get(host);
		if (pending === undefined) {
			pending = openRoomsRuntime({
				host,
				iroh: isUriLocator(locator) ? { reachability: Reachability.Direct } : undefined,
			});
			this.#byHost.set(host, pending);
		}
		const runtime = await pending;
		this.#runtimes.add(runtime);
		return await dialWithRuntime(locator, runtime);
	}

	async close(): Promise<void> {
		for (const runtime of [...this.#runtimes].reverse()) await runtime.close();
		this.#runtimes.clear();
		this.#byHost.clear();
	}
}

let activeRuntimeScope: TestRuntimeScope | null = null;

function roomsTest(
	name: string,
	run: (context: Deno.TestContext) => void | Promise<void>,
): void {
	Deno.test(name, async (context) => {
		const scope = new TestRuntimeScope();
		activeRuntimeScope = scope;
		try {
			await run(context);
		} finally {
			activeRuntimeScope = null;
			await scope.close();
		}
	});
}

function dial(locator: string, host?: Host): Promise<Session> {
	if (activeRuntimeScope === null) throw new Error("rooms test dial used outside a test scope");
	return activeRuntimeScope.dial(locator, host);
}

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

/** Wait for one thing with a deadline on it.
 *
 * A stream that never delivers what a test is waiting for is the ordinary shape
 * of a broken feature, and awaiting it plainly turns that into a hang: the run
 * sits there until something outside kills it, and reports nothing about what
 * was missing. This turns the same failure into a sentence. */
async function within<T>(work: Promise<T>, what: string, ms = 10_000): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const expiry = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
	});
	try {
		return await Promise.race([work, expiry]);
	} finally {
		clearTimeout(timer);
	}
}

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

/** A port nothing holds right now. Asked with a socket that does not share an
 * address, which is the same question the server itself asks before binding. */
function freeServerPort(): number {
	const probe = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const { port } = probe.addr as Deno.NetAddr;
	probe.close();
	return port;
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

async function withCapturedServer(fn: (port: number) => Promise<void>): Promise<string> {
	const proc = new Deno.Command("deno", {
		args: [...DENO_FLAGS, SERVER, "0"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	const stderr = new Response(proc.stderr).text();
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
	return await stderr;
}

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

function startStatefulServer(port: number, stateDirectory: string): Deno.ChildProcess {
	return new Deno.Command("deno", {
		args: [...DENO_FLAGS, `--allow-write=${stateDirectory}`, SERVER, String(port)],
		cwd: ROOT,
		env: { ROOMS_STATE: stateDirectory },
		stdout: "piped",
		stderr: "piped",
	}).spawn();
}

async function stopServer(proc: Deno.ChildProcess): Promise<void> {
	try {
		proc.kill("SIGTERM");
	} catch {
		// Already gone.
	}
	await proc.status;
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

/** Accumulate a `Room`'s lines into the same `string[]` shape `watchRoomConn`
 * hands back, so a test holding the client class reads them with the same
 * `waitForLine` vocabulary as one holding a raw inbox.
 *
 * Start it before the line you are waiting for can arrive. The stream queues
 * what it is given, so attaching at subscribe time cannot miss the welcome, but
 * attaching after one is already delivered can. */
function roomLines(room: Room): string[] {
	const lines: string[] = [];
	void (async () => {
		try {
			for await (const message of room.messages) lines.push(`${message.from}: ${message.text}`);
		} catch {
			// The stream ends with the membership, so a read that rejects while the
			// room is being left is the ordinary end of this pump, not a failure.
		}
	})();
	return lines;
}

async function until(
	condition: () => boolean,
	message: string,
	timeoutMs = 3_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!condition()) {
		if (Date.now() >= deadline) throw new Error(message);
		await delay(10);
	}
}

roomsTest("rooms directory opens a room and rejects opening it twice", async () => {
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

roomsTest("rooms directory rejects entering a room that does not exist", async () => {
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

roomsTest("room link state restores its identity and sealed room names", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-state-" });
	try {
		const bytes = (entropy: Uint8Array) => [...entropy].join(",");
		const first = await RoomServerState.open(directory);
		const firstEntropy = bytes(await first.entropyFor("General"));
		await first.remember("General");

		const restored = await RoomServerState.open(directory);
		assert(
			[...restored.identitySeed].join(",") === [...first.identitySeed].join(","),
			"the room Host identity changed across state restore",
		);
		assert(
			bytes(await restored.entropyFor("general")) === firstEntropy,
			"the same case-insensitive room did not restore the same swiss authority",
		);
		assert(
			bytes(await restored.entropyFor("elsewhere")) !== firstEntropy,
			"one room link granted a different room",
		);
		assert(
			(await restored.entropyFor("General")).length === DURABLE_SWISS_ENTROPY_BYTES,
			"a room's derived entropy is not the width the Host mints from",
		);
		assert(
			restored.linkedRooms().join(",") === "General",
			"the explicitly linked room was not restored",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("room link state refuses an unbounded durable name registry", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-link-limit-" });
	try {
		await RoomServerState.open(directory);
		const path = `${directory}/rooms.json`;
		const disk = JSON.parse(await Deno.readTextFile(path));
		disk.linkedRooms = Array.from({ length: MAX_ROOM_LINKS }, (_, index) => `r${index}`);
		await Deno.writeTextFile(path, JSON.stringify(disk) + "\n");

		const full = await RoomServerState.open(directory);
		let code: string | null = null;
		try {
			await full.remember("one-more");
		} catch (err) {
			code = err instanceof RoomError ? err.code : null;
		}
		assert(code === ROOM_LINKS_FULL, `expected room-links-full, got ${code}`);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("a room sturdyref reaches the same room publication after server restart", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-links-" });
	const port = freePort();
	const locator = loopbackTcpDesignator(port);
	let link = "";
	let first = startStatefulServer(port, stateDirectory);
	try {
		await readPort(first);
		const dir = await Directory.connect(locator, (address) => dial(address));
		const room = await Room.subscribe(dir.session, await dir.open("kept"), "before");
		link = await dir.link("kept", locator);
		await room.leave();
		await dir.close();
		await stopServer(first);

		first = startStatefulServer(port, stateDirectory);
		await readPort(first);
		const after = await Directory.connect(locator, (address) => dial(address));
		// Redeem the link itself rather than picking it apart. A holder of a room
		// link has the string and nothing else, so enlivening it is the act under
		// test; reading the swiss out and fetching it by name would prove the
		// server published something, not that the link reaches it.
		const roomAfter = await Room.subscribe(after.session, await after.session.enliven(link), "after");
		assert(
			await after.link("kept", locator) === link,
			"the server returned a different sturdyref after restoring its state",
		);
		await roomAfter.say("the link still reaches the room");
		await roomAfter.leave();
		await after.close();
	} finally {
		await stopServer(first);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("an uploaded file reaches every member, who read its bytes from the room", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "media"), "poster");

		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "media"), "reader");

		// A subscriber that reads only (from, text) is what a client predating
		// attachments is: the record is additive, so it must still see a line.
		const legacy = await watchRoom(port, "media", "legacy");

		// Larger than one chunk and not a multiple of it, so the upload and the
		// read both cross a boundary and end on a partial chunk.
		const bytes = Uint8Array.from({ length: BLOB_CHUNK * 2 + 17 }, (_, i) => i % 251);
		const sent: number[] = [];
		await senderRoom.attach(
			{ name: "pattern.bin", mime: "application/octet-stream", bytes },
			"",
			(n) => sent.push(n),
		);
		assert(sent.length === 3, `expected three chunk writes, saw ${sent.length}`);
		assert(sent[sent.length - 1] === bytes.length, "progress should end at the file size");

		let got: Message | null = null;
		for await (const message of receiverRoom.messages) {
			if (message.attachments.length > 0) {
				got = message;
				break;
			}
		}
		assert(got !== null, "the receiver should hear the file line");
		assert(got.from === "poster", `file line from ${got.from}`);
		assert(got.text === "pattern.bin", "an empty caption falls back to the file name");
		const attachment = got.attachments[0];
		assert(attachment.name === "pattern.bin", `record name ${attachment.name}`);
		assert(attachment.mime === "application/octet-stream", `record mime ${attachment.mime}`);
		assert(attachment.size === bytes.length, `record size ${attachment.size}`);

		const fetched = await receiverRoom.fetch(attachment);
		assert(fetched.length === bytes.length, `fetched ${fetched.length} of ${bytes.length}`);
		for (let i = 0; i < bytes.length; i += 1) {
			if (fetched[i] !== bytes[i]) throw new Error(`fetched bytes differ at ${i}`);
		}

		// The room hosts the bytes, so the file outlives the poster's connection.
		sender.close();
		await sender.serve().catch(() => {});
		const afterSenderLeft = await receiverRoom.fetch(attachment);
		assert(afterSenderLeft.length === bytes.length, "a posted file survives its poster leaving");

		await waitForLine(legacy.lines, /^poster: pattern\.bin$/);

		await legacy.leave();
		await receiverRoom.leave();
		receiver.close();
	});
});

roomsTest("a picture's declared shape rides the record to every member", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "shapes"), "poster");
		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "shapes"), "reader");

		await senderRoom.attach({
			name: "wide.png",
			mime: "image/png",
			bytes: new Uint8Array([1, 2, 3, 4]),
			width: 800,
			height: 450,
		});

		// A file with no shape to declare says so as zero, not as nonsense.
		await senderRoom.attach({ name: "notes.txt", mime: "text/plain", bytes: new Uint8Array([9]) });

		// One reader over the stream: breaking out of a `for await` cancels it,
		// so a second loop would find nothing.
		const byName = new Map<string, Attachment>();
		for await (const message of receiverRoom.messages) {
			for (const attachment of message.attachments) byName.set(attachment.name, attachment);
			if (byName.size === 2) break;
		}
		const wide = byName.get("wide.png");
		const plain = byName.get("notes.txt");
		assert(wide !== undefined && plain !== undefined, "both file lines should arrive");
		// The reader reserves this shape before the bytes arrive, which is what
		// keeps a log of pictures from shoving itself down the page as they load.
		assert(wide.width === 800, `declared width arrived as ${wide.width}`);
		assert(wide.height === 450, `declared height arrived as ${wide.height}`);
		assert(plain.width === 0 && plain.height === 0, "an unmeasured file declares no shape");

		await receiverRoom.leave();
		receiver.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("staged files publish together, in order, or not at all", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "album"), "poster");
		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "album"), "reader");

		const firstSource = { name: "first.txt", mime: "text/plain", bytes: new Uint8Array([1]) };
		const secondSource = { name: "second.txt", mime: "text/plain", bytes: new Uint8Array([2]) };
		const first = await senderRoom.stage(firstSource);
		const second = await senderRoom.stage(secondSource);
		// Publication is atomic and preserves composer order, before either file
		// has moved. Each blob read then waits on its own upload capability.
		await senderRoom.postFiles("two files");
		for await (const message of receiverRoom.messages) {
			if (message.attachments.length === 0) continue;
			assert(message.text === "two files", `caption was ${message.text}`);
			assert(message.attachments.length === 2, `expected two files, got ${message.attachments.length}`);
			assert(message.attachments[0].name === "first.txt", "first staged file moved");
			assert(message.attachments[1].name === "second.txt", "second staged file moved");
			const reads = message.attachments.map((attachment) => receiverRoom.fetch(attachment));
			await Promise.all([
				senderRoom.upload(first, firstSource),
				senderRoom.upload(second, secondSource),
			]);
			const [firstBytes, secondBytes] = await Promise.all(reads);
			assert(firstBytes[0] === 1 && secondBytes[0] === 2, "independent uploads reached their blobs");
			break;
		}

		await receiverRoom.leave();
		receiver.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("files ride a direct message in both directions over its existing transport", async () => {
	const encoder = new TextEncoder();
	const sent = new Uint8Array(BLOB_CHUNK + 17);
	for (let i = 0; i < sent.length; i += 1) sent[i] = i & 0xff;
	const replied = encoder.encode("the reply is a file too");

	let resolveReceived!: (bytes: Uint8Array) => void;
	let rejectReceived!: (reason?: unknown) => void;
	const received = new Promise<Uint8Array>((resolve, reject) => {
		resolveReceived = resolve;
		rejectReceived = reject;
	});
	let resolveReply!: (bytes: Uint8Array) => void;
	let rejectReply!: (reason?: unknown) => void;
	const replyReceived = new Promise<Uint8Array>((resolve, reject) => {
		resolveReply = resolve;
		rejectReply = reject;
	});
	const held: Attachment[] = [];

	const receiverHost = roomsHost();
	let arriving: Session | null = null;
	receiverHost.publishGiftable("dm-files", (verb, args) => {
		if (verb === "hold-file") {
			held.push(...readAttachments(args, 1));
			return null;
		}
		if (verb !== DM) throw new Error(`dm-files has no method ${verb}`);
		const session = currentSession() ?? arriving;
		const reply = args[1];
		const files = readAttachments(args, reply instanceof Ref ? 2 : 1);
		if (session === null || !(reply instanceof Ref) || files.length !== 1) {
			throw new Error(
				`direct file message needs its arriving session, reply, and one file ` +
					`(session=${session !== null}, reply=${reply instanceof Ref}, token=${
						String(args[2])
					}, files=${files.length})`,
			);
		}
		queueMicrotask(() => {
			fetchBlob(session, files[0]).then(resolveReceived, rejectReceived);
			sendWithAttachments(session, reply, DM, ["file reply"], [{
				name: "reply.txt",
				mime: "text/plain",
				bytes: replied,
			}]).catch(rejectReply);
		});
		return null;
	});

	const listener = await roomsListen("127.0.0.1", 0, receiverHost);
	const serving = (async () => {
		for await (const session of listener) {
			arriving = session;
			await session.serve().catch(() => {});
			break;
		}
	})();
	const sender = await dial(loopbackTcpDesignator(listener.port));
	sender.serve().catch(() => {});
	try {
		const target = await sender.fetch("dm-files");
		const reply = sender.spawn((verb, args) => {
			if (verb !== DM) throw new Error(`reply has no method ${verb}`);
			const files = readAttachments(args, 1);
			if (files.length !== 1) throw new Error("reply carried no file");
			queueMicrotask(() => fetchBlob(sender, files[0]).then(resolveReply, rejectReply));
			return null;
		});
		const oneRecord = attachmentArgs({
			name: "bounded.txt",
			mime: "text/plain",
			size: 1,
			blob: reply,
			width: 0,
			height: 0,
		});
		let refusedTooMany = false;
		try {
			readAttachments(["message", ...Array.from({ length: MAX_MESSAGE_FILES + 1 }, () => oneRecord).flat()], 1);
		} catch {
			refusedTooMany = true;
		}
		assert(refusedTooMany, "a direct peer must not make the receiver retain an unbounded file-record suffix");
		await sendWithAttachments(sender, target, DM, ["file request", reply], [{
			name: "pattern.bin",
			mime: "application/octet-stream",
			bytes: sent,
		}]);

		const [atReceiver, atSender] = await Promise.all([received, replyReceived]);
		assert(
			atReceiver.length === sent.length && atReceiver.every((byte, i) => byte === sent[i]),
			"the direct receiver should fetch every chunk from the sender-hosted blob",
		);
		assert(
			atSender.length === replied.length && atSender.every((byte, i) => byte === replied[i]),
			"the direct reply should carry its own sender-hosted blob on the same connection",
		);

		// A direct sender is the file store, so its process-wide held-source
		// ceiling is as load-bearing as the room server's. Leave one more than the
		// count budget unfetched: the oldest capability must break and the newest
		// must still answer.
		for (let i = 0; i <= MAX_DIRECT_ATTACHMENTS; i += 1) {
			await sendWithAttachments(sender, target, "hold-file", ["held"], [{
				name: `held-${i}.bin`,
				mime: "application/octet-stream",
				bytes: new Uint8Array([i & 0xff]),
			}]);
		}
		assert(held.length === MAX_DIRECT_ATTACHMENTS + 1, "the receiver should hold every file reference");
		let oldestExpired = false;
		try {
			await fetchBlob(arriving!, held[0]);
		} catch {
			oldestExpired = true;
		}
		assert(oldestExpired, "the direct sender should evict its oldest unfetched source at the ceiling");
		const newest = await fetchBlob(arriving!, held[held.length - 1]);
		assert(newest[0] === (MAX_DIRECT_ATTACHMENTS & 0xff), "the newest direct source should remain readable");
	} finally {
		sender.close();
		await sender.serve().catch(() => {});
		listener.close();
		await serving;
	}
});

roomsTest("a room refuses a post's own trailing args, an oversize file, and a short upload", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const roomRef = await enterOrOpen(session, "strict");
			await session.send(roomRef, SUBSCRIBE, ["poster", session.spawn(() => null)]);

			// What rides after a line's text is the room's vocabulary; a member
			// supplying its own is refused rather than relayed, so nobody can forge
			// a presence change or a file record.
			for (
				const bad of [
					["hello", "roster", "forged"],
					["hello", "file", "x.bin", "application/octet-stream", 5n],
				] as Argument[][]
			) {
				const code = await refusalCode(() => session.send(roomRef, POST, bad));
				assert(code === BAD_ATTACHMENT, `expected bad-attachment, got ${code}`);
			}

			// A file the room will not hold is refused at attach, before a byte moves.
			const tooBig = await refusalCode(() =>
				session.send(roomRef, ATTACH, ["big.bin", "application/octet-stream", BigInt(MAX_ATTACHMENT_BYTES + 1)])
			);
			assert(tooBig === ATTACHMENT_REFUSED, `expected attachment-refused, got ${tooBig}`);
			const unnamed = await refusalCode(() =>
				session.send(roomRef, ATTACH, ["", "application/octet-stream", 4n])
			);
			assert(unnamed === ATTACHMENT_REFUSED, `an unnamed file should be refused, got ${unnamed}`);

			// Posting exposes the file while it streams. Writing beyond its declared
			// extent is still refused at the upload capability.
			const upload = await session.send(roomRef, ATTACH, ["short.bin", "application/octet-stream", 8n]);
			assert(upload instanceof Ref, "attach should answer an upload capability");
			await session.send(roomRef, POST_FILES, ["streaming"]);
			await session.send(upload as Ref, WRITE, [new Uint8Array([1, 2, 3])]);
			const over = await refusalCode(() => session.send(upload as Ref, WRITE, [new Uint8Array(16)]));
			assert(over === UPLOAD_INCOMPLETE, `a write past the declared size should refuse, got ${over}`);

			// Filling it exactly completes the already-published blob and spends the upload.
			await session.send(upload as Ref, WRITE, [new Uint8Array([4, 5, 6, 7, 8])]);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("a room drops its oldest file at the ceiling and says so on read", async () => {
	await withServer(async (port) => {
		const poster = await dial(loopbackTcpDesignator(port));
		const room = await Room.subscribe(poster, await enterOrOpen(poster, "attic"), "poster");

		// Every posted file comes back on our own subscription, so reading the
		// stream is how we get a capability to each one.
		const seen: Attachment[] = [];
		const collecting = (async () => {
			for await (const message of room.messages) {
				seen.push(...message.attachments);
				if (seen.length > MAX_ROOM_ATTACHMENTS) break;
			}
		})();

		// One more file than the room will hold, each a single byte, so the
		// ceiling that trips is the count rather than the byte budget.
		for (let i = 0; i <= MAX_ROOM_ATTACHMENTS; i += 1) {
			await room.attach({
				name: `f${i}.bin`,
				mime: "application/octet-stream",
				bytes: new Uint8Array([i & 0xff]),
			});
		}
		await collecting;
		assert(
			seen.length === MAX_ROOM_ATTACHMENTS + 1,
			`expected every post to come back, saw ${seen.length}`,
		);

		// The newest is readable and the oldest is gone. A dropped file says so
		// rather than answering nothing, which a reader could not tell from a
		// file that really was empty.
		const newest = await room.fetch(seen[seen.length - 1]);
		assert(newest.length === 1, `the newest file should still read, got ${newest.length} bytes`);
		let expiredCode: string | null = null;
		try {
			await room.fetch(seen[0]);
		} catch (err) {
			expiredCode = roomErrorOf(err)?.code ?? null;
		}
		assert(expiredCode === BLOB_EXPIRED, `expected blob-expired for the dropped file, got ${expiredCode}`);

		poster.close();
		await poster.serve().catch(() => {});
	});
});

roomsTest("the server's in-flight budget spans connections and comes back with them", async () => {
	await withServer(async (port) => {
		// Held media can be evicted, so its ceiling is enforced by dropping.
		// Bytes in flight cannot: nobody has seen them and there is no owner to
		// tell. So an upload the server has no room for is refused at attach,
		// against the size it declares, before a byte moves.
		//
		// The bound that matters spans connections. One connection was already
		// held to MAX_MESSAGE_FILES; what that leaves unbounded is the number
		// of connections, which is what this drives.
		const hog = await dial(loopbackTcpDesignator(port));
		hog.serve().catch(() => {});
		const other = await dial(loopbackTcpDesignator(port));
		other.serve().catch(() => {});
		try {
			const hogRoom = await enterOrOpen(hog, "reserved");
			await hog.send(hogRoom, SUBSCRIBE, ["hog", hog.spawn(() => null)]);
			const otherRoom = await enterOrOpen(other, "reserved");
			await other.send(otherRoom, SUBSCRIBE, ["other", other.spawn(() => null)]);

			// One connection declares its whole allowance at the largest file the
			// room takes, and writes none of it.
			const each = BigInt(MAX_ATTACHMENT_BYTES);
			const fillsBudget = Math.floor(MAX_SERVER_PENDING_BYTES / MAX_ATTACHMENT_BYTES);
			for (let i = 0; i < fillsBudget; i += 1) {
				const upload = await hog.send(hogRoom, ATTACH, [`hog${i}.bin`, "application/octet-stream", each]);
				assert(upload instanceof Ref, "a connection's own allowance should be admitted");
			}

			// A second connection is refused, because the budget is the server's.
			const blocked = await refusalCode(() =>
				other.send(otherRoom, ATTACH, ["mine.bin", "application/octet-stream", each])
			);
			assert(blocked === ATTACHMENT_REFUSED, `expected attachment-refused, got ${blocked}`);

			// The hog leaves. Every reservation it held comes back with it, so the
			// second connection can declare the same bytes. A departure that leaked
			// its reservations would leave this refused for the life of the server.
			hog.close();
			await hog.serve().catch(() => {});
			await waitForMatch(
				async () =>
					(await refusalCode(() =>
						other.send(otherRoom, ATTACH, ["mine.bin", "application/octet-stream", each])
					)) ?? "admitted",
				/^admitted$/,
			);
		} finally {
			other.close();
			await other.serve().catch(() => {});
		}
	});
});

roomsTest("a member may hold only so many unposted uploads", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const roomRef = await enterOrOpen(session, "patient");
			await session.send(roomRef, SUBSCRIBE, ["poster", session.spawn(() => null)]);
			// An upload holds bytes nobody has seen, so a member that opens them
			// without posting is refused rather than allowed to accumulate.
			for (let i = 0; i < MAX_MESSAGE_FILES; i += 1) {
				const upload = await session.send(roomRef, ATTACH, [`f${i}.bin`, "application/octet-stream", 1n]);
				assert(upload instanceof Ref, "attach should answer an upload capability");
			}
			const code = await refusalCode(() =>
				session.send(roomRef, ATTACH, ["one-too-many.bin", "application/octet-stream", 1n])
			);
			assert(code === ATTACHMENT_REFUSED, `expected attachment-refused, got ${code}`);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("rooms in different rooms do not see each other's posts", async () => {
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

roomsTest("rooms server frees a room name once its last member leaves", async () => {
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

roomsTest("rooms server grants each live nickname once per room", async () => {
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

roomsTest("rooms server will not grant a name a connected member still answers to", async () => {
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

roomsTest("rooms server removes members that close cleanly", async () => {
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

roomsTest("rooms server removes every membership for a closed connection", async () => {
	await withServer(async (port) => {
		await subscribeTwiceAndClose(port, "general");

		await waitForMatch(
			() => subscribeOnce(port, "general", "second"),
			/1 in the room: second$/,
		);
	});
});

roomsTest("rooms server retires a disconnect batch before broadcasting leaves", async () => {
	const stderr = await withCapturedServer(async (port) => {
		const survivor = await watchRoom(port, "general", "survivor");
		const first = await trySubscribe(port, "general", "first");
		const second = await trySubscribe(port, "general", "second");
		assert(first.ok && second.ok, "the departing members should both join");

		// Both close calls begin before either waiter yields, matching one native
		// event drain carrying several SESSION_CLOSED records.
		await Promise.all([first.leave(), second.leave()]);
		await waitForLine(survivor.lines, /^room: first left \(1 here\)$/);
		await waitForLine(survivor.lines, /^room: second left \(1 here\)$/);
		await survivor.leave();
	});
	assert(!stderr.includes("notify to"), `disconnect cleanup attempted a stale notify:\n${stderr}`);
	assert(!stderr.includes("SessionCondemned"), `disconnect cleanup reached a condemned session:\n${stderr}`);
});

roomsTest("rooms server resubscribe replaces one connection's claimed nickname", async () => {
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

roomsTest("rooms server announces members leaving", async () => {
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

roomsTest("rooms directory lists the live rooms with member counts", async () => {
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

roomsTest("rooms directory pushes open/count/close deltas to a watcher", async () => {
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

roomsTest("a room leave drops just that membership, keeping the connection", async () => {
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

roomsTest(
	"racket one-shot client exits by its deadline while unrelated traffic continues",
	async () => {
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
				// The client's 250 ms deadline starts after Racket has loaded the
				// binding and joined the room. This outer timer is only a hung-process
				// fuse, so it must also admit a cold worktree's module compilation.
				delay(10_000).then(() => timedOut),
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
	},
);

// The same room semantics over iroh's encrypted QUIC instead of TCP. These dial
// the server's announced ocapn:// URI through the iroh ABI companion library, so they
// skip cleanly when that optional library is not built (no cargo). The room's
// wire and behavior are identical, only the transport differs.

roomsTest("an iroh room sturdyref enlivens directly into its room capability", async () => {
	if (!irohLibPresent()) return;
	await withIrohServer(async (uri) => {
		const owner = await Directory.connect(uri, (address) => dial(address));
		const ownerRoom = await Room.subscribe(owner.session, await owner.open("linked"), "owner");
		const ownerLines = roomLines(ownerRoom);
		const link = await owner.link("linked", uri);

		const joinerSession = await dial(uri);
		joinerSession.serve().catch(() => {});
		const joinerRoom = await Room.subscribe(
			joinerSession,
			await joinerSession.enliven(link),
			"joiner",
		);
		await waitForLine(roomLines(joinerRoom), /^room: welcome joiner/);
		// The welcome only says the link handed back a room. This says it handed
		// back *this* one: a redemption that reached a fresh room of the same name
		// would welcome the joiner just as warmly and never reach the owner.
		await waitForLine(ownerLines, /^room: joiner joined \(2 here\)$/);

		await joinerRoom.leave();
		joinerSession.close();
		await joinerSession.serve().catch(() => {});
		await ownerRoom.leave();
		await owner.close();
	});
});

roomsTest("rooms directory registers a member and acknowledges the name", async () => {
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

roomsTest(
	"rooms directory introduces only to the inbox a member minted for the caller",
	async () => {
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
	},
);

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

roomsTest("rooms directory refuses a register whose nick is too long", async () => {
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

roomsTest("rooms directory refuses a room name that is too long", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const code = await refusalCode(() => session.send(directory, OPEN, ["x".repeat(MAX_ROOM + 1)]));
		assert(code === ROOM_TOO_LONG, `expected room-too-long, got ${code}`);

		const accepted = await refusalCode(() => session.send(directory, OPEN, ["x".repeat(MAX_ROOM)]));
		assert(accepted === null, `a room name at the limit should open, got ${accepted}`);
		session.close();
		await session.serve().catch(() => {});
	});
});

roomsTest(
	"rooms directory does not hand a nickname's next holder the last one's inbox",
	async () => {
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
	},
);

roomsTest("a member re-offers its inboxes after a second registration, minting none", async () => {
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
		await memberHost.close();
	});
});

roomsTest("rooms directory keeps one registered nick per connection", async () => {
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

roomsTest("rooms directory refuses a nick another live connection holds", async () => {
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

roomsTest(
	"rooms signaling admits an offer before early ICE and rejects a second active dial",
	async () => {
		await withServer(async (port) => {
			const locator = loopbackTcpDesignator(port);
			const targetDesignator = "11".repeat(32);
			const targetLocator = `ocapn://${targetDesignator}.webrtc`;
			const origin = await Directory.connect(locator, (address) => dial(address));
			const target = await Directory.connect(locator, (address) => dial(address));
			try {
				await origin.register("signal-origin", locator);
				await target.register("signal-target", targetLocator);

				const targetEvents: string[] = [];
				const signalingInbox = target.session.spawn((verb, args) => {
					const id = typeof args[0] === "string" ? args[0] : "";
					if (verb === SIG_OFFER) {
						targetEvents.push(`offer:${id}`);
						void target.signalAnswer(id, "answer-sdp");
					} else if (verb === SIG_CANDIDATE) {
						targetEvents.push(`candidate:${id}:${String(args[1] ?? "")}`);
					}
					return null;
				});
				await target.offerSignaling(signalingInbox);

				const dispose = origin.onSignalCandidate(targetDesignator, () => {});
				let earlySettled = false;
				const early = origin.signalCandidate(targetDesignator, "early-ice").then(() => {
					earlySettled = true;
				});
				await delay(25);
				assert(!earlySettled, "an ICE candidate crossed before its exchange was admitted");

				assert(
					await origin.signalOffer(targetDesignator, "offer-sdp") === "answer-sdp",
					"the admitted signaling offer should receive its answer",
				);
				await early;
				await until(
					() => targetEvents.some((event) => event.endsWith(":early-ice")),
					"the early ICE candidate never reached the admitted exchange",
				);
				assert(
					targetEvents[0]?.startsWith("offer:"),
					`candidate arrived before offer: ${JSON.stringify(targetEvents)}`,
				);

				let duplicate = "";
				try {
					await origin.signalOffer(targetDesignator, "second-offer");
				} catch (error) {
					duplicate = error instanceof Error ? error.message : String(error);
				}
				assertMatch(duplicate, /already active/);
				dispose();
			} finally {
				await Promise.allSettled([origin.close(), target.close()]);
			}
		});
	},
);

roomsTest(
	"rooms signaling rejects a replaced exchange and stale retirement cannot close its successor",
	async () => {
		await withServer(async (port) => {
			const locator = loopbackTcpDesignator(port);
			const targetDesignator = "22".repeat(32);
			const targetLocator = `ocapn://${targetDesignator}.webrtc`;
			const origin = await dial(locator);
			const target = await dial(locator);
			origin.serve().catch(() => {});
			target.serve().catch(() => {});
			try {
				const originDirectory = await origin.fetch(DIRECTORY);
				const targetDirectory = await target.fetch(DIRECTORY);
				await registerAndWatch(origin, originDirectory, "raw-origin", locator);
				await registerAndWatch(target, targetDirectory, "raw-target", targetLocator);

				const offers: string[] = [];
				const signalingInbox = target.spawn((verb, args) => {
					if (verb === SIG_OFFER && typeof args[0] === "string") offers.push(args[0]);
					return null;
				});
				await target.send(targetDirectory, OFFER_SIGNALING, [signalingInbox]);

				const firstAccepted: string[] = [];
				const firstRejected: string[] = [];
				const firstReply = origin.spawn((verb, args) => {
					if (verb === SIG_ACCEPTED && typeof args[0] === "string") {
						firstAccepted.push(args[0]);
					}
					if (verb === SIG_REJECT) firstRejected.push(String(args[0] ?? ""));
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					targetDesignator,
					"first-offer",
					firstReply,
				]);
				await until(() => firstAccepted.length === 1, "first exchange was not admitted");

				const secondAccepted: string[] = [];
				const secondAnswers: string[] = [];
				const secondReply = origin.spawn((verb, args) => {
					if (verb === SIG_ACCEPTED && typeof args[0] === "string") {
						secondAccepted.push(args[0]);
					}
					if (verb === SIG_ANSWER && typeof args[0] === "string") {
						secondAnswers.push(args[0]);
					}
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					targetDesignator,
					"second-offer",
					secondReply,
				]);
				await until(
					() => secondAccepted.length === 1,
					"replacement exchange was not admitted",
				);
				await until(
					() => firstRejected.length === 1,
					"replaced exchange did not reject its caller",
				);
				assertMatch(firstRejected[0], /replaced/);

				const firstId = firstAccepted[0];
				const secondId = secondAccepted[0];
				assert(firstId !== secondId, "replacement reused an exchange identity");
				await origin.tell(originDirectory, SIGNAL_DONE, [firstId]);
				await target.tell(targetDirectory, SIGNAL_ANSWER, [secondId, "second-answer"]);
				await until(
					() => secondAnswers[0] === "second-answer",
					"stale retirement closed the replacement exchange",
				);
				await origin.tell(originDirectory, SIGNAL_DONE, [secondId]);
				assert(
					offers.includes(firstId) && offers.includes(secondId),
					"target did not receive both offers",
				);
			} finally {
				origin.close();
				target.close();
				await Promise.allSettled([
					origin.serve().catch(() => {}),
					target.serve().catch(() => {}),
				]);
			}
		});
	},
);

roomsTest("rooms signaling evicts the oldest bounded exchange and rejects its caller", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const origin = await dial(locator);
		const originServed = origin.serve().catch(() => {});
		const targets: { session: Session; served: Promise<void>; designator: string }[] = [];
		try {
			const originDirectory = await origin.fetch(DIRECTORY);
			await registerAndWatch(origin, originDirectory, "eviction-origin", locator);

			const setupTargets = Array.from(
				{ length: MAX_SIGNAL_EXCHANGES + 1 },
				async (_, index) => {
					const session = await dial(locator);
					const served = session.serve().catch(() => {});
					const directory = await session.fetch(DIRECTORY);
					const designator = (index + 1).toString(16).padStart(64, "0");
					await registerAndWatch(
						session,
						directory,
						`eviction-target-${index}`,
						`ocapn://${designator}.webrtc`,
					);
					await session.send(directory, OFFER_SIGNALING, [session.spawn(() => null)]);
					return { session, served, designator };
				},
			);
			targets.push(...await Promise.all(setupTargets));

			const firstRejected: string[] = [];
			for (const [index, target] of targets.entries()) {
				const reply = origin.spawn((verb, args) => {
					if (index === 0 && verb === SIG_REJECT) {
						firstRejected.push(String(args[0] ?? ""));
					}
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					target.designator,
					`offer-${index}`,
					reply,
				]);
			}
			await until(() => firstRejected.length === 1, "oldest exchange was not evicted");
			assertMatch(firstRejected[0], /evicted/);
		} finally {
			origin.close();
			for (const target of targets) target.session.close();
			await Promise.allSettled([originServed, ...targets.map((target) => target.served)]);
		}
	});
});

roomsTest("rooms server over iroh welcomes a subscriber by its ocapn:// URI", async () => {
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

roomsTest(
	"rooms server over iroh broadcasts joins and leaves through the capability callback",
	async () => {
		if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
		await withIrohServer(async (uri) => {
			const watcher = await watchRoomIroh(uri, "general", "iroh-watcher");
			const leaver = await watchRoomIroh(uri, "general", "iroh-leaver");
			await waitForLine(watcher.lines, /^room: iroh-leaver joined \(2 here\)$/);

			await leaver.leave();

			await waitForLine(watcher.lines, /^room: iroh-leaver left \(1 here\)$/);
			await watcher.leave();
		});
	},
);

roomsTest("a second server on one port stops rather than sharing it", async () => {
	// A pancake listener asks for a reusable address, so two servers can hold one
	// address with neither being told: both announce, and the kernel gives each
	// arriving connection to whichever it likes. Two members then join the same
	// room name at the same address and never see each other, and nothing
	// anywhere says why. Refusing is the only honest answer, so it is checked
	// against a real one already listening rather than against a bind in
	// isolation.
	const port = freeServerPort();
	const first = new Deno.Command("deno", {
		args: [...DENO_FLAGS, SERVER, String(port)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	try {
		await readPort(first);
		const second = new Deno.Command("deno", {
			args: [...DENO_FLAGS, SERVER, String(port)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		}).spawn();
		const [status, said] = await Promise.all([
			second.status,
			new Response(second.stderr).text(),
			new Response(second.stdout).text(),
		]);
		assert(!status.success, `the second server exited ${status.code} instead of refusing the port`);
		assertMatch(said, /already in use/);
		assertMatch(said, new RegExp(String(port)));
	} finally {
		try {
			first.kill("SIGTERM");
		} catch {
			// Already gone.
		}
		await first.status;
	}
});

roomsTest("a server that cannot start says so and exits saying so", async () => {
	// The backstop that keeps one stray notify from taking CapTP down was
	// catching startup too: a state file it could not read printed a stack trace,
	// left the process running with nothing listening, and exited 0. A supervisor
	// reading that exit code is told the server ran and stopped cleanly, which is
	// the worst of the three things that could be said.
	const dir = await Deno.makeTempDir();
	try {
		await Deno.writeTextFile(
			`${dir}/rooms.json`,
			JSON.stringify({ version: 1, identitySeed: "zz", roomLinkSecret: "zz", linkedRooms: [] }) + "\n",
		);
		const proc = new Deno.Command("deno", {
			// Its own write grant, because reading the state file is the point and
			// the ordinary server child is given none.
			args: [...DENO_FLAGS, `--allow-write=${dir}`, SERVER, "0"],
			cwd: ROOT,
			env: { ROOMS_STATE: dir },
			stdout: "piped",
			stderr: "piped",
		}).spawn();
		const [status, said, out] = await Promise.all([
			proc.status,
			new Response(proc.stderr).text(),
			new Response(proc.stdout).text(),
		]);
		assert(!status.success, `a server with an unreadable state file exited ${status.code}`);
		assert(
			!out.includes("ROOMS-SERVER-LISTENING"),
			"a server that could not read its state announced itself as listening",
		);
		// Said as a sentence, and naming the file, because that file is the one
		// input here a person can repair by hand.
		assertMatch(said, /rooms: could not start: /);
		assertMatch(said, /rooms\.json/);
		assert(!said.includes("at parseState"), `the operator was handed a stack trace instead of a sentence: ${said}`);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

roomsTest("the directory answers the first message a fresh connection sends", async () => {
	if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
	// A loop-backed listener dispatches an accepted session's first message as
	// it steps, which can be before the accepting code has run at all. The
	// directory used to be published onto each session as it arrived, so a dial
	// that fetched immediately raced that publish and lost about three times in
	// four, and losing was answered `unknown swissnum` — a room that was there
	// telling a member it was not. Published on the Host, it exists before any
	// connection does.
	//
	// Repeated because the failure was a race rather than a rule: one round
	// passing proves nothing, and the odds of six passing by luck are small.
	await withIrohServer(async (uri) => {
		for (let round = 1; round <= 6; round++) {
			const session = await dial(uri);
			session.serve().catch(() => {});
			// No settling wait between opening the connection and asking, which is
			// the whole of what this holds.
			await session.fetch(DIRECTORY);
			session.close();
		}
	});
});

roomsTest("holding a line's reference is the authority to change or withdraw it", async () => {
	await withServer(async (port) => {
		const author = await dial(loopbackTcpDesignator(port));
		const authorRoom = await Room.subscribe(author, await enterOrOpen(author, "edits"), "author");

		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "edits"), "reader");
		const heard = readerRoom.messages[Symbol.asyncIterator]();
		const next = async (): Promise<Message> => {
			for (;;) {
				const { value, done } = await within(heard.next(), "the next line in the room");
				assert(!done && value !== undefined, "the reader's stream ended early");
				// Skip the membership traffic; this test is about one line.
				if (value.presence === undefined) return value;
			}
		};

		// Posting answers with the line it made. Nothing here says who may change
		// it, because the reference going to this member is the whole of that.
		const line = await authorRoom.say("frist post");
		assert(line !== null, "post answered with no reference to the line it made");

		const said = await next();
		assert(said.text === "frist post", `the reader heard ${said.text}`);
		assert(said.change === "said", `a new line should be said, not ${said.change}`);
		assert(said.lineId !== undefined, "a line arrived without the id an edit would name");

		// Changing it reaches everybody who has it on screen, naming the same line.
		await line.edit("first post");
		const fixed = await next();
		assert(fixed.change === "edited", `an edit should be edited, not ${fixed.change}`);
		assert(fixed.lineId === said.lineId, "an edit named a different line than it changed");
		assert(fixed.text === "first post", `the edit carried ${fixed.text}`);
		assert(fixed.from === "author", `an edit should still be the author's, not ${fixed.from}`);

		// Taking it back names it once more, and saying so twice is somebody
		// making sure rather than doing something wrong.
		await line.withdraw();
		const gone = await next();
		assert(gone.change === "withdrawn", `a withdrawal should be withdrawn, not ${gone.change}`);
		assert(gone.lineId === said.lineId, "a withdrawal named a different line");
		await line.withdraw();

		// A withdrawn line stays withdrawn: editing one afterwards would put text
		// back on screen that its author had taken down.
		let refused: unknown = null;
		try {
			await line.edit("back again");
		} catch (error) {
			refused = error;
		}
		assert(refused !== null, "a withdrawn line let itself be edited back onto everybody's screen");
	});
});

roomsTest("a member's own standing is theirs to state, and the room tells the rest", async () => {
	await withServer(async (port) => {
		const first = await dial(loopbackTcpDesignator(port));
		const firstRoom = await Room.subscribe(first, await enterOrOpen(first, "standing"), "first");

		const other = await dial(loopbackTcpDesignator(port));
		const otherRoom = await Room.subscribe(other, await enterOrOpen(other, "standing"), "other");
		const heard = otherRoom.messages[Symbol.asyncIterator]();
		const nextAway = async (): Promise<{ name: string; reason: string }> => {
			for (let i = 0; i < 8; i++) {
				const { value, done } = await within(heard.next(), "a standing from the room");
				assert(!done && value !== undefined, "the other member's stream ended early");
				if (value.presence?.kind === "away") return value.presence;
			}
			throw new Error("no standing arrived");
		};

		// Nothing is handed over for this: the room writes the standing of the
		// membership that called, so a member can say it about themselves and
		// about nobody else.
		await firstRoom.away("back in ten");
		const gone = await nextAway();
		assert(gone.name === "first", `the room said ${gone.name} had stepped away`);
		assert(gone.reason === "back in ten", `the reason arrived as ${gone.reason}`);

		// Somebody arriving afterwards is told who is already away, on the same
		// line every later change arrives on.
		const late = await dial(loopbackTcpDesignator(port));
		const lateRoom = await Room.subscribe(late, await enterOrOpen(late, "standing"), "late");
		const lateHeard = lateRoom.messages[Symbol.asyncIterator]();
		let told: string | undefined;
		for (let i = 0; i < 8 && told === undefined; i++) {
			const { value } = await within(lateHeard.next(), "what a newcomer is told");
			if (value?.presence?.kind === "away") told = value.presence.reason;
		}
		assert(told === "back in ten", `a newcomer was told the standing was ${told}`);

		// Bare is back, which is what `/away` has meant in every client for thirty
		// years, and it reads as a change rather than as nothing said.
		await firstRoom.away("");
		const back = await nextAway();
		assert(back.reason === "", `coming back arrived as ${back.reason}`);

		// A reason too long is cut rather than refused: losing the tail of a
		// courtesy is a smaller wrong than not marking somebody away at all.
		await firstRoom.away("y".repeat(MAX_AWAY + 40));
		const cut = await nextAway();
		assert(cut.reason.length === MAX_AWAY, `a long reason arrived at ${cut.reason.length} characters`);
	});
});

roomsTest("holding the topic capability is the authority to say what a room is about", async () => {
	await withServer(async (port) => {
		const first = await dial(loopbackTcpDesignator(port));
		const firstRoom = await Room.subscribe(first, await enterOrOpen(first, "topical"), "first");
		assert(firstRoom.canSetTopic, "subscribing did not answer with a topic to set");

		const other = await dial(loopbackTcpDesignator(port));
		const otherRoom = await Room.subscribe(other, await enterOrOpen(other, "topical"), "other");
		const heard = otherRoom.messages[Symbol.asyncIterator]();
		const next = async (): Promise<Message> => {
			for (;;) {
				const { value, done } = await within(heard.next(), "the next line in the room");
				assert(!done && value !== undefined, "the other member's stream ended early");
				if (value.presence === undefined) return value;
			}
		};

		// Setting it reaches everybody in the room, as a fact and as a sentence: a
		// client that has never heard of topics still shows the line saying it moved.
		await firstRoom.setTopic("what we are here for");
		const said = await next();
		assert(said.facts?.topic === "what we are here for", `the topic arrived as ${said.facts?.topic}`);
		assert(said.text.includes("what we are here for"), `the change said "${said.text}"`);

		// The room holds the topic, not whoever set it, so somebody arriving later
		// is told what they walked into.
		const late = await dial(loopbackTcpDesignator(port));
		const lateRoom = await Room.subscribe(late, await enterOrOpen(late, "topical"), "late");
		const lateHeard = lateRoom.messages[Symbol.asyncIterator]();
		let told: string | undefined;
		for (let i = 0; i < 8 && told === undefined; i++) {
			const { value } = await within(lateHeard.next(), "the topic a newcomer is told");
			told = value?.facts?.topic;
		}
		assert(told === "what we are here for", `a newcomer was told the topic was ${told}`);

		// Every member holds one: the room has no ranks to hand out, and the second
		// member setting it is not a permission being granted but a reference being
		// held.
		assert(otherRoom.canSetTopic, "a member who did not open the room holds no topic");
		await otherRoom.setTopic("");
		const cleared = await next();
		assert(cleared.facts?.topic === "", "taking the topic down did not read as an empty topic");

		// Too long is refused rather than silently cut, the same as a line.
		let refused: unknown = null;
		try {
			await firstRoom.setTopic("x".repeat(MAX_TOPIC + 1));
		} catch (error) {
			refused = error;
		}
		assert(refused !== null, "a topic past the room's cap was accepted");
	});
});

roomsTest("a connection watching the directory twice is watching it once", async () => {
	await withServer(async (port) => {
		const watcherConn = await dial(loopbackTcpDesignator(port));
		const watch = await watchDirectory(watcherConn);

		// The same connection asks again. Every room event walks the watcher list,
		// so a second row here would make each join and departure anywhere on this
		// server do its work twice for this one peer, and nothing bounds how many
		// times it may ask.
		const directory = await watcherConn.fetch(DIRECTORY);
		const second = watcherConn.spawn((_verb, args) => {
			watch.events.push(`${args[0]} ${args[1]} ${Number(args[2])}`);
			return null;
		});
		await watcherConn.send(directory, WATCH, [second]);

		const member = await watchRoom(port, "echoing", "one");
		await waitForLine(watch.events, /^opened echoing 1$/);
		// A count delta after it, so the open above has been fully delivered by the
		// time this is counted: a second copy would already be in the list.
		const another = await watchRoom(port, "echoing", "two");
		await waitForLine(watch.events, /^count echoing 2$/);
		const opens = watch.events.filter((event) => event === "opened echoing 1").length;
		assert(opens === 1, `one connection watching twice was told the room opened ${opens} times`);

		await member.leave();
		await another.leave();
		watcherConn.close();
		await watcherConn.serve().catch(() => {});
	});
});

roomsTest("a file that stops arriving is given up on rather than waited on forever", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "stalling"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "stalling"), "reader");

		// Published with none of its bytes sent, so the read below parks. Parking is
		// ordinary and a room behaving itself settles it, which is why the deadline
		// this passes is short while the one the app ships sits above the window a
		// room may hold a reader for. What is not ordinary is a partner that never
		// settles it at all, and the reader has no other way out: the row is drawn
		// as still arriving, and a row that is arriving is one nothing restarts.
		const source = { name: "halted.bin", mime: "application/octet-stream", bytes: new Uint8Array([1, 2, 3]) };
		const upload = await senderRoom.stage(source);
		await senderRoom.postFiles("on its way");

		let posted: Attachment | null = null;
		for await (const message of readerRoom.messages) {
			if (message.attachments.length > 0) {
				posted = message.attachments[0];
				break;
			}
		}
		assert(posted !== null, "the staged file was never announced");

		let stalled: unknown = null;
		await fetchBlob(reader, posted, undefined, 200).catch((err) => {
			stalled = err;
		});
		assert(
			stalled instanceof Unanswered,
			`a read nobody answered ended as ${stalled === null ? "success" : String(stalled)}`,
		);

		// And giving up is not giving in: the same file arrives when its bytes do,
		// which is what makes the row's control worth offering again.
		await senderRoom.upload(upload, source);
		const bytes = await within(fetchBlob(reader, posted), "the file to arrive once its bytes were sent");
		assert(bytes.length === 3 && bytes[0] === 1, "the file did not arrive after the transfer resumed");

		await readerRoom.leave();
		reader.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("a file the room is still receiving holds only so many readers waiting on it", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "queue"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "queue"), "reader");

		// Staged and published, with none of its bytes sent. A read for bytes the
		// room does not have waits rather than answering short, so every read below
		// parks: this is the one structure here that grows with what a peer sends.
		const source = { name: "slow.bin", mime: "application/octet-stream", bytes: new Uint8Array([7, 7, 7]) };
		const upload = await senderRoom.stage(source);
		await senderRoom.postFiles("coming");

		let posted: Attachment | null = null;
		for await (const message of readerRoom.messages) {
			if (message.attachments.length > 0) {
				posted = message.attachments[0];
				break;
			}
		}
		assert(posted !== null, "the staged file was never announced");

		const parked: Promise<Argument>[] = [];
		for (let i = 0; i < MAX_BLOB_READERS; i++) {
			const waiting = reader.send(posted.blob, READ, [0n, BigInt(BLOB_CHUNK)]) as Promise<Argument>;
			// Refused below, and every one of these settles when the bytes land. An
			// unobserved rejection would take the process down before the assertion.
			void waiting.catch(() => {});
			parked.push(waiting);
		}
		let refused = "";
		await reader.send(posted.blob, READ, [0n, BigInt(BLOB_CHUNK)]).catch((err) => {
			refused = err instanceof Error ? err.message : String(err);
		});
		assert(
			refused.includes(ATTACHMENT_REFUSED) || refused.includes("readers waiting"),
			`a file past its reader ceiling answered ${JSON.stringify(refused)}`,
		);

		// And the ceiling is a ceiling, not a wall: the readers already waiting are
		// owed their bytes, and the upload finishing is what pays them.
		await senderRoom.upload(upload, source);
		const first = await within(parked[0], "a parked read to be paid by the finished upload");
		assert(first instanceof Uint8Array && first[0] === 7, "a parked read did not get the file it waited for");

		await readerRoom.leave();
		reader.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("one connection re-entering a room keeps its place, and a leave after it would not", async () => {
	await withServer(async (port) => {
		const member = await dial(loopbackTcpDesignator(port));
		const ref = await enterOrOpen(member, "revolving");
		const first = await Room.subscribe(member, ref, "ada");

		const watcher = await dial(loopbackTcpDesignator(port));
		const watching = await Room.subscribe(watcher, await enterOrOpen(watcher, "revolving"), "watcher");
		const seen = watching.messages.getReader();

		// Re-entering is one connection re-claiming its place: the room replaces
		// the record rather than seating a second member under one name. This is
		// what a page does when a room stops delivering under a live connection,
		// and it is the only way back into a room whose history it still holds.
		const second = await Room.subscribe(member, ref, "ada");
		first.replaced();
		let refusedAfterReentry = "";
		await second.say("still here").catch((err) => {
			refusedAfterReentry = err instanceof Error ? err.message : String(err);
		});
		assert(
			refusedAfterReentry === "",
			`re-entering took back the place it had just made: ${refusedAfterReentry}`,
		);

		let heard = "";
		while (heard === "") {
			const { done, value } = await within(seen.read(), "the re-entered member to be heard");
			if (done) break;
			if (value.from === "ada") heard = value.text;
		}
		assert(heard === "still here", `a re-entered member was not heard: ${JSON.stringify(heard)}`);

		// And why `replaced` exists rather than `leave`. A departure is keyed by the
		// connection, so a leave sent on the membership that was replaced takes back
		// the place the re-entry had just made, leaving a member who believes they
		// are in a room the room no longer has them in.
		await first.leave();
		let refused = "";
		await second.say("anybody there").catch((err) => {
			refused = err instanceof Error ? err.message : String(err);
		});
		assert(
			refused !== "",
			"a leave on a replaced membership left the re-entered one standing, so the two are not one place",
		);

		seen.releaseLock();
	});
});

roomsTest("the room's own tidying cannot take back a line's authority", async () => {
	await withServer(async (port) => {
		const author = await dial(loopbackTcpDesignator(port));
		const room = await Room.subscribe(author, await enterOrOpen(author, "bounded"), "author");

		// A room that answered every post with a reference would end up holding one
		// per line said, so it lets go of the older ones. Letting go is the room
		// dropping its own hold, not a revocation: the member's reference is what
		// carries the authority, and it stays live because they hold it.
		//
		// Which makes this the test of the whole shape. A room that "tidied up" by
		// taking the authority back would pass every other check here and quietly
		// break the promise the design rests on, so it is checked from the far
		// side, where possession is all there is.
		const first = await room.say("the first thing said");
		assert(first !== null, "post answered with no reference to the line it made");
		for (let i = 0; i < 120; i++) await room.say(`line ${i}`);
		await first.edit("changed long afterwards");
	});
});
