// The IRC gateway: channels bridged into the directory on an operator's say.
//
// Holding the gateway capability, joinIrc stands an IRC channel beside the
// native rooms — entered and listed like any of them, IRC members appearing
// as irc/<nick> — and partIrc takes it down, room and all. The IRC side is a
// scripted fixture, so the whole conversation is hermetic.

import { DIRECTORY, LIST, SNAPSHOT } from "../../lib/protocol.ts";
import { parseBridgeGateway } from "../../lib/bridge/gateway.ts";
import { joinIrcChannel, openIrcNetwork, partIrcChannel } from "./irc_gateway/wire.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { Room } from "../../lib/room/client.ts";
import {
	IRC_ACCOUNT_FIELD,
	IRC_DISCONNECT_ACTION,
	IRC_LINK_ACTION,
	IRC_NICK_FIELD,
	IRC_PASSWORD_FIELD,
} from "../../irc/bridge/identity_form.ts";
import { directoryBehavior } from "../../server/directory_behavior.ts";
import { ircGatewayBehavior } from "../../server/irc_gateway_behavior.ts";
import { RoomServerOperationsState } from "../../server/operations_state.ts";
import { readIrcLines } from "../../irc/protocol.ts";
import { ircNickRenameRefusal } from "../../irc/bridge/identity.ts";
import { registerSaslReader, say, writeAll } from "./irc_gateway/fixture.ts";
import { assert, dial, enterOrOpen, nextMessage, roomsTest, within } from "../support/rooms_server.ts";
import { RoomServer } from "../../server/room_server.ts";

Deno.test("an IRC identity refuses a service-forced guest nick", () => {
	assert(ircNickRenameRefusal("Chosen", "cHOSEN") === null, "IRC case mapping changed an equivalent nick");
	assert(
		ircNickRenameRefusal("Chosen", "Guest1234")?.includes("registered account") === true,
		"a service-forced guest nick was accepted as the Rooms identity",
	);
});

roomsTest("the gateway bridges a fixture channel in and parts it again", async () => {
	const roomServer = new RoomServer();
	const operations = await RoomServerOperationsState.open(null);
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
	const secondConn = firstConn.then(() => ircListener.accept());

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
			// The member's /me crosses as the CTCP ACTION it is. Rooms standing
			// stays room-scoped; IRC AWAY would affect every joined channel.
			const acted = (await lines.next()).value;
			assert(
				acted?.command === "PRIVMSG" && acted.params[1] === "\u0001ACTION waves\u0001",
				`the action crossed as ${JSON.stringify(acted?.params)}`,
			);
			readerActed();
			// Services force-rename the reader mid-session. That is not the
			// Rooms identity they asked to project, so the gateway closes the
			// seat with an account-login diagnosis.
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
			// Markers after the forced rename prove the failed seat injects
			// neither its old nick nor the unwanted Guest nick into the room.
			await feedEchoReady;
			await writeAll(conn, say(":alice!u@example PRIVMSG #news :first marker"));
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
			session.publish(DIRECTORY, directoryBehavior(roomServer));
			session.publish("gw", ircGatewayBehavior(roomServer, operations));
			void session.serve().catch(() => {});
		}
	})();

	const session = await dial(loopbackTcpDesignator(server.port));
	let witnessSession: Awaited<ReturnType<typeof dial>> | null = null;
	let replacementSession: Awaited<ReturnType<typeof dial>> | null = null;
	try {
		const gw = await session.fetch("gw");
		await openIrcNetwork(session, gw, {
			network: "fixture",
			host: "127.0.0.1",
			port: ircPort,
			tls: false,
			nick: "gwbot",
		});
		const name = await within(
			joinIrcChannel(session, gw, "fixture", "#news"),
			"the join answer",
		);
		assert(name === "fixture/#news", `joinIrc answered ${String(name)}`);
		assert(operations.ircBridges().length === 1, "joining did not commit the IRC bridge intent");

		const roomRef = await within(enterOrOpen(session, "fixture/#news"), "entering the bridged room");
		const room = await within(Room.subscribe(session, roomRef, "reader"), "subscribing");
		await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "reader" &&
				message.presence.state === "rooms",
		);
		await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "reader" &&
				message.presence.state === "linked",
		);
		feed();
		const line = await nextMessage(room, (message) => message.text.includes("hello from IRC"));
		assert(line.from === "irc/alice", `the IRC line arrived from ${line.from}`);

		// The member speaks and IRC hears them under their own nick, before
		// the room echoes the line.
		await within(room.say("hi from rooms"), "the member's own line");
		await within(readerSpokeOnIrc, "the reader's line on IRC");

		// The channel-addressed action crosses IRC. Standing remains a Rooms
		// room fact because IRC AWAY is network-wide rather than channel-scoped.
		await within(room.say("/me waves"), "the member's action");
		await within(room.away("lunch"), "stepping away");
		await within(readerActedOnIrc, "the action on IRC");
		const awayLine = await nextMessage(room, (message) => message.text === "reader is away: lunch");
		assert(awayLine.from === "room", `the away line spoke as ${awayLine.from}`);

		// And the channel's own vocabulary maps back: an IRC action arrives
		// as the /me form every rooms client draws, a topic as the room's.
		feedAgain();
		const danced = await nextMessage(room, (message) => message.text === "/me dances");
		assert(danced.from === "irc/alice", `the action arrived from ${danced.from}`);
		await nextMessage(room, (message) => message.text === "the topic is: ship day");

		// A services rename fails the projected identity instead of silently
		// presenting a Guest nick as success.
		renameCue();
		const renamedSeat = await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "reader" &&
				message.presence.state === "failed",
		);
		assert(renamedSeat.presence?.kind === "seat", "the services rename did not fail the structured seat");
		await nextMessage(
			room,
			(message) =>
				message.text.includes("changed the chosen nick") && message.text.includes("registered account"),
		);

		// Ordinary channel traffic continues after the reader seat failed.
		feedEcho();
		const afterEcho = await nextMessage(
			room,
			(message) => message.from.startsWith("irc/") || message.from === "reader",
		);
		assert(
			afterEcho.from === "irc/alice" && afterEcho.text === "first marker",
			`the reader's echo leaked back as ${afterEcho.from}: "${afterEcho.text}"`,
		);

		// The failed seat injects no echo under the unwanted Guest name.
		const afterRename = await nextMessage(
			room,
			(message) => message.from.startsWith("irc/") || message.from === "reader",
		);
		assert(
			afterRename.from === "irc/alice" && afterRename.text === "second marker",
			`the renamed echo leaked back as ${afterRename.from}: "${afterRename.text}"`,
		);

		// Let the fixture finish its already-closed reader connection.
		dropSeat();

		// Their own registered account is refused on a cleartext bridge: the
		// custody rule is the same as the feed's, stated at the seat.
		let refusedAccount = "";
		try {
			await within(
				room.submitBridgeForm(IRC_LINK_ACTION, {
					[IRC_NICK_FIELD]: "reader",
					[IRC_ACCOUNT_FIELD]: "acct",
					[IRC_PASSWORD_FIELD]: "pw",
				}),
				"the cleartext account refusal",
			);
		} catch (error) {
			refusedAccount = error instanceof Error ? error.message : String(error);
		}
		assert(
			refusedAccount.includes("TLS") || refusedAccount.includes("encrypted"),
			`a cleartext bridge took a member's account: "${refusedAccount}"`,
		);

		await within(room.submitBridgeForm(IRC_DISCONNECT_ACTION, {}), "disconnecting the IRC identity");
		await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "reader" &&
				message.presence.state === "rooms",
		);
		let refusedPost = "";
		try {
			await within(room.say("must stay rooms only"), "the Rooms-only post refusal");
		} catch (error) {
			refusedPost = error instanceof Error ? error.message : String(error);
		}
		assert(
			refusedPost.includes("link your IRC identity"),
			`a Rooms-only member silently reopened IRC: "${refusedPost}"`,
		);

		const gateway = parseBridgeGateway(
			await within(session.send(gw, SNAPSHOT, []), "the gateway snapshot") as string,
		);
		const connection = gateway.connections[0];
		assert(
			gateway.connections.length === 1 && connection?.leases.length === 1,
			"the snapshot lists one network and one channel",
		);
		const lease = connection!.leases[0]!;
		assert(
			connection!.id === "fixture" && lease.id === "#news" && lease.roomName === "fixture/#news",
			"the row names it",
		);

		// Transport closure is the membership boundary too. A witness observes
		// the leave before a fresh connection claims the same Rooms name; if the
		// old IrcBridgeRoom member survived, this subscribe is refused as a
		// duplicate even though its IRC socket is gone.
		witnessSession = await dial(loopbackTcpDesignator(server.port));
		const witnessRef = await within(enterOrOpen(witnessSession, "fixture/#news"), "entering as the witness");
		const witness = await within(Room.subscribe(witnessSession, witnessRef, "witness"), "subscribing the witness");
		await session.close();
		await nextMessage(
			witness,
			(message) => message.presence?.kind === "leave" && message.presence.name === "reader",
		);
		replacementSession = await dial(loopbackTcpDesignator(server.port));
		const replacementRef = await within(
			enterOrOpen(replacementSession, "fixture/#news"),
			"entering after the closed reader",
		);
		await within(
			Room.subscribe(replacementSession, replacementRef, "reader"),
			"reusing the name after transport close",
		);

		const witnessGw = await witnessSession.fetch("gw");
		await within(partIrcChannel(witnessSession, witnessGw, "fixture", "#news"), "the part answer");
		assert(operations.ircBridges().length === 0, "parting retained the IRC bridge intent");
		const listed = await within(
			witnessSession.send(await witnessSession.fetch(DIRECTORY), LIST, []),
			"the list",
		) as unknown[];
		assert(
			!JSON.stringify(listed).includes("fixture/#news"),
			"a parted channel still stands in the directory list",
		);
		let retainedRefusal = "";
		try {
			await within(
				Room.subscribe(replacementSession, replacementRef, "after-part"),
				"the retained room capability refusal",
			);
		} catch (error) {
			retainedRefusal = error instanceof Error ? error.message : String(error);
		}
		assert(
			retainedRefusal.includes("parted"),
			`a retained room capability recreated the parted bridge: "${retainedRefusal}"`,
		);
	} finally {
		// Backstops: a scene that failed above must not park the fixtures on
		// their cues and turn one assertion into a hang.
		renameCue();
		dropSeat();
		feedEcho();
		feed();
		feedAgain();
		await replacementSession?.close().catch(() => {});
		await witnessSession?.close().catch(() => {});
		await session.close().catch(() => {});
		try {
			ircListener.close();
		} catch { /* the failed scene may already have closed it */ }
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([fixture, readerFixture, serving]);
		await roomServer.close();
	}
});

roomsTest("a member's IRC login chooses their wire nick and SASL account", async () => {
	const roomServer = new RoomServer();
	const ircListener = Deno.listenTls({
		hostname: "localhost",
		port: 0,
		cert: await Deno.readTextFile("test/net/fixtures/tls_server.pem"),
		key: await Deno.readTextFile("test/net/fixtures/tls_server.key"),
	});
	const ircPort = (ircListener.addr as Deno.NetAddr).port;
	const feedConn = ircListener.accept();
	const initialReaderConn = feedConn.then(() => ircListener.accept());
	const authenticatedReaderConn = initialReaderConn.then(() => ircListener.accept());
	const collidingReaderConn = authenticatedReaderConn.then(() => ircListener.accept());
	const restoredAfterCollisionConn = collidingReaderConn.then(() => ircListener.accept());
	const refusedReaderConn = restoredAfterCollisionConn.then(() => ircListener.accept());
	const restoredReaderConn = refusedReaderConn.then(() => ircListener.accept());
	let initialReaderRegistered!: () => void;
	const initialReaderReady = new Promise<void>((resolve) => {
		initialReaderRegistered = resolve;
	});

	const feedFixture = (async () => {
		const conn = await feedConn;
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			assert((await lines.next()).value?.command === "NICK", "the login fixture feed registers its nick");
			assert((await lines.next()).value?.command === "USER", "the login fixture feed registers its user");
			await writeAll(conn, say(":fixture 001 gwbot :welcome"));
			assert((await lines.next()).value?.command === "JOIN", "the login fixture feed joins");
			await writeAll(conn, say(":gwbot!u@example JOIN :#login"));
			for await (const _ of lines) { /* drain until part */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const initialReaderFixture = (async () => {
		const conn = await initialReaderConn;
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			const nick = (await lines.next()).value;
			assert(nick?.command === "NICK" && nick.params[0] === "rooms-name", "the initial seat uses the Rooms name");
			assert((await lines.next()).value?.command === "USER", "the initial seat registers its user");
			// Hold registration here. The login must cancel this in-flight attempt
			// before opening the chosen identity, not let it win the seat later.
			initialReaderRegistered();
			for await (const _ of lines) { /* the login cancels this anonymous seat */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const authenticatedReaderFixture = (async () => {
		const conn = await authenticatedReaderConn;
		try {
			const lines = await registerSaslReader(conn, "myircnick", "myircnick", "password", "#login", true);
			const posted = (await lines.next()).value;
			assert(
				posted?.command === "PRIVMSG" && posted.params[0] === "#login" &&
					posted.params[1] === "identity marker",
				"the authenticated seat did not carry the member's line",
			);
			for await (const _ of lines) { /* drain until part */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const collidingReaderFixture = (async () => {
		const conn = await collidingReaderConn;
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			const nick = (await lines.next()).value;
			assert(
				nick?.command === "NICK" && nick.params[0] === "occupiednick",
				"the exact chosen nick was not tried",
			);
			assert((await lines.next()).value?.command === "USER", "the colliding identity registers its user");
			await writeAll(conn, say(":fixture 433 * occupiednick :Nickname is already in use"));
			while (!(await lines.next()).done) { /* refusal closes the candidate */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const restoredAfterCollisionFixture = (async () => {
		const conn = await restoredAfterCollisionConn;
		try {
			const lines = await registerSaslReader(conn, "myircnick", "myircnick", "password", "#login", true);
			const posted = (await lines.next()).value;
			assert(
				posted?.command === "PRIVMSG" && posted.params[0] === "#login" &&
					posted.params[1] === "after collision marker",
				"the identity restored after a nick collision did not carry the member's line",
			);
			for await (const _ of lines) { /* drain until the next replacement */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const refusedReaderFixture = (async () => {
		const conn = await refusedReaderConn;
		try {
			const lines = await registerSaslReader(
				conn,
				"badnick",
				"badaccount",
				"wrong-password",
				"#login",
				false,
			);
			for await (const _ of lines) { /* the failed attempt closes */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const restoredReaderFixture = (async () => {
		const conn = await restoredReaderConn;
		try {
			const lines = await registerSaslReader(conn, "myircnick", "myircnick", "password", "#login", true);
			const posted = (await lines.next()).value;
			assert(
				posted?.command === "PRIVMSG" && posted.params[0] === "#login" &&
					posted.params[1] === "rollback marker",
				"the restored identity did not carry the member's next line",
			);
			for await (const _ of lines) { /* drain until part */ }
		} finally {
			try {
				conn.close();
			} catch { /* the gateway closed it first */ }
		}
	})();

	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish(DIRECTORY, directoryBehavior(roomServer));
			session.publish("gw", ircGatewayBehavior(roomServer));
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	let joined = false;
	try {
		const gw = await session.fetch("gw");
		await openIrcNetwork(session, gw, {
			network: "login-fixture",
			host: "localhost",
			port: ircPort,
			tls: true,
			nick: "gwbot",
		});
		await within(
			joinIrcChannel(session, gw, "login-fixture", "#login"),
			"joining the login fixture",
		);
		joined = true;
		const roomRef = await within(enterOrOpen(session, "login-fixture/#login"), "entering the login fixture");
		const room = await within(Room.subscribe(session, roomRef, "rooms-name"), "subscribing to the login fixture");
		await within(initialReaderReady, "the initial IRC registration attempt");
		const answered = await within(
			room.submitBridgeForm(IRC_LINK_ACTION, {
				[IRC_NICK_FIELD]: "myircnick",
				[IRC_ACCOUNT_FIELD]: "myircnick",
				[IRC_PASSWORD_FIELD]: "password",
			}),
			"choosing the IRC identity",
		);
		assert(answered.includes("<myircnick>"), `the identity answer was ${answered}`);
		const linked = await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "rooms-name" &&
				message.presence.state === "linked",
		);
		assert(
			linked.presence?.kind === "seat" && linked.presence.nick === "myircnick",
			"the room did not link the Rooms member to the chosen IRC nick",
		);
		await within(room.say("identity marker"), "posting through the authenticated identity");
		let refused = "";
		try {
			await within(
				room.submitBridgeForm(IRC_LINK_ACTION, { [IRC_NICK_FIELD]: "occupiednick" }),
				"refusing the occupied chosen nick",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(
			refused.includes("already in use"),
			`an explicitly chosen nick was silently changed instead of refused: "${refused}"`,
		);
		await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "rooms-name" &&
				message.presence.state === "linked" && message.presence.nick === "myircnick",
		);
		await within(room.say("after collision marker"), "posting after the collision rollback");
		refused = "";
		try {
			await within(
				room.submitBridgeForm(IRC_LINK_ACTION, {
					[IRC_NICK_FIELD]: "badnick",
					[IRC_ACCOUNT_FIELD]: "badaccount",
					[IRC_PASSWORD_FIELD]: "wrong-password",
				}),
				"refusing the replacement identity",
			);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("904"), `the bad replacement was not refused by SASL: "${refused}"`);
		const restored = await nextMessage(
			room,
			(message) =>
				message.presence?.kind === "seat" && message.presence.name === "rooms-name" &&
				message.presence.state === "linked" && message.presence.nick === "myircnick",
		);
		assert(restored.presence?.kind === "seat", "the rejected identity did not restore the prior seat");
		await within(room.say("rollback marker"), "posting through the restored identity");
		await within(partIrcChannel(session, gw, "login-fixture", "#login"), "parting the login fixture");
		joined = false;
	} finally {
		if (joined) {
			try {
				const gw = await session.fetch("gw");
				await partIrcChannel(session, gw, "login-fixture", "#login");
			} catch { /* the failed scene may already have ended the gateway */ }
		}
		try {
			ircListener.close();
		} catch { /* all three fixture connections may already own it */ }
		await session.close().catch(() => {});
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([
			feedFixture,
			initialReaderFixture,
			authenticatedReaderFixture,
			collidingReaderFixture,
			restoredAfterCollisionFixture,
			refusedReaderFixture,
			restoredReaderFixture,
			serving,
		]);
		await roomServer.close();
	}
});
