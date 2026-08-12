// Per-binding keyed-tcp restart proof (ADR-0075): happy path, key-squatter
// refusal, and same-seed-fresh-port restart — the Deno sibling of
// `test/driver/keyed_tcp_restart_test.zig`.
//
// Needs deno and the installed pancake archives; run via
// `zig build deno-keyed-tcp-restart`.

import { connect, keyedTcpLocator, type KeyedTcpServer, listenKeyedTcp } from "@pancake/stack";

const GREETING = "hello from the keyed listener";
const SEED_HAPPY = new Uint8Array(32).fill(0x71);
const SEED_HONEST = new Uint8Array(32).fill(0x72);
const SEED_SQUATTER = new Uint8Array(32).fill(0x73);
const SEED_RESTART = new Uint8Array(32).fill(0x74);

function greeter(verb: string, _args: unknown[]): string | null {
	if (verb === "greet") return GREETING;
	return null;
}

async function serveOnce(server: KeyedTcpServer): Promise<void> {
	for await (const session of server) {
		session.publish("greeter", greeter);
		session.serve();
		return;
	}
}

async function callGreeter(uri: string): Promise<void> {
	const session = await connect(uri);
	try {
		const ref = await session.fetch("greeter");
		const reply = await session.send(ref, "greet", []);
		if (reply !== GREETING) {
			throw new Error(`unexpected greeting: ${JSON.stringify(reply)}`);
		}
	} finally {
		session.close();
	}
}

async function sceneHappy(): Promise<void> {
	const server = listenKeyedTcp("127.0.0.1", 0, SEED_HAPPY);
	const task = serveOnce(server);
	await server.ready();
	await callGreeter(await server.uri());
	await task;
	server.close();
	console.log("deno-keyed-tcp-restart: happy path ok");
}

async function sceneSquatter(): Promise<void> {
	const honest = listenKeyedTcp("127.0.0.1", 0, SEED_HONEST);
	await honest.ready();
	const designator = honest.designator;
	honest.close();
	const squatter = listenKeyedTcp("127.0.0.1", 0, SEED_SQUATTER);
	const task = serveOnce(squatter);
	await squatter.ready();
	const uri = keyedTcpLocator(designator, "127.0.0.1", squatter.port);
	try {
		await callGreeter(uri);
		throw new Error("squatter dial should have been refused");
	} catch (e) {
		if (e instanceof Error && e.message.includes("should have been refused")) throw e;
		console.log(`deno-keyed-tcp-restart: squatter refused (${e})`);
	}
	await Promise.race([task, new Promise((r) => setTimeout(r, 2000))]);
	squatter.close();
	console.log("deno-keyed-tcp-restart: squatter refusal ok");
}

async function sceneRestart(): Promise<void> {
	const first = listenKeyedTcp("127.0.0.1", 0, SEED_RESTART);
	const task1 = serveOnce(first);
	await first.ready();
	const designator = first.designator;
	await callGreeter(await first.uri());
	await task1;
	first.close();

	const second = listenKeyedTcp("127.0.0.1", 0, SEED_RESTART);
	const task2 = serveOnce(second);
	await second.ready();
	if (second.designator !== designator) {
		throw new Error(`restart designator drifted: ${designator} vs ${second.designator}`);
	}
	await callGreeter(keyedTcpLocator(designator, "127.0.0.1", second.port));
	await task2;
	second.close();
	console.log("deno-keyed-tcp-restart: restart ok");
}

await sceneHappy();
await sceneSquatter();
await sceneRestart();
console.log("deno-keyed-tcp-restart: all scenes ok");
