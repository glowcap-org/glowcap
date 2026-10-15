// The Rooms IRC server carries independent client sessions, rooms, and direct messages across supported transports.
import { type Behavior } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import { Reachability } from "@glowcap/iroh";
import { DirectMessage, Directory, Room } from "../../lib/room/client.ts";
import { inboxPublisher } from "../../lib/dm_inbox.ts";
import { DM } from "../../lib/protocol.ts";
import { dial, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { startServer } from "../support/installed_server.ts";
import { within } from "../support/rooms_server.ts";
import { startIrcServer } from "./server_process.ts";
import { encodeIrc, type IrcMessage, readIrcLines } from "../../irc/protocol.ts";
import { assertEquals } from "../assert.ts";

const ROOMS_NICK = "rooms";

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
		const next = await within(lines.next(), what);
		if (next.done) throw new Error(`IRC socket ended while waiting for ${what}`);
		if (match(next.value)) return next.value;
		if (["400", "432", "433"].includes(next.value.command)) {
			throw new Error(`IRC refused ${what}: ${next.value.command} ${next.value.params.join(" ")}`);
		}
	}
	throw new Error(`timed out waiting for ${what}`);
}

async function nextRoomLine(room: Room, from: string, text: string): Promise<void> {
	const reader = room.messages.getReader();
	try {
		while (true) {
			const next = await within(reader.read(), `${from}: ${text}`);
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
	name: "the IRC server is the Rooms authority for channels and introduced direct messages",
	sanitizeOps: false,
	sanitizeResources: false,
	fn: async () => {
		const server = await startServer();
		await using _serverOwner = { [Symbol.asyncDispose]: () => server.close() };
		const roomLocator = server.locator;

		const roomsRuntime = await openRoomsRuntime();
		const roomsDir = await Directory.connect(roomLocator, (locator) => dial(locator, roomsRuntime));
		const roomsRoom = await Room.subscribe(roomsDir.session, await roomsDir.open("general"), ROOMS_NICK);
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
		await bobDir.register("bob", bobEndpoint.uri, { onMintInboxFor: bobOfferer.offer });

		await using ircServer = await startIrcServer(roomLocator);
		const irc = await Deno.connect({ hostname: "127.0.0.1", port: ircServer.port });
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
			assertEquals(roster.filter((name) => !name.startsWith("rooms-")).sort(), ["alice", "bob", ROOMS_NICK]);
			const projected = roster.find((name) => name.startsWith("rooms-"));
			assertEquals(projected !== undefined, true, "the Unicode nickname had no IRC projection");
			await writeAll(irc, encodeIrc("NAMES", ["#general"]));
			await nextMatching(lines, (line) => line.command === "353", "explicit NAMES");
			await nextMatching(lines, (line) => line.command === "366", "end of explicit NAMES");
			await writeAll(irc, encodeIrc("NICK", ["renamed"]));
			await nextMatching(lines, (line) => line.command === "438", "non-atomic nickname change refusal");

			await roomsRoom.say("hello from Rooms").then((posted) => posted?.release());
			const inbound = await nextMatching(
				lines,
				(line) => line.command === "PRIVMSG" && line.params[0] === "#general",
				"Rooms channel message",
			);
			assertEquals(inbound.params, ["#general", "hello from Rooms"]);
			assertEquals(inbound.prefix?.startsWith(`${ROOMS_NICK}!rooms@`), true, "channel attribution");
			await unicodeRoom.say("bonjour from Rooms").then((posted) => posted?.release());
			const projectedLine = await nextMatching(
				lines,
				(line) => line.command === "PRIVMSG" && line.params[1] === "bonjour from Rooms",
				"projected Unicode nickname",
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

			await roomsRoom.say("x".repeat(600)).then((posted) => posted?.release());
			const omitted = await nextMatching(
				lines,
				(line) => line.command === "NOTICE" && line.params[1]?.includes("600-byte message"),
				"overlong line notice",
			);
			assertEquals(omitted.params[1]?.includes("could not fit one IRC line"), true);

			await writeAll(irc, encodeIrc("PRIVMSG", ["#general", "hello from IRC"]));
			await nextRoomLine(roomsRoom, "alice", "hello from IRC");

			await roomsRoom.setTopic("capabilities, not channel modes");
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
				throw new Error(`Bob could not open the line toward the IRC server: ${error}`, { cause: error });
			}
			await bobToAlice.say("private toward IRC").then((posted) => posted?.release());
			const direct = await nextMatching(
				lines,
				(line) =>
					line.command === "PRIVMSG" && line.params[0] === "alice" && line.params[1] === "private toward IRC",
				"introduced direct message toward IRC",
			);
			assertEquals(direct.prefix?.startsWith("bob!rooms@"), true, "direct attribution");

			await writeAll(irc, encodeIrc("PING", ["clock"]));
			const pong = await nextMatching(lines, (line) => line.command === "PONG", "PONG");
			assertEquals(pong.params, ["clock"]);
			await writeAll(irc, encodeIrc("PART", ["#general", "done"]));
			await nextMatching(lines, (line) => line.command === "PART" && line.params[0] === "#general", "own PART");
			await writeAll(irc, encodeIrc("QUIT", ["done"]));
			while (!(await within(lines.next(), "IRC disconnect")).done) { /* drain final protocol output */ }
			const again = await Deno.connect({ hostname: "127.0.0.1", port: ircServer.port });
			try {
				const nextLines = readIrcLines(again.readable)[Symbol.asyncIterator]();
				await writeAll(again, encodeIrc("NICK", ["alice"]));
				await writeAll(again, encodeIrc("USER", ["alice", "0", "*", "Alice again"]));
				await nextMatching(nextLines, (line) => line.command === "001", "immediate name reuse");
				let stale = "";
				try {
					await bobToAlice.say("stale inbox must not reach the new client");
				} catch (error) {
					stale = String(error);
				}
				assertEquals(stale.includes("direct-not-accepted"), true, stale);
				const fresh = await DirectMessage.open(bobDir, "alice");
				await fresh.say("fresh authority").then((posted) => posted?.release());
				await nextMatching(
					nextLines,
					(line) => line.command === "PRIVMSG" && line.params[1] === "fresh authority",
					"fresh inbox after reconnect",
				);
				await fresh.close();
			} finally {
				try {
					again.close();
				} catch { /* the IRC server closed first */ }
			}
			await bobToAlice.close();
		} finally {
			try {
				irc.close();
			} catch { /* the IRC server closed first */ }
		}

		await ircServer.close();
		await bobRoom.leave();
		await unicodeRoom.leave();
		await roomsRoom.leave();
		await bobDir.close();
		await unicodeDir.close();
		await roomsDir.close();
		bobEndpoint.close();
		await bobRuntime.close();
		await unicodeRuntime.close();
		await roomsRuntime.close();
		await bobAccepting;
	},
});

for (const [directoryTransport, inboxTransport] of [["tcp", "noise"], ["iroh", "iroh"], ["tcp", "tcp"]] as const) {
	Deno.test(`TLS IRC clients hold independent sessions and multiple rooms (${directoryTransport}/${inboxTransport})`, async () => {
		const server = await startServer(
			directoryTransport === "iroh"
				? ["--transport=iroh", "--reachability=direct"]
				: ["--transport=tcp", "--port=0"],
		);
		await using _serverOwner = { [Symbol.asyncDispose]: () => server.close() };
		await using runtime = await openRoomsRuntime(
			directoryTransport === "iroh" ? { iroh: { reachability: Reachability.Direct } } : {},
		);
		const directory = await Directory.connect(server.locator, (locator) => dial(locator, runtime));
		await directory.open("one");
		await directory.open("two");
		await using ircServer = await startIrcServer(server.locator, [
			`--dm-transport=${inboxTransport}`,
			"--tls-cert=test/net/fixtures/tls_server.pem",
			"--tls-key=test/net/fixtures/tls_server.key",
		]);
		const root = await Deno.readTextFile("test/net/fixtures/tls_root.pem");
		const alice = await Deno.connectTls({ hostname: "localhost", port: ircServer.port, caCerts: [root] });
		const bob = await Deno.connectTls({ hostname: "localhost", port: ircServer.port, caCerts: [root] });
		const aliceLines = readIrcLines(alice.readable)[Symbol.asyncIterator]();
		const bobLines = readIrcLines(bob.readable)[Symbol.asyncIterator]();
		try {
			for (const [socket, lines, nick] of [[alice, aliceLines, "alice"], [bob, bobLines, "[bob]"]] as const) {
				await writeAll(socket, encodeIrc("NICK", [nick]));
				await writeAll(socket, encodeIrc("USER", [nick, "0", "*", nick]));
				await nextMatching(lines, (line) => line.command === "001", `${nick} TLS registration`);
			}
			const collision = await Deno.connectTls({ hostname: "localhost", port: ircServer.port, caCerts: [root] });
			try {
				const refused = readIrcLines(collision.readable)[Symbol.asyncIterator]();
				await writeAll(collision, encodeIrc("NICK", ["{bob}"]));
				await writeAll(collision, encodeIrc("USER", ["bob", "0", "*", "Bob"]));
				await nextMatching(refused, (line) => line.command === "433", "IRC casemapping collision refusal");
			} finally {
				try {
					collision.close();
				} catch { /* refusal ended the socket */ }
			}
			await writeAll(alice, encodeIrc("JOIN", ["#one,#two"]));
			await nextMatching(
				aliceLines,
				(line) => line.command === "366" && line.params[1] === "#two",
				"Alice in both rooms",
			);
			await writeAll(bob, encodeIrc("JOIN", ["#two"]));
			const names = await nextMatching(
				bobLines,
				(line) => line.command === "353",
				"Bob's independent membership",
			);
			assertEquals(names.params.at(-1)?.split(" ").sort(), ["[bob]", "alice"]);
			await writeAll(bob, encodeIrc("PRIVMSG", ["#two", "hello sibling"]));
			const received = await nextMatching(aliceLines, (line) => line.command === "PRIVMSG", "sibling traffic");
			assertEquals(received.params, ["#two", "hello sibling"]);
			assertEquals(received.prefix?.startsWith("[bob]!"), true);
			await writeAll(alice, encodeIrc("PRIVMSG", ["[bob]", "private sibling"]));
			const privateLine = await nextMatching(
				bobLines,
				(line) => line.command === "PRIVMSG" && line.params[0] === "[bob]",
				"sibling DM",
			);
			assertEquals(privateLine.params, ["[bob]", "private sibling"]);
			await writeAll(bob, encodeIrc("PRIVMSG", ["alice", "private reply"]));
			const reply = await nextMatching(
				aliceLines,
				(line) => line.command === "PRIVMSG" && line.params[0] === "alice",
				"sibling DM reply",
			);
			assertEquals(reply.params, ["alice", "private reply"]);
			await writeAll(bob, encodeIrc("PART", ["#two"]));
			await nextMatching(bobLines, (line) => line.command === "PART", "Bob's departure");
			await writeAll(bob, encodeIrc("QUIT"));
			await writeAll(alice, encodeIrc("LIST"));
			const counts = new Map<string, string>();
			while (true) {
				const row = await nextMatching(
					aliceLines,
					(line) => line.command === "322" || line.command === "323",
					"counted room list",
				);
				if (row.command === "323") break;
				counts.set(row.params[1], row.params[2]);
			}
			assertEquals([...counts.entries()].sort(), [["#one", "1"], ["#two", "1"]]);
			await writeAll(alice, encodeIrc("PING", ["still here"]));
			await nextMatching(aliceLines, (line) => line.command === "PONG", "surviving client");
		} finally {
			for (const conn of [alice, bob]) {
				try {
					conn.close();
				} catch { /* QUIT already closed */ }
			}
			await directory.close();
		}
	});
}
