import { type Argument, type Behavior, Ref, type Session } from "@glowcap/runtime";
import { Directory, Room } from "../../lib/room/client.ts";
import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { MAX_AWAY, MAX_SEAT_BADGE, MAX_SEAT_SAID } from "../../lib/limits.ts";
import {
	AWAY,
	ENTER,
	ENTER_PUBLICATION,
	LEAVE,
	LIST,
	LIST_PUBLICATIONS,
	POST,
	SUBSCRIBE,
	WATCH,
} from "../../lib/protocol.ts";
import { IrcBridgeRoom } from "../../irc/bridge/room.ts";
import { IRC_ROSTER_LIMIT } from "../../irc/bridge/roster.ts";
import { ircSeatWords } from "../../irc/bridge/seat.ts";
import { ircChannelProjection, runIrcSession } from "../../irc/bridge/client.ts";
import { IrcChannelRelay } from "../../irc/bridge/outbound.ts";
import { encodeIrc, readIrcLines } from "../../irc/protocol.ts";
import { assertEquals } from "../assert.ts";
import { oneShotRoomAdmission } from "../../lib/room/admission.ts";

function testRef(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("the IRC bridge admits room and directory commands before changing state", () => {
	const relay = new IrcChannelRelay("#exact", "bridgebot");
	const bridge = new IrcBridgeRoom("fixture", "#exact", relay, {
		ownOutbound: true,
		publicationId: "bridge-generation",
		origin: "irc.fixture:6697",
	});
	const released: Ref[] = [];
	const spawned: Behavior[] = [];
	const session = {
		release: (ref: Ref) => released.push(ref),
		tell: () => Promise.resolve(),
		spawn: (behavior: Behavior) => {
			spawned.push(behavior);
			return testRef();
		},
	} as unknown as Session;
	const room = bridge.roomBehavior({ sessionFor: () => session });
	const directory = bridge.directoryBehavior(() => session);
	const refused = (run: () => unknown): boolean => {
		try {
			run();
			return false;
		} catch {
			return true;
		}
	};

	const rejectedInbox = testRef();
	assertEquals(refused(() => room(SUBSCRIBE, ["surplus", rejectedInbox, "extra"])), true);
	assertEquals(released.includes(rejectedInbox), true, "a refused subscription retained its inbox");

	const inbox = testRef();
	room(SUBSCRIBE, ["reader", inbox]);
	const membership = spawned[0];
	assertEquals(refused(() => membership(POST, ["line", "surplus"])), true);
	assertEquals(refused(() => membership(AWAY, ["x".repeat(MAX_AWAY + 1)])), true);
	assertEquals(refused(() => membership(LEAVE, ["surplus"])), true);
	const listed = directory(LIST, []) as unknown[][];
	assertEquals(listed.length, 1, "a refused leave removed the room");
	assertEquals(listed[0]?.[0], "fixture/#exact");
	assertEquals(String(listed[0]?.[1]), "1", "a refused leave changed membership");
	const publications = directory(LIST_PUBLICATIONS, []) as Argument[][];
	assertEquals(publications.length, 1);
	assertEquals(
		publications[0]?.map((value) => typeof value === "bigint" ? String(value) : value),
		["fixture/#exact", "1", "bridge-generation", "bridge", "irc.fixture:6697", "bridge", "participant"],
	);
	assertEquals(refused(() => directory(ENTER_PUBLICATION, ["fixture/#exact"])), true);
	assertEquals(directory(ENTER_PUBLICATION, ["bridge-generation"]) instanceof Ref, true);
	assertEquals(directory(ENTER, ["fixture/#exact"]) instanceof Ref, true);

	const rejectedWatcher = testRef();
	assertEquals(refused(() => directory(WATCH, [rejectedWatcher, "surplus"])), true);
	assertEquals(released.includes(rejectedWatcher), true, "a refused watch retained its inbox");
	assertEquals(refused(() => directory(LIST, ["surplus"])), true);

	membership(LEAVE, []);
});

Deno.test("a handed IRC room capability acts for the session calling it", () => {
	const relay = new IrcChannelRelay("#handed", "bridgebot");
	const bridge = new IrcBridgeRoom("fixture", "#handed", relay, { ownOutbound: true });
	const spawned: Behavior[] = [];
	const fakeSession = () =>
		({
			release: () => {},
			tell: () => Promise.resolve(),
			spawn: (behavior: Behavior) => {
				spawned.push(behavior);
				return testRef();
			},
		}) as unknown as Session;
	const first = fakeSession();
	const second = fakeSession();
	let active = first;
	const room = bridge.roomBehavior({ sessionFor: () => active });
	room(SUBSCRIBE, ["first", testRef()]);
	const firstMembership = spawned.at(-1)!;
	active = second;
	room(SUBSCRIBE, ["second", testRef()]);
	const secondMembership = spawned.at(-1)!;
	const listed = bridge.directoryBehavior(() => first)(LIST, []) as unknown[][];
	assertEquals(String(listed[0]?.[1]), "2", "a handed room capability retained the first caller session");
	secondMembership(LEAVE, []);
	active = first;
	firstMembership(LEAVE, []);
});

Deno.test("retried IRC invitation entrances compete over one membership", () => {
	const relay = new IrcChannelRelay("#invited", "bridgebot");
	const bridge = new IrcBridgeRoom("fixture", "#invited", relay, { ownOutbound: true });
	const released: Ref[] = [];
	const fakeSession = () =>
		({
			release: (ref: Ref) => released.push(ref),
			tell: () => Promise.resolve(),
			spawn: () => testRef(),
		}) as unknown as Session;
	const first = fakeSession();
	const second = fakeSession();
	let active = first;
	const admission = oneShotRoomAdmission();
	const entrance = bridge.roomBehavior({ sessionFor: () => active, admission });
	entrance(SUBSCRIBE, ["first", testRef()]);
	active = second;
	const secondInbox = testRef();
	let refused = false;
	try {
		entrance(SUBSCRIBE, ["second", secondInbox]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true, "one IRC invitation admitted two Rooms memberships");
	assertEquals(released.includes(secondInbox), true, "a spent IRC invitation retained the refused inbox");
	bridge.retire(first);
});

Deno.test("an IRC bridge reports a live member notification failure", async () => {
	const trouble: string[] = [];
	const relay = new IrcChannelRelay("#trouble", "bridgebot");
	const bridge = new IrcBridgeRoom("fixture", "#trouble", relay, {
		ownOutbound: true,
		onTrouble: (context) => trouble.push(context),
	});
	const session = {
		sessionOpen: true,
		release: () => {},
		tell: () => Promise.reject(new Error("injected notification refusal")),
		spawn: () => testRef(),
	} as unknown as Session;
	bridge.roomBehavior({ sessionFor: () => session })(SUBSCRIBE, ["reader", testRef()]);
	await Promise.resolve();
	assertEquals(trouble.some((context) => context.includes("member notification")), true);
	bridge.retire(session);
});

Deno.test("the IRC bridge bounds the roster before retaining another name", () => {
	const relay = new IrcChannelRelay("#bounded", "bridgebot");
	const bridge = new IrcBridgeRoom("fixture", "#bounded", relay);
	for (let offset = 0; offset < IRC_ROSTER_LIMIT; offset += 16) {
		const names = Array.from({ length: Math.min(16, IRC_ROSTER_LIMIT - offset) }, (_, at) => `n${offset + at}`);
		bridge.apply({
			tags: new Map(),
			prefix: "fixture",
			command: "353",
			params: ["bridge", "=", "#bounded", names.join(" ")],
		});
	}
	let refused = false;
	try {
		bridge.apply({
			tags: new Map(),
			prefix: "fixture",
			command: "353",
			params: ["bridge", "=", "#bounded", "one-too-many"],
		});
	} catch {
		refused = true;
	}
	assertEquals(refused, true, "the IRC roster grew past its retained bound");
	bridge.disconnected();
});

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

Deno.test({
	name: "the two-way IRC bridge carries a scripted channel through live Rooms CapTP",
	sanitizeOps: false,
	sanitizeResources: false,
	fn: async () => {
		const ircListener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
		const relay = new IrcChannelRelay("#ocapn", "bridgebot", { writable: true, sendIntervalMs: 0 });
		const bridge = new IrcBridgeRoom("fixture", "#ocapn", relay);
		const roomsServer = await roomsListen("127.0.0.1", 0, roomsHost());
		let feed!: () => void;
		const feedReady = new Promise<void>((resolve) => {
			feed = resolve;
		});
		let registered!: () => void;
		const registrationReady = new Promise<void>((resolve) => {
			registered = resolve;
		});
		let closeFixture!: () => void;
		const fixtureMayClose = new Promise<void>((resolve) => {
			closeFixture = resolve;
		});
		let parted!: () => void;
		const partObserved = new Promise<void>((resolve) => {
			parted = resolve;
		});

		const fixture = (async () => {
			const conn = await ircListener.accept();
			ircListener.close();
			try {
				const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
				assertEquals((await lines.next()).value?.command, "CAP");
				assertEquals((await lines.next()).value?.command, "NICK");
				assertEquals((await lines.next()).value?.command, "USER");
				await writeAll(
					conn,
					new TextEncoder().encode(":fixture CAP bridgebot LS :multi-prefix sasl=PLAIN\r\n"),
				);
				const capRequest = (await lines.next()).value;
				assertEquals([capRequest?.command, capRequest?.params], ["CAP", ["REQ", "sasl"]]);
				await writeAll(conn, new TextEncoder().encode(":fixture CAP bridgebot ACK :sasl\r\n"));
				assertEquals((await lines.next()).value?.params, ["PLAIN"]);
				await writeAll(conn, encodeIrc("AUTHENTICATE", ["+"]));
				const auth = (await lines.next()).value;
				assertEquals(auth?.command, "AUTHENTICATE");
				assertEquals(
					new TextDecoder().decode(
						Uint8Array.from(atob(auth?.params[0] ?? ""), (char) => char.charCodeAt(0)),
					),
					"\0bridge-account\0bridge-password",
				);
				await writeAll(
					conn,
					new TextEncoder().encode(":fixture 903 bridgebot :SASL authentication successful\r\n"),
				);
				assertEquals((await lines.next()).value?.command, "CAP");
				await writeAll(conn, new TextEncoder().encode(":fixture 001 bridgebot :welcome\r\n"));
				const join = (await lines.next()).value;
				assertEquals([join?.command, join?.params], ["JOIN", ["#ocapn"]]);
				await writeAll(conn, new TextEncoder().encode(":bridgebot!u@example JOIN :#ocapn\r\n"));
				await feedReady;
				await writeAll(conn, new TextEncoder().encode("PING :clock\r\n"));
				const pong = (await lines.next()).value;
				assertEquals([pong?.command, pong?.params], ["PONG", ["clock"]]);
				await writeAll(
					conn,
					new TextEncoder().encode(
						":fixture 353 bridgebot = #ocapn :bridgebot @alice +bob\r\n" +
							":fixture 366 bridgebot #ocapn :end of names\r\n" +
							"@time=now :alice!u@example PRIVMSG #ocapn :hello from IRC\r\n",
					),
				);
				const nativePost = (await lines.next()).value;
				assertEquals([nativePost?.command, nativePost?.params], [
					"PRIVMSG",
					["#ocapn", "<reader> hello IRC from Rooms"],
				]);
				const baselinePost = (await lines.next()).value;
				assertEquals([baselinePost?.command, baselinePost?.params], [
					"PRIVMSG",
					["#ocapn", "<baseline-reader> hello IRC from baseline"],
				]);
				const part = (await lines.next()).value;
				assertEquals([part?.command, part?.params[0]], ["PART", "#ocapn"]);
				await writeAll(
					conn,
					new TextEncoder().encode(":bridgebot!u@example PART #ocapn :leaving\r\nPING :parted\r\n"),
				);
				const partPong = (await lines.next()).value;
				assertEquals([partPong?.command, partPong?.params], ["PONG", ["parted"]]);
				parted();
				await fixtureMayClose;
			} finally {
				conn.close();
			}
		})();

		const ircConn = await Deno.connect({ hostname: "127.0.0.1", port: ircListener.addr.port });
		const irc = runIrcSession(ircConn, ircChannelProjection(bridge, relay), {
			nick: "bridgebot",
			sasl: { account: "bridge-account", password: "bridge-password" },
			onRegistered: registered,
		})
			.catch((error) => {
				assertEquals(String(error).includes("ended the connection"), true, `unexpected IRC close: ${error}`);
			})
			.finally(() => {
				try {
					ircConn.close();
				} catch { /* fixture closed first */ }
			});

		const host = (async () => {
			for await (const session of roomsServer) {
				session.onClose(() => bridge.retire(session));
				bridge.publish(session);
				void session.serve().catch(() => {});
			}
		})();

		await using runtime = await openRoomsRuntime();
		const directory = await Directory.connect(
			loopbackTcpDesignator(roomsServer.port),
			(address) => dial(address, runtime),
		);
		const listed = await directory.list();
		assertEquals(listed.map((room) => room.name), [bridge.roomName]);
		const watched = await directory.watch(() => {});
		assertEquals(watched.map((room) => room.name), [bridge.roomName]);
		let reserved = "";
		try {
			await Room.subscribe(directory.session, await directory.enter(bridge.roomName), "IRC/alice");
		} catch (error) {
			reserved = String(error);
		}
		assertEquals(
			reserved.includes('beginning with "irc/"'),
			true,
			`the bridge attribution namespace was claimable: ${reserved}`,
		);
		const room = await Room.subscribe(directory.session, await directory.enter(bridge.roomName), "reader");
		const messages = room.messages.getReader();
		await using baselineRuntime = await openRoomsRuntime({ host: roomsHost(undefined, "interop") });
		const baselineDirectory = await Directory.connect(
			loopbackTcpDesignator(roomsServer.port),
			(address) => dial(address, baselineRuntime),
		);
		assertEquals(
			[baselineDirectory.session.profile.captpVersion, baselineDirectory.session.profile.codec],
			["v1_0", "syrup"],
			"the Goblins-compatible floor was not negotiated",
		);
		const baselineRoom = await Room.subscribe(
			baselineDirectory.session,
			await baselineDirectory.enter(bridge.roomName),
			"baseline-reader",
		);
		const baselineMessages = baselineRoom.messages.getReader();
		await registrationReady;
		feed();

		let fromIrc: { from: string; text: string } | null = null;
		// What the bridge says about itself, which a reader needs before the
		// roster means anything: without it a row reads as a Rooms member with an
		// oddly spelled name. Collected off the same stream rather than asked for,
		// because a client is told rather than asking.
		let declared: unknown = null;
		for (let i = 0; i < 12 && (fromIrc === null || declared === null); i += 1) {
			const { value, done } = await messages.read();
			if (done) break;
			if (value.facts?.bridge != null) declared = value.facts.bridge;
			if (value.from === "irc/alice") fromIrc = { from: value.from, text: value.text };
		}
		assertEquals(fromIrc, { from: "irc/alice", text: "hello from IRC" });
		assertEquals(
			declared,
			// The scope is the network this bridge fronts. A reader who linked on
			// a sibling channel of it is already linked here, and this is how a
			// client knows that before anyone in this room has.
			{ prefix: "irc/", badge: "IRC", said: "IRC only", scope: "fixture" },
			"the bridge never told a reader what it calls its own",
		);
		let baselineFromIrc: { from: string; text: string } | null = null;
		for (let i = 0; i < 12 && baselineFromIrc === null; i += 1) {
			const { value, done } = await baselineMessages.read();
			if (done) break;
			if (value.from === "irc/alice") baselineFromIrc = { from: value.from, text: value.text };
		}
		assertEquals(baselineFromIrc, { from: "irc/alice", text: "hello from IRC" });
		const afterNames = await directory.list();
		assertEquals(afterNames[0].count, 4, "the bridge bot is hidden; two IRC nicks and two Rooms readers remain");

		await room.say("hello IRC from Rooms");
		await baselineRoom.say("hello IRC from baseline");

		messages.releaseLock();
		baselineMessages.releaseLock();
		await room.leave();
		await baselineRoom.leave();
		await partObserved;
		assertEquals((await directory.list())[0].count, 0, "a parted bridge retained an unobservable IRC roster");
		closeFixture();
		await directory.close();
		await baselineDirectory.close();
		roomsServer.close();
		await Promise.all([fixture, irc, host]);
	},
});

Deno.test("the IRC bridge writes its own badges and sentences", () => {
	// The one place these words live. They used to be a switch in the browser,
	// which meant a second bridge could not say anything of its own without a
	// client release; carrying them means this is the authority and the reading
	// on the other side is agnostic (`member_identity_test.ts`).
	//
	// Pinned exactly, because they are what a reader sees. Changing one is a
	// product decision and should fail here first.
	const at = (phase: "rooms" | "connecting" | "linked" | "failed") =>
		ircSeatWords({ network: "Libera", phase, nick: "alice_irc" });
	assertEquals(at("rooms"), { badge: "ROOMS", said: "Rooms only" });
	assertEquals(at("connecting"), { badge: "LINKING", said: "Linking Libera as alice_irc" });
	assertEquals(at("linked"), { badge: "LINKED", said: "Rooms + Libera as alice_irc" });
	assertEquals(at("failed"), { badge: "FAILED", said: "Libera link failed as alice_irc" });

	// Both fit the bounds a room admits them under, so the bridge cannot write a
	// badge its own wire would refuse.
	for (const phase of ["rooms", "connecting", "linked", "failed"] as const) {
		const words = at(phase);
		assertEquals(words.badge.length > 0 && words.badge.length <= MAX_SEAT_BADGE, true);
		assertEquals(words.said.length > 0 && words.said.length <= MAX_SEAT_SAID, true);
	}
});
