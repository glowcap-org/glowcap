// The IRC gateway: channels bridged into the directory on an operator's say.
//
// Holding the gateway capability, joinIrc stands an IRC channel beside the
// native rooms — entered and listed like any of them, IRC members appearing
// as irc/<nick> — and partIrc takes it down, room and all. The IRC side is a
// scripted fixture, so the whole conversation is hermetic.

import { DIRECTORY, JOIN_IRC, LIST, PART_IRC, SNAPSHOT } from "../lib/protocol.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { Room } from "../lib/room_client.ts";
import { directoryBehavior } from "../server/directory_behavior.ts";
import { ircGatewayBehavior } from "../server/irc_gateway.ts";
import { readIrcLines } from "../irc/protocol.ts";
import { assert, dial, enterOrOpen, nextMessage, roomsTest, within } from "./support/rooms_server.ts";

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

const say = (line: string) => new TextEncoder().encode(line + "\r\n");

roomsTest("the gateway bridges a fixture channel in and parts it again", async () => {
	const ircListener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const ircPort = (ircListener.addr as Deno.NetAddr).port;
	let feed!: () => void;
	const feedReady = new Promise<void>((resolve) => {
		feed = resolve;
	});
	let readerSpoke!: () => void;
	const readerSpokeOnIrc = new Promise<void>((resolve) => {
		readerSpoke = resolve;
	});
	let readerActed!: () => void;
	const readerActedOnIrc = new Promise<void>((resolve) => {
		readerActed = resolve;
	});
	let feedAgain!: () => void;
	const feedMoreReady = new Promise<void>((resolve) => {
		feedAgain = resolve;
	});
	let feedEcho!: () => void;
	const feedEchoReady = new Promise<void>((resolve) => {
		feedEcho = resolve;
	});
	let dropSeat!: () => void;
	const dropSeatReady = new Promise<void>((resolve) => {
		dropSeat = resolve;
	});
	let renameCue!: () => void;
	const renameReady = new Promise<void>((resolve) => {
		renameCue = resolve;
	});

	// One accept order, not a race: the shared feed connects first (join
	// starts it), the reader's own connection second (subscribing starts it).
	const firstConn = ircListener.accept();
	const secondConn = firstConn.then(() => {
		const next = ircListener.accept();
		void next.finally(() => ircListener.close());
		return next;
	});

	// The reader's own connection: the member registers under their nick,
	// joins, and their post arrives as them.
	const readerFixture = (async () => {
		const conn = await secondConn;
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			const nickLine = (await lines.next()).value;
			assert(nickLine?.command === "NICK" && nickLine.params[0] === "reader", "the reader registers as themself");
			assert((await lines.next()).value?.command === "USER", "then their user line");
			await writeAll(conn, say(":fixture 001 reader :welcome"));
			const join = (await lines.next()).value;
			assert(join?.command === "JOIN" && join.params[0] === "#news", "the reader joins the channel");
			await writeAll(conn, say(":reader!u@example JOIN :#news"));
			const said = (await lines.next()).value;
			assert(
				said?.command === "PRIVMSG" && said.params[0] === "#news" && said.params[1] === "hi from rooms",
				"the member's line reaches IRC as them",
			);
			readerSpoke();
			// The member's /me crosses as the CTCP ACTION it is, and stepping
			// away rides IRC's own AWAY.
			const acted = (await lines.next()).value;
			assert(
				acted?.command === "PRIVMSG" && acted.params[1] === "\u0001ACTION waves\u0001",
				`the action crossed as ${JSON.stringify(acted?.params)}`,
			);
			const away = (await lines.next()).value;
			assert(
				away?.command === "AWAY" && away.params[0] === "lunch",
				`away crossed as ${JSON.stringify(away?.params)}`,
			);
			readerActed();
			// Services force-rename the reader mid-session; the link stays up
			// under the new name and the gateway is told. On cue, so the note
			// cannot land in the stream before the scenes ahead of it.
			await renameReady;
			await writeAll(conn, say(":reader!u@example NICK :Guest1234"));
			// On cue, the network drops the seat: the member hears about it in
			// the room rather than in a server log.
			await dropSeatReady;
			conn.close();
			return;
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	// The scripted IRC side: registration, the join echo, a roster, then one
	// held line released only once the Rooms reader is seated to hear it.
	const fixture = (async () => {
		const conn = await firstConn;
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			assert((await lines.next()).value?.command === "NICK", "the gateway registers a nick first");
			assert((await lines.next()).value?.command === "USER", "then its user line");
			await writeAll(conn, say(":fixture 001 gwbot :welcome"));
			const join = (await lines.next()).value;
			assert(join?.command === "JOIN" && join.params[0] === "#news", "the gateway joins its channel");
			await writeAll(conn, say(":gwbot!u@example JOIN :#news"));
			await writeAll(conn, say(":fixture 353 gwbot = #news :gwbot @alice"));
			await writeAll(conn, say(":fixture 366 gwbot #news :end of names"));
			await feedReady;
			await writeAll(conn, say(":alice!u@example PRIVMSG #news :hello from IRC"));
			await feedMoreReady;
			await writeAll(conn, say(":alice!u@example PRIVMSG #news :\u0001ACTION dances\u0001"));
			await writeAll(conn, say(":alice!u@example TOPIC #news :ship day"));
			// The feed hears the reader's own citizenship back from the
			// channel: their join, a roster refresh naming them, their line.
			// None of it may echo into the room as a second irc/ identity.
			await feedEchoReady;
			await writeAll(conn, say(":reader!u@example JOIN :#news"));
			await writeAll(conn, say(":fixture 353 gwbot = #news :gwbot @alice reader"));
			await writeAll(conn, say(":fixture 366 gwbot #news :end of names"));
			await writeAll(conn, say(":reader!u@example PRIVMSG #news :hi from rooms"));
			await writeAll(conn, say(":alice!u@example PRIVMSG #news :first marker"));
			// After the rename the suppression follows the live nick.
			await writeAll(conn, say(":Guest1234!u@example JOIN :#news"));
			await writeAll(conn, say(":Guest1234!u@example PRIVMSG #news :hi from rooms"));
			await writeAll(conn, say(":alice!u@example PRIVMSG #news :second marker"));
			// Hold the connection until the gateway closes it at part.
			for await (const _ of lines) { /* drain */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish(DIRECTORY, directoryBehavior());
			session.publish("gw", ircGatewayBehavior());
			void session.serve().catch(() => {});
		}
	})();

	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const gw = await session.fetch("gw");
		const name = await within(
			session.send(gw, JOIN_IRC, ["fixture", "#news", "127.0.0.1", BigInt(ircPort), false, "gwbot"]),
			"the join answer",
		);
		assert(name === "fixture/#news", `joinIrc answered ${String(name)}`);

		const roomRef = await within(enterOrOpen(session, "fixture/#news"), "entering the bridged room");
		const room = await within(Room.subscribe(session, roomRef, "reader"), "subscribing");
		feed();
		const line = await nextMessage(room, (message) => message.text.includes("hello from IRC"));
		assert(line.from === "irc/alice", `the IRC line arrived from ${line.from}`);

		// The member speaks and IRC hears them under their own nick, before
		// the room echoes the line.
		await within(room.say("hi from rooms"), "the member's own line");
		await within(readerSpokeOnIrc, "the reader's line on IRC");

		// The rooms-side command vocabulary maps onto the channel: /me is a
		// CTCP ACTION, away is AWAY, and both echo in the room natively.
		await within(room.say("/me waves"), "the member's action");
		await within(room.away("lunch"), "stepping away");
		await within(readerActedOnIrc, "the action and away on IRC");
		const awayLine = await nextMessage(room, (message) => message.text === "reader is away: lunch");
		assert(awayLine.from === "room", `the away line spoke as ${awayLine.from}`);

		// And the channel's own vocabulary maps back: an IRC action arrives
		// as the /me form every rooms client draws, a topic as the room's.
		feedAgain();
		const danced = await nextMessage(room, (message) => message.text === "/me dances");
		assert(danced.from === "irc/alice", `the action arrived from ${danced.from}`);
		await nextMessage(room, (message) => message.text === "the topic is: ship day");

		// A services rename reaches the member as a room line. Awaited before
		// the echo burst: the stream reader discards what it scans past.
		renameCue();
		await nextMessage(room, (message) => message.text.includes("on IRC you are now <Guest1234>"));

		// The member's own channel echo never comes back as a second member
		// or a second message: the next thing the room hears after the echo
		// burst is alice, not irc/reader.
		feedEcho();
		const afterEcho = await nextMessage(
			room,
			(message) => message.from.startsWith("irc/") || message.from === "reader",
		);
		assert(
			afterEcho.from === "irc/alice" && afterEcho.text === "first marker",
			`the reader's echo leaked back as ${afterEcho.from}: "${afterEcho.text}"`,
		);

		// After the rename the suppression follows the live name.
		const afterRename = await nextMessage(
			room,
			(message) => message.from.startsWith("irc/") || message.from === "reader",
		);
		assert(
			afterRename.from === "irc/alice" && afterRename.text === "second marker",
			`the renamed echo leaked back as ${afterRename.from}: "${afterRename.text}"`,
		);

		// The seat dropping is told to the member where they speak.
		dropSeat();
		await nextMessage(room, (message) => message.text.includes("your IRC seat ended"));

		// Their own registered account is refused on a cleartext bridge: the
		// custody rule is the same as the feed's, stated at the seat.
		let refusedAccount = "";
		try {
			await within(room.ircAccount("acct", "pw"), "the cleartext account refusal");
		} catch (error) {
			refusedAccount = error instanceof Error ? error.message : String(error);
		}
		assert(
			refusedAccount.includes("TLS") || refusedAccount.includes("encrypted"),
			`a cleartext bridge took a member's account: "${refusedAccount}"`,
		);

		const rows = await within(session.send(gw, SNAPSHOT, []), "the gateway snapshot") as unknown[];
		assert(Array.isArray(rows) && rows.length === 1, "the snapshot lists the one bridged channel");
		const row = rows[0] as unknown[];
		assert(row[0] === "fixture" && row[1] === "#news" && row[2] === "fixture/#news", "the row names it");

		await within(session.send(gw, PART_IRC, ["fixture", "#news"]), "the part answer");
		const listed = await within(
			session.send(session.fetch ? await session.fetch(DIRECTORY) : gw, LIST, []),
			"the list",
		) as unknown[];
		assert(
			!JSON.stringify(listed).includes("fixture/#news"),
			"a parted channel still stands in the directory list",
		);
	} finally {
		// Backstops: a scene that failed above must not park the fixtures on
		// their cues and turn one assertion into a hang.
		renameCue();
		dropSeat();
		feedEcho();
		feed();
		feedAgain();
		await session.close().catch(() => {});
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([fixture, readerFixture, serving]);
	}
});

roomsTest("a registered account is refused over cleartext, and validated", async () => {
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish("gw", ircGatewayBehavior());
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const gw = await session.fetch("gw");
		// The wire flow itself is the bridge suite's to prove; what the verb
		// owns is custody policy: no password rides a cleartext socket, and
		// malformed credentials are refused before any dial.
		let refused = "";
		try {
			await within(
				session.send(gw, JOIN_IRC, ["net2", "#reg", "127.0.0.1", 6667n, false, "gwbot", "acct", "pw"]),
				"the cleartext refusal",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("TLS"), `sasl over cleartext was not refused for TLS: "${refused}"`);
		refused = "";
		try {
			await within(
				session.send(gw, JOIN_IRC, ["net2", "#reg", "127.0.0.1", 6697n, true, "gwbot", "acct", ""]),
				"the malformed-credential refusal",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused !== "", "an account with no password was not refused");
	} finally {
		await session.close().catch(() => {});
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([serving]);
	}
});
