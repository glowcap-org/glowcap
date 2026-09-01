import { RoomServerOperationsState } from "../../server/operations_state.ts";
import { assertEquals } from "../assert.ts";
import { roomsHost } from "../../lib/locator.ts";
import { ListenerRegistry } from "../../server/listeners.ts";
import {
	closeIrcBridges,
	ircBridgeSnapshot,
	ircGatewaySnapshot,
	partIrcBridge,
	restoreIrcBridges,
} from "../../server/irc_gateway.ts";
import { RoomServerState } from "../../server/state.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { DENO_FLAGS, readPort, ROOT, SERVER } from "../support/rooms_server.ts";
import { RoomServerSessions } from "../../server/sessions.ts";
import { RoomDisconnects } from "../../server/presence.ts";
import { RoomServer } from "../../server/room_server.ts";

Deno.test("operator-managed server configuration survives restart as intent", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-operations-state-" });
	try {
		const state = await RoomServerOperationsState.open(directory);
		await state.rememberListener({ transport: "noise-tcp", options: { bind: "127.0.0.1", port: 4312 } });
		await state.rememberIrcNetwork({
			network: "libera",
			host: "irc.example.test",
			port: 6697,
			tls: true,
			nick: "pancake-rooms",
			sasl: { account: "rooms", password: "secret" },
		});
		const publicationId = await state.rememberIrcBridge({
			network: "libera",
			channel: "#pancake",
		});
		const authority = state.ircBridgeAuthority(publicationId);
		assertEquals(authority != null, true);
		const restored = await RoomServerOperationsState.open(directory);
		assertEquals(restored.listeners(), [{
			transport: "noise-tcp",
			options: { bind: "127.0.0.1", port: 4312 },
		}]);
		assertEquals(restored.ircNetworks()[0]?.sasl, { account: "rooms", password: "secret" });
		assertEquals(restored.ircBridges()[0]?.publicationId, publicationId);
		assertEquals(restored.ircBridgeAuthority(publicationId), authority);
		const issued = await restored.issueIrcBridgeSteward(publicationId);
		const issuedRestored = await RoomServerOperationsState.open(directory);
		assertEquals(issuedRestored.ircBridgeAuthority(publicationId), issued);
		await issuedRestored.forgetListener("noise-tcp");
		await issuedRestored.forgetIrcBridge("LIBERA", "#PANCAKE");
		await issuedRestored.forgetIrcNetwork("LIBERA");
		const cleared = await RoomServerOperationsState.open(directory);
		assertEquals(cleared.listeners(), []);
		assertEquals(cleared.ircBridges(), []);
		assertEquals(cleared.ircNetworks(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("operator-managed configuration replaces one logical listener or channel intent", async () => {
	const state = await RoomServerOperationsState.open(null);
	await state.rememberListener({ transport: "tcp", options: { port: 1 } });
	await state.rememberListener({ transport: "tcp", options: { port: 2 } });
	await state.rememberIrcNetwork({ network: "network", host: "irc.test", port: 6697, tls: true, nick: "rooms" });
	let rejectedNetworkReplacement = false;
	try {
		await state.rememberIrcNetwork({
			network: "NETWORK",
			host: "elsewhere.test",
			port: 6697,
			tls: true,
			nick: "rooms",
		});
	} catch {
		rejectedNetworkReplacement = true;
	}
	const firstPublicationId = await state.rememberIrcBridge({
		network: "network",
		channel: "#room",
	});
	const replacementPublicationId = await state.rememberIrcBridge({
		network: "NETWORK",
		channel: "#ROOM",
	});
	assertEquals(state.listeners(), [{ transport: "tcp", options: { port: 2 } }]);
	assertEquals(rejectedNetworkReplacement, true);
	assertEquals(state.ircNetworks()[0]?.host, "irc.test");
	assertEquals(state.ircBridges().map((bridge) => `${bridge.network}/${bridge.channel}`), ["NETWORK/#ROOM"]);
	assertEquals(firstPublicationId === replacementPublicationId, false);
});

Deno.test("operator-managed server state refuses duplicate or malformed intent at startup", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-operations-corrupt-" });
	try {
		await Deno.writeTextFile(
			`${directory}/operations.json`,
			JSON.stringify({
				version: 1,
				listeners: [
					{ transport: "tcp", options: { port: 1 } },
					{ transport: "tcp", options: { port: 2 } },
				],
				ircNetworks: [],
				ircBridges: [],
				ircBridgeAuthorities: [],
			}),
		);
		let refused = false;
		try {
			await RoomServerOperationsState.open(directory);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		await Deno.writeTextFile(
			`${directory}/operations.json`,
			JSON.stringify({
				version: 1,
				listeners: [],
				ircNetworks: [],
				ircBridges: [{ network: "missing", channel: "#orphan", publicationId: "orphan" }],
				ircBridgeAuthorities: [{
					publicationId: "orphan",
					roomEntropy: "1".repeat(32),
					stewardEntropy: "2".repeat(32),
					generation: 0,
					issued: false,
				}],
			}),
		);
		refused = false;
		try {
			await RoomServerOperationsState.open(directory);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		await Deno.writeTextFile(
			`${directory}/operations.json`,
			JSON.stringify({
				version: 1,
				listeners: [{ transport: "iroh", options: { port: 1 } }],
				ircNetworks: [],
				ircBridges: [],
				ircBridgeAuthorities: [],
			}),
		);
		refused = false;
		try {
			await RoomServerOperationsState.open(directory);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		await Deno.writeTextFile(
			`${directory}/operations.json`,
			JSON.stringify({
				version: 1,
				listeners: [],
				ircNetworks: [{ network: "network", host: "irc.example.test", port: 6697, tls: true, nick: "rooms" }],
				ircBridges: ["#one", "#two"].map((channel) => ({
					network: "network",
					channel,
					publicationId: "duplicate-publication",
				})),
				ircBridgeAuthorities: [{
					publicationId: "duplicate-publication",
					roomEntropy: "3".repeat(32),
					stewardEntropy: "4".repeat(32),
					generation: 0,
					issued: false,
				}],
			}),
		);
		refused = false;
		try {
			await RoomServerOperationsState.open(directory);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		await Deno.writeTextFile(
			`${directory}/operations.json`,
			JSON.stringify({
				version: 1,
				listeners: [],
				ircNetworks: [
					{ network: "network", host: "irc.example.test", port: 6697, tls: true, nick: "rooms" },
					{ network: "NETWORK", host: "other.example.test", port: 6697, tls: true, nick: "rooms" },
				],
				ircBridges: [],
				ircBridgeAuthorities: [],
			}),
		);
		refused = false;
		try {
			await RoomServerOperationsState.open(directory);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("server startup names a corrupt operator-managed state document", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-operations-startup-" });
	try {
		await RoomServerState.open(directory);
		await Deno.writeTextFile(`${directory}/operations.json`, "not-json\n");
		const process = spawnOwned("deno", {
			args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
			cwd: ROOT,
			env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: directory },
			stdout: "piped",
			stderr: "piped",
		});
		const [status, stdout, stderr] = await Promise.all([
			process.status,
			new Response(process.stdout).text(),
			new Response(process.stderr).text(),
		]);
		assertEquals(status.success, false);
		assertEquals(stdout.includes("ROOMS-SERVER-LISTENING"), false);
		assertEquals(stderr.includes(`${directory}/operations.json`), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("one Rooms server state directory admits one live writer", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-server-custody-" });
	const start = () =>
		spawnOwned("deno", {
			args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
			cwd: ROOT,
			env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: directory },
			stdout: "piped",
			stderr: "piped",
		});
	const first = start();
	try {
		await readPort(first);
		const second = start();
		const [status, stderr] = await Promise.all([second.status, new Response(second.stderr).text()]);
		assertEquals(status.success, false);
		assertEquals(stderr.includes("state directory is already in use"), true);
	} finally {
		await stopOwned(first);
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("listener and IRC runtime owners replay and forget saved intent", async () => {
	const state = await RoomServerOperationsState.open(null);
	await state.rememberListener({ transport: "tcp", options: { bind: "127.0.0.1", port: 0 } });
	const host = roomsHost();
	const roomServer = new RoomServer();
	const listeners = new ListenerRegistry(
		host,
		new RoomServerSessions(new RoomDisconnects(roomServer)),
		roomServer.journal,
		state,
	);
	try {
		await listeners.restore();
		const tcp = listeners.rows().find((row) => Array.isArray(row) && row[0] === "tcp") as unknown[];
		assertEquals(typeof tcp[6], "number");
		await listeners.down(tcp[6] as number);
		assertEquals(state.listeners(), []);
	} finally {
		await listeners.close();
		await host.close();
	}

	await state.rememberIrcNetwork({
		network: "restore",
		host: "127.0.0.1",
		port: 1,
		tls: false,
		nick: "rooms",
	});
	const publicationId = await state.rememberIrcBridge({
		network: "restore",
		channel: "#state",
	});
	await restoreIrcBridges(roomServer, state);
	assertEquals(ircBridgeSnapshot(roomServer).map((row) => (row as unknown[]).slice(0, 2)), [["restore", "#state"]]);
	assertEquals((ircBridgeSnapshot(roomServer)[0] as unknown[])[3], publicationId);
	closeIrcBridges(roomServer);
	await restoreIrcBridges(roomServer, state);
	assertEquals((ircBridgeSnapshot(roomServer)[0] as unknown[])[3], publicationId);
	await partIrcBridge(roomServer, "restore", "#state", state);
	assertEquals(state.ircBridges(), []);
	closeIrcBridges(roomServer);
});

Deno.test("a zero-channel IRC network survives restart without enacting a transport", async () => {
	const state = await RoomServerOperationsState.open(null);
	await state.rememberIrcNetwork({
		network: "quiet",
		host: "127.0.0.1",
		port: 1,
		tls: false,
		nick: "rooms",
	});
	const roomServer = new RoomServer();
	await restoreIrcBridges(roomServer, state);
	const snapshot = ircGatewaySnapshot(roomServer) as unknown[][];
	assertEquals((snapshot[0] as unknown[][]).map((row) => row.slice(0, 2)), [["quiet", "dormant"]]);
	assertEquals(snapshot[1], []);
	closeIrcBridges(roomServer);
});
