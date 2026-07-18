// Rooms direct-message-by-introduction demo (three-party handoff, gifter side).
//
// A rendezvous room introduces two members who then talk *directly*, with the
// room out of the message path — the headline of cycle C. It is the rooms-app
// face of `deno-gifter-handoff`: same three-party handoff (ADR-0009), dressed in
// the rooms protocol (`register`/`introduce` on the directory, a member `dm`
// object) so the demo exercises the real server behaviour, not a bespoke one.
//
//   Room   (rendezvous / gifter)  serves the directory; on `register` it fetches
//                                 `dm` on the registrar session; `introduce`
//                                 hands that reference on as a gift.
//   Bob    (member / exporter)    one Host that listens and dials the room,
//                                 publishes `dm` on the room session, registers.
//   Carol  (member / recipient)   joins the room, asks it to introduce her to
//                                 Bob, transparently redeems the gift, and DMs
//                                 Bob over her own *direct* connection.
//
// Three proofs, all asserted:
//   1. Carol's DM reaches Bob's inbox (the introduction produced a live cap).
//   2. Bob accepts a brand-new inbound connection for the DM — Carol reached
//      Bob directly by the gift's locator, not through the room.
//   3. The room never carries the DM: register did not dial Bob; the DM text
//      travels solely on Carol-to-Bob.
//
// Run by `zig build demo-rooms-dm`.

import process from "node:process";
import { connect, Host, listen, Ref, tcpLocator } from "@pancake/stack";
import { serveDirectory } from "./deno/server.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "./deno/lib/protocol.ts";
import { loopbackTcpDesignator } from "./deno/lib/locator.ts";

const DM_TEXT = "hi Bob, privately, from Carol";

function fail(message: string): never {
	console.error(`rooms-dm demo FAILED: ${message}`);
	process.exit(1);
}

async function until(
	ready: () => boolean,
	what: string,
	timeoutMs = 10_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!ready()) {
		if (Date.now() > deadline) fail(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 10));
	}
}

async function main(): Promise<void> {
	const bobInbox: string[] = [];
	let bobInbound = 0;
	const bobHost = new Host();
	const dmBehavior = (verb: string, args: unknown[]) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		bobInbox.push(String(args[1]));
		return null;
	};
	bobHost.publishGiftable("dm", dmBehavior);
	const bob = listen("127.0.0.1", 0, bobHost);
	const bobAccept = (async () => {
		for await (const session of bob) {
			bobInbound += 1;
			session.serve().catch(() => {});
		}
	})();
	const bobLocator = loopbackTcpDesignator(await bob.ready());

	const room = listen("127.0.0.1", 0);
	const roomServe = serveDirectory(room);
	const roomPort = await room.ready();

	const bobToRoom = await connect(tcpLocator("127.0.0.1", roomPort), undefined, bobHost);
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

	const carol = await connect(tcpLocator("127.0.0.1", roomPort));
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

	console.log("rooms-dm demo OK:");
	console.log(
		`  • the room introduced Carol to Bob (a desc:handoff-give, redeemed transparently)`,
	);
	console.log(
		`  • Bob accepted 1 connection: Carol's direct dial (register fetched dm on the room session)`,
	);
	console.log(
		`  • Carol's DM reached Bob over her own connection — the room never relayed it`,
	);

	carol.close();
	bobToRoom.close();
	await room.close();
	bob.close();
	await Promise.allSettled([bobAccept, roomServe]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
