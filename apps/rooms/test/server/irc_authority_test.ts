// Durable entry and Rooms moderation authority owned by one IRC bridge source.

import type { Behavior, Session } from "@glowcap/runtime";
import { readIrcLines } from "../../irc/protocol.ts";
import { giveStewardship, revokeStewardship, snapshotOperator } from "../../lib/operator.ts";
import { ROOM_RETIRED, RoomError } from "../../lib/errors.ts";
import { DIRECTORY } from "../../lib/protocol.ts";
import { joinIrcChannel, openIrcNetwork, partIrcChannel, snapshotIrcGateway } from "./irc_gateway/wire.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { Room } from "../../lib/room/client.ts";
import { directoryBehavior } from "../../server/directory_behavior.ts";
import { IrcBridgeAuthorities } from "../../server/irc_gateway/authority.ts";
import { ircGatewayBehavior } from "../../server/irc_gateway_behavior.ts";
import { RoomServerOperationsState } from "../../server/operations_state.ts";
import { roomsOperatorBehavior } from "../../server/operator/behavior.ts";
import { RoomDisconnects } from "../../server/presence.ts";
import { RoomLinks } from "../../server/room_links.ts";
import { RoomServerSessions } from "../../server/sessions.ts";
import { RoomServerState } from "../../server/state.ts";
import { say, writeAll } from "./irc_gateway/fixture.ts";
import { assert, dial, enterOrOpen, roomsTest, within } from "../support/rooms_server.ts";
import { RoomServer } from "../../server/room_server.ts";

function ircFixture() {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const connections = new Set<Deno.Conn>();
	const handlers: Promise<void>[] = [];
	const allJoined = Promise.withResolvers<void>();
	let joined = 0;
	const serving = (async () => {
		try {
			for await (const connection of listener) {
				connections.add(connection);
				const handler = (async () => {
					try {
						const lines = readIrcLines(connection.readable);
						const iterator = lines[Symbol.asyncIterator]();
						const nick = (await iterator.next()).value;
						assert(nick?.command === "NICK", "fixture connection did not register a nick");
						assert((await iterator.next()).value?.command === "USER", "fixture connection sent no USER");
						const name = nick.params[0];
						await writeAll(connection, say(`:fixture 001 ${name} :welcome`));
						for await (const message of { [Symbol.asyncIterator]: () => iterator }) {
							if (message.command === "JOIN") {
								await writeAll(connection, say(`:${name}!member@example JOIN :${message.params[0]}`));
								joined += 1;
								if (joined === 4) allJoined.resolve();
							} else if (message.command === "PING") {
								await writeAll(connection, say(`:fixture PONG :${message.params.at(-1) ?? "fixture"}`));
							} else if (message.command === "QUIT") break;
						}
					} finally {
						connections.delete(connection);
						try {
							connection.close();
						} catch { /* fixture shutdown already closed it */ }
					}
				})().catch((error) => {
					if (
						error instanceof Deno.errors.Interrupted || error instanceof Deno.errors.BadResource ||
						error instanceof Deno.errors.ConnectionReset
					) return;
					throw error;
				});
				handlers.push(handler);
			}
		} catch (error) {
			if (!(error instanceof Deno.errors.BadResource)) throw error;
		}
	})();
	return {
		port: (listener.addr as Deno.NetAddr).port,
		joined: allJoined.promise,
		async close() {
			listener.close();
			for (const connection of connections) connection.close();
			await serving;
			const outcomes = await Promise.allSettled(handlers);
			const failed = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
			if (failed != null) throw failed.reason;
		},
	};
}

async function waitForEnd(room: Room): Promise<void> {
	const reader = room.messages.getReader();
	try {
		await Promise.race([
			(async () => {
				while (!(await reader.read()).done) { /* drain the welcome and terminal notice */ }
			})(),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error("room membership did not end")), 5_000)
			),
		]);
	} finally {
		reader.releaseLock();
	}
}

roomsTest("an IRC bridge owns durable entry and Rooms moderator capabilities", async () => {
	const irc = ircFixture();
	const roomServer = new RoomServer();
	const state = await RoomServerOperationsState.open(null);
	const links = await RoomLinks.restore(
		roomServer,
		await RoomServerState.open(),
		{
			room: () => {
				throw new Error("the bridge authority test requested a native room publication");
			},
			steward: () => {
				throw new Error("the bridge authority test requested a native moderator publication");
			},
			manager: () => {
				throw new Error("the bridge authority test requested a native manager publication");
			},
			unpublish: () => false,
		},
		() => "127.0.0.1:1",
	);
	const sessions = new RoomServerSessions(new RoomDisconnects(roomServer));
	const host = roomsHost();
	const server = await roomsListen("127.0.0.1", 0, host);
	const authorities = new IrcBridgeAuthorities(state, {
		publish: (entropy, behavior) => host.publishDurable(behavior, entropy),
		unpublish: (swiss) => host.unpublishDurable(swiss),
		advertisedLocation: () => `127.0.0.1:${server.port}`,
	});
	const serving = (async () => {
		for await (const accepted of server) {
			accepted.publish(DIRECTORY, directoryBehavior(roomServer));
			accepted.publish("gw", ircGatewayBehavior(roomServer, state, authorities));
			accepted.publish("op", roomsOperatorBehavior(roomServer, links, sessions, authorities));
			void accepted.serve().catch(() => {});
		}
	})();
	const aliceSession = await dial(loopbackTcpDesignator(server.port));
	const bobSession = await dial(loopbackTcpDesignator(server.port));
	const invitedSession = await dial(loopbackTcpDesignator(server.port));
	let alice: Room | null = null;
	let bob: Room | null = null;
	let invited: Room | null = null;
	try {
		const gateway = await aliceSession.fetch("gw");
		await openIrcNetwork(aliceSession, gateway, {
			network: "authority",
			host: "127.0.0.1",
			port: irc.port,
			tls: false,
			nick: "feed",
		});
		await joinIrcChannel(aliceSession, gateway, "authority", "#room");
		const snapshot = await snapshotIrcGateway(aliceSession, gateway);
		const publicationId = snapshot.connections[0]?.leases[0]?.publicationId;
		assert(publicationId != null, "the bridge published no exact generation");

		alice = await Room.subscribe(aliceSession, await enterOrOpen(aliceSession, "authority/#room"), "alice");
		bob = await Room.subscribe(bobSession, await enterOrOpen(bobSession, "authority/#room"), "bob");
		const link = await alice.link();
		invited = await Room.subscribe(invitedSession, await invitedSession.enliven(link), "carol");
		await within(irc.joined, "every bridge member joining the IRC fixture");

		const operator = await aliceSession.fetch("op");
		const inventoried = (await snapshotOperator(aliceSession, operator)).stewardships.find((row) =>
			row.name === publicationId
		);
		assert(inventoried?.label === "authority/#room", "the operator did not inventory the bridge source");
		const issued = await giveStewardship(aliceSession, operator, publicationId);
		assert(issued.steward != null, "issuing bridge moderation returned no sturdyref");
		await alice.takeSteward(issued.steward);
		await alice.kick("bob");
		await waitForEnd(bob);
		assert(bob.endedReason?.includes("moderator removed") === true, "the removed member got no terminal reason");

		let ircKickRefusal = "";
		try {
			await alice.kick("irc/visitor");
		} catch (error) {
			ircKickRefusal = error instanceof Error ? error.message : String(error);
		}
		// The refusal names what this moderator governs rather than what it does
		// not: it says Rooms memberships, and stays silent about IRC, because a
		// second bridge's members are refused by exactly the same sentence.
		assert(
			ircKickRefusal.includes("bridged from elsewhere"),
			`bridge moderation pretended to carry privileges over a bridged name: ${ircKickRefusal}`,
		);

		const revoked = await revokeStewardship(aliceSession, operator, publicationId);
		assert(!revoked.issued && revoked.steward === null, "the operator did not report completed revocation");
		for (let attempt = 0; attempt < 50 && alice.stewardLink != null; attempt += 1) {
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
		assert(alice.stewardLink === null && !alice.canKick, "bridge revocation left the room claiming moderation");
		let retired = false;
		try {
			await alice.kick("carol");
		} catch {
			retired = true;
		}
		assert(retired, "the revoked bridge moderator capability remained live");
		await partIrcChannel(aliceSession, gateway, "authority", "#room");
	} finally {
		await alice?.leave().catch(() => {});
		await bob?.leave().catch(() => {});
		await invited?.leave().catch(() => {});
		await Promise.all([
			aliceSession.close().catch(() => {}),
			bobSession.close().catch(() => {}),
			invitedSession.close().catch(() => {}),
		]);
		server.close();
		await Promise.allSettled([serving]);
		await irc.close();
		await roomServer.close();
		await host.close();
	}
});

Deno.test("IRC bridge moderator publication rolls durable issuance back on failure", async () => {
	const state = await RoomServerOperationsState.open(null);
	await state.rememberIrcNetwork({
		network: "atomic",
		host: "irc.example.test",
		port: 6697,
		tls: true,
		nick: "rooms",
	});
	const publicationId = await state.rememberIrcBridge({ network: "atomic", channel: "#room" });
	const published = new Set<string>();
	let failSteward = false;
	let changes = 0;
	const authorities = new IrcBridgeAuthorities(state, {
		publish: (entropy) => {
			const encoded = [...entropy].map((byte) => byte.toString(16).padStart(2, "0")).join("");
			if (failSteward && encoded === state.ircBridgeAuthority(publicationId)?.stewardEntropy) {
				throw new Error("fixture publication refusal");
			}
			const swiss = `durable-${encoded}`;
			if (published.has(swiss)) throw new Error("fixture duplicate publication");
			published.add(swiss);
			return swiss;
		},
		unpublish: (swiss) => published.delete(swiss),
		advertisedLocation: () => "127.0.0.1:1",
	}, () => changes += 1);
	const roomBehavior: Behavior = () => null;
	authorities.activate(publicationId, "atomic/#room", roomBehavior, () => false, (nick) => nick.startsWith("irc/"));
	const session = {} as Session;
	const before = state.ircBridgeAuthority(publicationId)!;
	failSteward = true;
	let refusal = "";
	try {
		await authorities.issueSteward(publicationId, session);
	} catch (error) {
		refusal = error instanceof Error ? error.message : String(error);
	}
	const rolledBack = state.ircBridgeAuthority(publicationId)!;
	assert(refusal.includes("fixture publication refusal"), "the publication refusal lost its exact cause");
	assert(!rolledBack.issued, "a failed publication remained durably issued");
	assert(rolledBack.stewardEntropy !== before.stewardEntropy, "rollback did not retire the failed entropy");
	assert(!published.has(`durable-${before.stewardEntropy}`), "rollback retained the failed live publication");

	failSteward = false;
	const issued = await authorities.issueSteward(publicationId, session);
	const recoveredGeneration = issued.generation;
	const recoveredSwiss = `durable-${state.ircBridgeAuthority(publicationId)!.stewardEntropy}`;
	await authorities.issueSteward(publicationId, session);
	assert(
		state.ircBridgeAuthority(publicationId)!.generation === recoveredGeneration,
		"recovering an issued moderator advanced its generation",
	);
	await authorities.revokeSteward(publicationId);
	assert(!published.has(recoveredSwiss), "revocation retained the live moderator publication");
	assert(changes === 3, `authority changes notified ${changes} times instead of once per durable transition`);
	authorities.deactivate(publicationId);
	assert(authorities.stewardships(session).length === 0, "inactive bridge authority remained actionable inventory");
});

Deno.test("parting during IRC moderator issuance publishes no orphan", async () => {
	const publicationId = "part-race";
	const issued = {
		publicationId,
		roomEntropy: "1".repeat(32),
		stewardEntropy: "2".repeat(32),
		generation: 1,
		issued: true,
	};
	let current: typeof issued | null = { ...issued, generation: 0, issued: false };
	const pending = Promise.withResolvers<typeof issued>();
	const state = {
		ircBridgeAuthority: () => current,
		ircBridges: () => [{ network: "race", channel: "#room", publicationId }],
		issueIrcBridgeSteward: () => pending.promise,
	} as unknown as RoomServerOperationsState;
	const published = new Set<string>();
	const authorities = new IrcBridgeAuthorities(state, {
		publish: (entropy) => {
			const swiss = [...entropy].map((byte) => byte.toString(16).padStart(2, "0")).join("");
			published.add(swiss);
			return swiss;
		},
		unpublish: (swiss) => published.delete(swiss),
		advertisedLocation: () => "127.0.0.1:1",
	});
	authorities.activate(publicationId, "race/#room", () => null, () => false, (nick) => nick.startsWith("irc/"));
	const issuing = authorities.issueSteward(publicationId, {} as Session);
	await Promise.resolve();
	current = null;
	authorities.deactivate(publicationId);
	pending.resolve(issued);
	let retired = false;
	try {
		await issuing;
	} catch (error) {
		retired = error instanceof RoomError && error.code === ROOM_RETIRED;
	}
	assert(retired, "issuance did not report the bridge retirement");
	assert(published.size === 0, "issuance published authority after its bridge retired");
});
