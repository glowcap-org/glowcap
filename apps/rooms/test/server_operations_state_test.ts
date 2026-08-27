import { RoomServerOperationsState } from "../server/operations_state.ts";
import { assertEquals } from "./assert.ts";
import { roomsHost } from "../lib/locator.ts";
import { ListenerRegistry } from "../server/listeners.ts";
import { ircBridgeSnapshot, partIrcBridge, restoreIrcBridges } from "../server/irc_gateway.ts";
import { RoomServerState } from "../server/state.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";
import { DENO_FLAGS, readPort, ROOT, SERVER } from "./support/rooms_server.ts";

Deno.test("operator-managed server configuration survives restart as intent", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-operations-state-" });
	try {
		const state = await RoomServerOperationsState.open(directory);
		await state.rememberListener({ transport: "noise-tcp", options: { bind: "127.0.0.1", port: 4312 } });
		await state.rememberIrcBridge({
			network: "libera",
			channel: "#pancake",
			host: "irc.example.test",
			port: 6697,
			tls: true,
			nick: "pancake-rooms",
			sasl: { account: "rooms", password: "secret" },
		});
		const restored = await RoomServerOperationsState.open(directory);
		assertEquals(restored.listeners(), [{
			transport: "noise-tcp",
			options: { bind: "127.0.0.1", port: 4312 },
		}]);
		assertEquals(restored.ircBridges()[0]?.sasl, { account: "rooms", password: "secret" });
		await restored.forgetListener("noise-tcp");
		await restored.forgetIrcBridge("LIBERA", "#PANCAKE");
		const cleared = await RoomServerOperationsState.open(directory);
		assertEquals(cleared.listeners(), []);
		assertEquals(cleared.ircBridges(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("operator-managed configuration replaces one logical listener or channel", async () => {
	const state = await RoomServerOperationsState.open(null);
	await state.rememberListener({ transport: "tcp", options: { port: 1 } });
	await state.rememberListener({ transport: "tcp", options: { port: 2 } });
	await state.rememberIrcBridge({
		network: "network",
		channel: "#room",
		host: "first.test",
		port: 6697,
		tls: true,
		nick: "rooms",
	});
	await state.rememberIrcBridge({
		network: "NETWORK",
		channel: "#ROOM",
		host: "second.test",
		port: 6697,
		tls: true,
		nick: "rooms",
	});
	assertEquals(state.listeners(), [{ transport: "tcp", options: { port: 2 } }]);
	assertEquals(state.ircBridges().map((bridge) => bridge.host), ["second.test"]);
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
				ircBridges: [],
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
				listeners: [{ transport: "iroh", options: { port: 1 } }],
				ircBridges: [],
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
	const listeners = new ListenerRegistry(host, state);
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

	await state.rememberIrcBridge({
		network: "restore",
		channel: "#state",
		host: "127.0.0.1",
		port: 1,
		tls: false,
		nick: "rooms",
	});
	await restoreIrcBridges(state);
	assertEquals(ircBridgeSnapshot().map((row) => (row as unknown[]).slice(0, 2)), [["restore", "#state"]]);
	await partIrcBridge("restore", "#state", state);
	assertEquals(state.ircBridges(), []);
});
