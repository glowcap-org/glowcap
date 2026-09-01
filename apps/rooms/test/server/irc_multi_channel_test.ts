// One Rooms member is one IRC identity across a network, however many of that
// network's channels the directory bridges.

import { DIRECTORY, SNAPSHOT } from "../../lib/protocol.ts";
import {
	closeIrcNetwork,
	joinIrcChannel,
	openIrcNetwork,
	partIrcChannel,
	snapshotIrcGateway,
} from "../../lib/irc_gateway_client.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { Room } from "../../lib/room/client.ts";
import { directoryBehavior } from "../../server/directory_behavior.ts";
import { ircGatewayBehavior } from "../../server/irc_gateway_behavior.ts";
import { readIrcLines } from "../../irc/protocol.ts";
import { assert, dial, enterOrOpen, nextMessage, roomsTest, within } from "../support/rooms_server.ts";
import { RoomServer } from "../../server/room_server.ts";

roomsTest("an IRC network is durable authority before it has a channel or transport", async () => {
	const irc = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const ircPort = (irc.addr as Deno.NetAddr).port;
	const accepted = irc.accept().then((conn) => {
		conn.close();
		return true;
	}).catch(() => false);
	const roomServer = new RoomServer();
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish(DIRECTORY, directoryBehavior(roomServer));
			session.publish("gw", ircGatewayBehavior(roomServer));
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const gateway = await session.fetch("gw");
		const network = await openIrcNetwork(session, gateway, {
			network: "quiet",
			host: "127.0.0.1",
			port: ircPort,
			tls: false,
			nick: "feed",
		});
		const channels = await session.send(network, SNAPSHOT, []) as unknown[];
		assert(channels.length === 0, "a new network capability already owned a channel");
		session.release(network);
		const snapshot = await snapshotIrcGateway(session, gateway);
		assert(snapshot.networks[0]?.status === "dormant", "a zero-channel network enacted a transport");
		assert(snapshot.bridged.length === 0, "a zero-channel network invented a bridge");
		const connected = await Promise.race([
			accepted,
			new Promise<false>((resolve) => setTimeout(() => resolve(false), 30)),
		]);
		assert(!connected, "opening a zero-channel network opened its IRC socket");
		await closeIrcNetwork(session, gateway, "quiet");
		assert((await snapshotIrcGateway(session, gateway)).networks.length === 0, "closing retained the network");
	} finally {
		await session.close().catch(() => {});
		server.close();
		irc.close();
		await Promise.allSettled([accepted, serving]);
		await roomServer.close();
	}
});

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

const line = (text: string) => new TextEncoder().encode(text + "\r\n");

async function next(lines: AsyncIterator<import("../../irc/protocol.ts").IrcMessage>, what: string) {
	return await Promise.race([
		lines.next().then((item) => item.value),
		new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), 5_000)),
	]);
}

async function serveFeed(conn: Deno.Conn, channels: readonly string[]): Promise<void> {
	const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
	const nick = await next(lines, "network feed registration");
	assert(nick?.command === "NICK", "the network feed did not register");
	assert((await next(lines, "network feed USER"))?.command === "USER", "the network feed sent no USER");
	await writeAll(conn, line(`:fixture 001 ${nick.params[0]} :welcome`));
	for (const [index, channel] of channels.entries()) {
		const join = await next(lines, `${channel} feed JOIN`);
		assert(join?.command === "JOIN" && join.params[0] === channel, `${channel} feed joined elsewhere`);
		await writeAll(conn, line(`:${nick.params[0]}!feed@example JOIN :${channel}`));
		const visitor = `visitor${index + 1}`;
		await writeAll(conn, line(`:fixture 353 ${nick.params[0]} = ${channel} :@${visitor}`));
		await writeAll(conn, line(`:fixture 366 ${nick.params[0]} ${channel} :End of NAMES`));
		await writeAll(conn, line(`:${visitor}!member@example PRIVMSG ${channel} :from ${channel}`));
	}
	for (const channel of channels) {
		const part = await next(lines, `${channel} feed PART`);
		assert(part?.command === "PART" && part.params[0] === channel, `${channel} feed parted elsewhere`);
	}
}

roomsTest("an IRC registration refusal reaches the operator snapshot", async () => {
	const irc = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const ircPort = (irc.addr as Deno.NetAddr).port;
	const fixture = irc.accept().then(async (conn) => {
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			await next(lines, "refused feed NICK");
			await next(lines, "refused feed USER");
			await writeAll(conn, line(":fixture 433 * BusyNick :Nickname is already in use"));
		} finally {
			conn.close();
		}
	});
	const roomServer = new RoomServer();
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish(DIRECTORY, directoryBehavior(roomServer));
			session.publish("gw", ircGatewayBehavior(roomServer));
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const gateway = await session.fetch("gw");
		const network = await openIrcNetwork(session, gateway, {
			network: "refused",
			host: "127.0.0.1",
			port: ircPort,
			tls: false,
			nick: "BusyNick",
		});
		session.release(network);
		await joinIrcChannel(session, gateway, "refused", "#room");
		await fixture;
		const problem = await within(
			(async () => {
				while (true) {
					const snapshot = await snapshotIrcGateway(session, gateway);
					if (snapshot.networks[0]?.problem !== "") return snapshot.networks[0]?.problem ?? "";
					await new Promise((resolve) => setTimeout(resolve, 10));
				}
			})(),
			"the IRC registration refusal snapshot",
		);
		assert(problem.includes("BusyNick") && problem.includes("already in use"), "the refusal lost its exact cause");
		await closeIrcNetwork(session, gateway, "refused");
	} finally {
		await session.close().catch(() => {});
		server.close();
		irc.close();
		await Promise.allSettled([fixture, serving]);
		await roomServer.close();
	}
});

roomsTest("one IRC network identity spans two bridged channels", async () => {
	const irc = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const ircPort = (irc.addr as Deno.NetAddr).port;
	const feedConnection = irc.accept();
	const memberSocket = feedConnection.then(() => irc.accept());
	const feed = feedConnection.then((conn) => serveFeed(conn, ["#one", "#two"]));
	const roomServer = new RoomServer();
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const accepted of server) {
			accepted.publish(DIRECTORY, directoryBehavior(roomServer));
			accepted.publish("gw", ircGatewayBehavior(roomServer));
			void accepted.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	let one: Room | null = null;
	let two: Room | null = null;
	try {
		const gateway = await session.fetch("gw");
		const network = await openIrcNetwork(session, gateway, {
			network: "fixture",
			host: "127.0.0.1",
			port: ircPort,
			tls: false,
			nick: "feed",
		});
		session.release(network);
		for (const channel of ["#one", "#two"]) {
			await within(
				joinIrcChannel(session, gateway, "fixture", channel),
				`bridging ${channel}`,
			);
		}
		one = await Room.subscribe(session, await enterOrOpen(session, "fixture/#one"), "alice");
		const member = await memberSocket;
		const lines = readIrcLines(member.readable)[Symbol.asyncIterator]();
		assert(
			(await next(lines, "member NICK"))?.params[0] === "alice",
			"the member connection did not take its Rooms nick",
		);
		assert((await next(lines, "member USER"))?.command === "USER", "the member connection sent no USER");
		await writeAll(member, line(":fixture 001 alice :welcome"));
		const joinedOne = await next(lines, "first member JOIN");
		assert(joinedOne?.command === "JOIN" && joinedOne.params[0] === "#one", "the first room joined elsewhere");
		await writeAll(member, line(":alice!member@example JOIN :#one"));
		const oneRoster = await nextMessage(
			one,
			(message) => message.presence?.kind === "roster" && message.presence.names.includes("irc/visitor1"),
		);
		assert(oneRoster.presence?.kind === "roster", "the first feed roster did not reach its room");
		const oneInbound = await nextMessage(one, (message) => message.text === "from #one");
		assert(oneInbound.from === "irc/visitor1", "the first feed line did not reach its room");

		two = await Room.subscribe(session, await enterOrOpen(session, "fixture/#two"), "alice");
		const joinedTwo = await next(lines, "second member JOIN");
		assert(joinedTwo?.command === "JOIN" && joinedTwo.params[0] === "#two", "the second room joined elsewhere");
		await writeAll(member, line(":alice!member@example JOIN :#two"));
		const twoRoster = await nextMessage(
			two,
			(message) => message.presence?.kind === "roster" && message.presence.names.includes("irc/visitor2"),
		);
		assert(twoRoster.presence?.kind === "roster", "the second feed roster did not reach its room");
		const twoInbound = await nextMessage(two, (message) => message.text === "from #two");
		assert(twoInbound.from === "irc/visitor2", "the second feed line did not reach its room");
		await one.say("from one");
		await two.say("from two");
		const first = await next(lines, "first member line");
		const second = await next(lines, "second member line");
		assert(first?.command === "PRIVMSG" && first.params[0] === "#one", "the first line crossed channels");
		assert(second?.command === "PRIVMSG" && second.params[0] === "#two", "the second line crossed channels");

		await one.leave();
		one = null;
		const parted = await next(lines, "first member PART");
		assert(parted?.command === "PART" && parted.params[0] === "#one", "leaving one room closed the wrong channel");
		await two.say("still here");
		const survivor = await next(lines, "surviving member line");
		assert(
			survivor?.command === "PRIVMSG" && survivor.params[0] === "#two" && survivor.params[1] === "still here",
			"the sibling channel did not survive",
		);
		await two.leave();
		two = null;
		await partIrcChannel(session, gateway, "fixture", "#one");
		await partIrcChannel(session, gateway, "fixture", "#two");
		member.close();
	} finally {
		await one?.leave().catch(() => {});
		await two?.leave().catch(() => {});
		await session.close().catch(() => {});
		server.close();
		try {
			irc.close();
		} catch { /* already closed */ }
		for (const connection of [feedConnection, memberSocket]) {
			void connection.then((conn) => {
				try {
					conn.close();
				} catch { /* already closed */ }
			}).catch(() => {});
		}
		await Promise.allSettled([feed, serving]);
		await roomServer.close();
	}
});
