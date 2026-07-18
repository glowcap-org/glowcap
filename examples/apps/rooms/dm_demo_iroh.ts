// Rooms direct-message-by-introduction over iroh (three-party handoff).
// Sibling of `dm_demo.ts` over encrypted QUIC (`Direct` posture).
// Run by `zig build demo-rooms-dm-iroh`.

import process from "node:process";
import { Host, Ref } from "@pancake/stack";
import { IrohServer, listenIroh, Reachability } from "@pancake/iroh";
import { serveDirectory } from "./deno/server.ts";
import { dial } from "./deno/lib/locator.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "./deno/lib/protocol.ts";

const DM_TEXT = "hi Bob, privately, from Carol, over iroh";

function fail(message: string): never {
	console.error(`rooms-dm-iroh demo FAILED: ${message}`);
	process.exit(1);
}

async function until(
	ready: () => boolean,
	what: string,
	timeoutMs = 20_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!ready()) {
		if (Date.now() > deadline) fail(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 20));
	}
}

async function dialableUri(server: IrohServer, what: string): Promise<string> {
	await until(() => server.directAddresses.length > 0, `${what} direct addresses`);
	return server.uri;
}

async function main(): Promise<void> {
	const bobInbox: string[] = [];
	let bobInbound = 0;
	const bobSeed = crypto.getRandomValues(new Uint8Array(32));
	const bobHost = new Host(bobSeed);
	const dmBehavior = (verb: string, args: unknown[]) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		bobInbox.push(String(args[1]));
		return null;
	};
	bobHost.publishGiftable("dm", dmBehavior);
	const bob = listenIroh(Reachability.Direct, bobSeed, bobHost);
	const bobAccept = (async () => {
		for await (const session of bob) {
			bobInbound += 1;
			session.serve().catch(() => {});
		}
	})();
	const bobLocator = await dialableUri(bob, "Bob");

	const roomSeed = crypto.getRandomValues(new Uint8Array(32));
	const roomHost = new Host(roomSeed);
	const room = listenIroh(Reachability.Direct, roomSeed, roomHost);
	const roomServe = serveDirectory(room);
	const roomUri = await dialableUri(room, "Room");

	const bobToRoom = await dial(roomUri, bobHost);
	bobToRoom.serve().catch(() => {});
	bobToRoom.publish("dm", dmBehavior);
	const bobDir = await bobToRoom.fetch(DIRECTORY);
	let registered = false;
	const regInbox = bobToRoom.spawn((verb, args) => {
		if (verb === NOTIFY && args[0] === "registered") registered = true;
		return null;
	});
	await bobToRoom.send(bobDir, REGISTER, ["bob", bobLocator, regInbox]);
	await until(() => registered, "the room to register Bob");

	if (bobInbound !== 0) {
		fail(
			`expected 0 inbound connections after register (no dial-back), saw ${bobInbound}`,
		);
	}

	const carol = await dial(roomUri);
	carol.serve().catch(() => {});
	const carolDir = await carol.fetch(DIRECTORY);
	const introduced = await carol.send(carolDir, INTRODUCE, ["bob"]);
	if (!(introduced instanceof Ref)) {
		fail("introduce did not return a capability");
	}

	await until(() => bobInbound >= 1, "Carol's direct connection to Bob");
	if (bobInbound !== 1) {
		fail(
			`expected Carol's redeem to add exactly one direct connection, Bob saw ${bobInbound}`,
		);
	}

	await carol.send(introduced, DM, ["Carol", DM_TEXT]);
	await until(
		() => bobInbox.includes(DM_TEXT),
		"Bob to receive Carol's direct DM",
	);

	console.log("rooms-dm-iroh demo OK:");
	console.log(
		`  • the room introduced Carol to Bob over iroh (handoff-give with direct addresses)`,
	);
	console.log(
		`  • Bob accepted 1 iroh connection: Carol's direct dial (register fetched dm on the room session)`,
	);
	console.log(
		`  • Carol's DM reached Bob over her own encrypted-QUIC connection`,
	);

	carol.close();
	bobToRoom.close();
	room.close();
	bob.close();
	await Promise.allSettled([bobAccept, roomServe]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
