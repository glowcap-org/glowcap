import * as tcp from "@glowcap/tcp";
// Per-binding keyed-tcp restart proof (ADR-0028): happy path, key-squatter
// refusal, and same-seed-fresh-port restart: the Deno sibling of
// `test/driver/keyed_tcp_restart_test.zig`.
//
// Needs deno and the installed glowcap archives; run via
// `zig build deno-keyed-tcp-restart`.

import { GlowcapError, type Locator, Runtime } from "@glowcap/runtime";
import type { Server } from "@glowcap/tcp";

const GREETING = "hello from the keyed listener";
const SEED_HAPPY = new Uint8Array(32).fill(0x71);
const SEED_HONEST = new Uint8Array(32).fill(0x72);
const SEED_SQUATTER = new Uint8Array(32).fill(0x73);
const SEED_RESTART = new Uint8Array(32).fill(0x74);
await using runtime = await Runtime.open({ providers: [tcp.provider()] });

function greeter(verb: string | null, _args: unknown[]): string | null {
	if (verb === "greet") return GREETING;
	return null;
}

async function serveOnce(server: Server, waitForPeerClose = false): Promise<void> {
	server.host.publish("greeter", greeter);
	for await (const session of server) {
		// The refusal scene needs only the rejected peer's closure, with no
		// application traffic or serving after the connection has closed.
		if (waitForPeerClose) {
			await new Promise<void>((resolve) => session.onClose(resolve));
			return;
		}
		await session.serve();
		return;
	}
}

async function callGreeter(partner: Locator): Promise<void> {
	const session = await runtime.connect(partner);
	try {
		const ref = await session.fetch("greeter");
		const reply = await session.send(ref, "greet", []);
		if (reply !== GREETING) {
			throw new Error(`unexpected greeting: ${JSON.stringify(reply)}`);
		}
	} finally {
		await session.close();
	}
}

async function sceneHappy(): Promise<void> {
	const server = await tcp.keyed.listen("127.0.0.1", 0, { seed: SEED_HAPPY });
	const task = serveOnce(server);
	await callGreeter(server.locator);
	await task;
	await server.close();
	console.log("deno-keyed-tcp-restart: happy path ok");
}

async function sceneSquatter(): Promise<void> {
	const honest = await tcp.keyed.listen("127.0.0.1", 0, { seed: SEED_HONEST });
	const designator = honest.designator;
	await honest.close();
	const squatter = await tcp.keyed.listen("127.0.0.1", 0, { seed: SEED_SQUATTER });
	const task = serveOnce(squatter, true);
	const partner = tcp.keyed.locator(designator, "127.0.0.1", squatter.port);
	await runtime.connect(partner).then(
		async (session) => {
			await session.close();
			throw new Error("squatter dial should have been refused");
		},
		(error) => {
			if (!(error instanceof GlowcapError)) throw error;
			console.log(`deno-keyed-tcp-restart: squatter refused (${error})`);
		},
	);
	await task;
	await squatter.close();
	console.log("deno-keyed-tcp-restart: squatter refusal ok");
}

async function sceneRestart(): Promise<void> {
	const first = await tcp.keyed.listen("127.0.0.1", 0, { seed: SEED_RESTART });
	const task1 = serveOnce(first);
	const designator = first.designator;
	await callGreeter(first.locator);
	await task1;
	await first.close();

	const second = await tcp.keyed.listen("127.0.0.1", 0, { seed: SEED_RESTART });
	const task2 = serveOnce(second);
	if (second.designator !== designator) {
		throw new Error(`restart designator drifted: ${designator} vs ${second.designator}`);
	}
	await callGreeter(tcp.keyed.locator(designator, "127.0.0.1", second.port));
	await task2;
	await second.close();
	console.log("deno-keyed-tcp-restart: restart ok");
}

await sceneHappy();
await sceneSquatter();
await sceneRestart();
console.log("deno-keyed-tcp-restart: all scenes ok");
