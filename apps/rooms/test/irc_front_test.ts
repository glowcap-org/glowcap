import { type Behavior, type Host } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import { DirectMessage, Directory, Room } from "../lib/room_client.ts";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { DM } from "../lib/protocol.ts";
import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { serveDirectory } from "../server/main.ts";
import { serveIrcFront } from "../irc/front.ts";
import { frontInboxRouter } from "../irc/front/inbox.ts";
import { encodeIrc, type IrcMessage, readIrcLines } from "../irc/protocol.ts";
import { assertEquals } from "./assert.ts";

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) {
		const wrote = await conn.write(bytes.subarray(offset));
		if (wrote === 0) throw new Error("fixture socket accepted a zero-byte write");
		offset += wrote;
	}
}

async function nextMatching(
	lines: AsyncIterator<IrcMessage>,
	match: (message: IrcMessage) => boolean,
	what: string,
): Promise<IrcMessage> {
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const next = await Promise.race([
			lines.next(),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), 10_000)
			),
		]);
		if (next.done) throw new Error(`IRC socket ended while waiting for ${what}`);
		if (match(next.value)) return next.value;
	}
	throw new Error(`timed out waiting for ${what}`);
}

async function nextRoomLine(room: Room, from: string, text: string): Promise<void> {
	const reader = room.messages.getReader();
	try {
		while (true) {
			const next = await Promise.race([
				reader.read(),
				new Promise<never>((_, reject) =>
					setTimeout(() => reject(new Error(`timed out waiting for ${from}: ${text}`)), 10_000)
				),
			]);
			if (next.done) throw new Error(`room ended while waiting for ${from}: ${text}`);
			if (next.value.from === from && next.value.text === text) return;
		}
	} finally {
		reader.releaseLock();
	}
}

function acceptDirect(server: AsyncIterable<{ serve(): Promise<void> }>): Promise<void> {
	return (async () => {
		for await (const session of server) {
			void session.serve().catch((error) => console.error("direct fixture session:", error));
		}
	})();
}

Deno.test({
	name: "the IRC front is native Rooms authority for channels and introduced direct messages",
	sanitizeOps: false,
	sanitizeResources: false,
	fn: async () => {
		const roomServer = await roomsListen("127.0.0.1", 0);
		const roomLocator = loopbackTcpDesignator(roomServer.port);
		const roomServing = serveDirectory(roomServer.host, roomServer);

		const nativeRuntime = await openRoomsRuntime();
		const nativeDir = await Directory.connect(roomLocator, (locator) => dial(locator, nativeRuntime));
		const nativeRoom = await Room.subscribe(nativeDir.session, await nativeDir.open("general"), "native");
		const unicodeRuntime = await openRoomsRuntime();
		const unicodeDir = await Directory.connect(roomLocator, (locator) => dial(locator, unicodeRuntime));
		const unicodeRoom = await Room.subscribe(unicodeDir.session, await unicodeDir.enter("general"), "élise");

		const bobHost = roomsHost();
		const bobEndpoint = await tcp.noise.listen("127.0.0.1", 0, { host: bobHost });
		const bobAccepting = acceptDirect(bobEndpoint);
		const bobRuntime = await openRoomsRuntime({ host: bobHost });
		const bobDir = await Directory.connect(roomLocator, (locator) => dial(locator, bobRuntime));
		const bobRoom = await Room.subscribe(bobDir.session, await bobDir.enter("general"), "bob");
		const bobInbox: { from: string; text: string }[] = [];
		const bobBehavior = (peer: string): Behavior => (verb, args) => {
			if (verb !== DM) throw new Error(`dm has no method ${verb}`);
			bobInbox.push({ from: peer, text: typeof args[0] === "string" ? args[0] : "" });
			return null;
		};
		const bobOfferer = inboxPublisher(bobHost).offerer({
			dir: () => bobDir,
			behaviorFor: bobBehavior,
		});
		await bobDir.register("bob", bobEndpoint.uri, bobOfferer.offer);

		// The front deliberately uses the interoperability floor. Its Directory,
		// room callbacks, registrations, and DM handoffs therefore prove the same
		// v1.0/Syrup profile Goblins peers consume.
		const frontHost: Host = roomsHost(undefined, "v1-syrup");
		const frontDm = await tcp.noise.listen("127.0.0.1", 0, { host: frontHost });
		const frontAccepting = acceptDirect(frontDm);
		const frontRuntime = await openRoomsRuntime({ host: frontHost });
		const ircListener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
		const frontServing = (async () => {
			const accepted = await ircListener.accept();
			ircListener.close();
			await serveIrcFront(accepted, {
				directory: roomLocator,
				dial: (locator) => dial(locator, frontRuntime),
				dmLocator: frontDm.uri,
				inboxRouter: frontInboxRouter(frontHost),
				serverName: "rooms.test",
			});
		})();

		const irc = await Deno.connect({ hostname: "127.0.0.1", port: ircListener.addr.port });
		const lines = readIrcLines(irc.readable)[Symbol.asyncIterator]();
		try {
			await writeAll(irc, encodeIrc("CAP", ["LS", "302"]));
			await writeAll(irc, encodeIrc("NICK", ["alice"]));
			await writeAll(irc, encodeIrc("USER", ["alice", "0", "*", "Alice via IRC"]));
			await nextMatching(lines, (line) => line.command === "CAP" && line.params[1] === "LS", "CAP LS");
			await writeAll(irc, encodeIrc("CAP", ["END"]));
			await nextMatching(lines, (line) => line.command === "001", "welcome");
			await nextMatching(lines, (line) => line.command === "376", "end of MOTD");

			await writeAll(irc, encodeIrc("JOIN", ["#general"]));
			await nextMatching(lines, (line) => line.command === "JOIN" && line.params[0] === "#general", "own JOIN");
			const names = await nextMatching(lines, (line) => line.command === "353", "NAMES roster");
			const roster = names.params.at(-1)?.split(" ").sort() ?? [];
			assertEquals(roster.filter((name) => !name.startsWith("rooms-")).sort(), ["alice", "bob", "native"]);
			const projected = roster.find((name) => name.startsWith("rooms-"));
			assertEquals(projected !== undefined, true, "the native Unicode nickname had no IRC projection");
			await writeAll(irc, encodeIrc("NAMES", ["#general"]));
			await nextMatching(lines, (line) => line.command === "353", "explicit NAMES");
			await nextMatching(lines, (line) => line.command === "366", "end of explicit NAMES");
			await writeAll(irc, encodeIrc("NICK", ["renamed"]));
			await nextMatching(lines, (line) => line.command === "438", "non-atomic nickname change refusal");

			await nativeRoom.say("hello from Rooms").then((posted) => posted?.release());
			const inbound = await nextMatching(
				lines,
				(line) => line.command === "PRIVMSG" && line.params[0] === "#general",
				"Rooms channel message",
			);
			assertEquals(inbound.params, ["#general", "hello from Rooms"]);
			assertEquals(inbound.prefix?.startsWith("native!rooms@"), true, "channel attribution");
			await unicodeRoom.say("bonjour from Rooms").then((posted) => posted?.release());
			const projectedLine = await nextMatching(
				lines,
				(line) => line.command === "PRIVMSG" && line.params[1] === "bonjour from Rooms",
				"projected native nickname",
			);
			assertEquals(projectedLine.prefix?.startsWith(`${projected}!rooms@`), true, "projected attribution");
			await writeAll(irc, encodeIrc("WHOIS", [projected!]));
			const projectedWhois = await nextMatching(
				lines,
				(line) => line.command === "311" && line.params[1] === projected,
				"WHOIS projected nickname",
			);
			assertEquals(projectedWhois.params.at(-1), "élise");
			await nextMatching(lines, (line) => line.command === "318", "end of projected WHOIS");

			await nativeRoom.say("x".repeat(600)).then((posted) => posted?.release());
			const omitted = await nextMatching(
				lines,
				(line) => line.command === "NOTICE" && line.params[1]?.includes("600-byte message"),
				"overlong line notice",
			);
			assertEquals(omitted.params[1]?.includes("could not fit one IRC line"), true);

			await writeAll(irc, encodeIrc("PRIVMSG", ["#general", "hello from IRC"]));
			await nextRoomLine(nativeRoom, "alice", "hello from IRC");

			await nativeRoom.setTopic("capabilities, not channel modes");
			const topic = await nextMatching(lines, (line) => line.command === "TOPIC", "topic change");
			assertEquals(topic.params, ["#general", "capabilities, not channel modes"]);
			await writeAll(irc, encodeIrc("TOPIC", ["#general", "held through a topic capability"]));
			const changed = await nextMatching(
				lines,
				(line) => line.command === "TOPIC" && line.params[1] === "held through a topic capability",
				"topic capability result",
			);
			assertEquals(changed.params[0], "#general");
			await writeAll(irc, encodeIrc("TOPIC", ["#general"]));
			await nextMatching(lines, (line) => line.command === "332", "topic query");

			await writeAll(irc, encodeIrc("LIST"));
			const listed = await nextMatching(lines, (line) => line.command === "322", "room list");
			assertEquals(listed.params[1], "#general");
			await nextMatching(lines, (line) => line.command === "323", "end of LIST");
			await writeAll(irc, encodeIrc("WHOIS", ["bob"]));
			await nextMatching(
				lines,
				(line) => line.command === "311" && line.params[1] === "bob",
				"WHOIS roster proof",
			);
			await nextMatching(lines, (line) => line.command === "318", "end of WHOIS");

			await writeAll(irc, encodeIrc("PRIVMSG", ["bob", "private from IRC"]));
			const bobDeadline = Date.now() + 10_000;
			while (!bobInbox.some((message) => message.from === "alice" && message.text === "private from IRC")) {
				if (Date.now() >= bobDeadline) throw new Error("Bob did not receive the introduced IRC direct message");
				await new Promise((resolve) => setTimeout(resolve, 10));
			}

			let bobToAlice: DirectMessage;
			try {
				bobToAlice = await DirectMessage.open(bobDir, "alice");
			} catch (error) {
				throw new Error(`Bob could not open the line toward the IRC front: ${error}`, { cause: error });
			}
			await bobToAlice.say("private toward IRC").then((posted) => posted?.release());
			const direct = await nextMatching(
				lines,
				(line) =>
					line.command === "PRIVMSG" && line.params[0] === "alice" && line.params[1] === "private toward IRC",
				"introduced direct message toward IRC",
			);
			assertEquals(direct.prefix?.startsWith("bob!rooms@"), true, "direct attribution");
			await bobToAlice.close();

			await writeAll(irc, encodeIrc("PING", ["clock"]));
			const pong = await nextMatching(lines, (line) => line.command === "PONG", "PONG");
			assertEquals(pong.params, ["clock"]);
			await writeAll(irc, encodeIrc("PART", ["#general", "done"]));
			await nextMatching(lines, (line) => line.command === "PART" && line.params[0] === "#general", "own PART");
			await writeAll(irc, encodeIrc("QUIT", ["done"]));
		} finally {
			try {
				irc.close();
			} catch { /* front closed first */ }
		}

		await frontServing;
		await bobRoom.leave();
		await unicodeRoom.leave();
		await nativeRoom.leave();
		await bobDir.close();
		await unicodeDir.close();
		await nativeDir.close();
		frontDm.close();
		bobEndpoint.close();
		roomServer.close();
		await frontRuntime.close();
		await bobRuntime.close();
		await unicodeRuntime.close();
		await nativeRuntime.close();
		await Promise.allSettled([frontAccepting, bobAccepting, roomServing]);
	},
});
