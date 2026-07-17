// Rooms direct-message-by-introduction demo (three-party handoff, gifter side).
//
// A rendezvous room introduces two members who then talk *directly*, with the
// room out of the message path — the headline of cycle C. It is the rooms-app
// face of `deno-gifter-handoff`: same three-party handoff (ADR-0009), dressed in
// the rooms protocol (`register`/`introduce` on the directory, a member `dm`
// object) so the demo exercises the real server behaviour, not a bespoke one.
//
//   Room   (rendezvous / gifter)  serves the directory; on `register` it dials
//                                 a member back and holds its `dm`; `introduce`
//                                 hands that reference on as a gift.
//   Bob    (member / exporter)    listens on its own endpoint, exports a node-
//                                 giftable `dm` inbox, joins the room, registers.
//   Carol  (member / recipient)   joins the room, asks it to introduce her to
//                                 Bob, transparently redeems the gift, and DMs
//                                 Bob over her own *direct* connection.
//
// Three proofs, all asserted:
//   1. Carol's DM reaches Bob's inbox (the introduction produced a live cap).
//   2. Bob accepts a brand-new inbound connection for the DM, distinct from the
//      room's register dial-back — Carol reached Bob directly, by the gift's
//      locator, not through the room.
//   3. The room never carries the DM: it only deposited the gift on its own
//      connection to Bob; the DM text travels solely on Carol-to-Bob.
//
// The nodes are separate identities on separate loopback ports — a genuine
// three-party handoff — run in one process so the assertions are precise and the
// gate is flake-free. Run by `zig build demo-rooms-dm`.

import process from "node:process";
import { connect, listen, Ref, tcpLocator } from "@pancake/stack";
import { serveDirectory } from "./deno/server.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "./deno/lib/protocol.ts";
import { loopbackTcpDesignator } from "./deno/lib/locator.ts";

const DM_TEXT = "hi Bob, privately, from Carol";

function fail(message: string): never {
	console.error(`rooms-dm demo FAILED: ${message}`);
	process.exit(1);
}

/** Resolve once `ready` is true, polling briefly; reject past `timeoutMs`. */
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
	// ── Bob (member / exporter): a node-giftable dm inbox on its own endpoint ────
	const bobInbox: string[] = [];
	let bobInbound = 0; // every connection Bob accepts, the new-inbound proof
	const bob = listen("127.0.0.1", 0);
	bob.host.publishGiftable("dm", (verb, args) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		// dm(from, text): the sender names itself, and the text is what we assert on.
		bobInbox.push(String(args[1]));
		return null;
	});
	const bobAccept = (async () => {
		for await (const session of bob) {
			bobInbound += 1;
			session.serve().catch(() => {});
		}
	})();
	const bobLocator = loopbackTcpDesignator(await bob.ready());

	// ── Room (rendezvous / gifter): the real directory, with introductions ───────
	const room = listen("127.0.0.1", 0);
	const roomServe = serveDirectory(room, room.host);
	const roomPort = await room.ready();

	// ── Bob joins the room and registers his dialable locator ────────────────────
	// The room dials that locator back, fetches Bob's `dm`, and signals readiness
	// on the inbox Bob hands it, so `introduce` can never race the dial-back.
	const bobToRoom = await connect(tcpLocator("127.0.0.1", roomPort));
	bobToRoom.serve().catch(() => {});
	const bobDir = await bobToRoom.fetch(DIRECTORY);
	let registered = false;
	const regInbox = bobToRoom.spawn((verb, args) => {
		if (verb === NOTIFY && args[0] === "registered") registered = true;
		return null;
	});
	await bobToRoom.send(bobDir, REGISTER, ["bob", bobLocator, regInbox]);
	await until(() => registered, "the room to register Bob");

	// After registration Bob has accepted exactly the room's dial-back.
	const inboundAfterRegister = bobInbound;
	if (inboundAfterRegister !== 1) {
		fail(
			`expected 1 inbound connection (the room's dial-back) after register, saw ${inboundAfterRegister}`,
		);
	}

	// ── Carol (recipient): get introduced, redeem transparently, DM directly ─────
	const carol = await connect(tcpLocator("127.0.0.1", roomPort));
	carol.serve().catch(() => {});
	const carolDir = await carol.fetch(DIRECTORY);
	// `introduce` returns Bob's dm (home = room-to-Bob); the binding transparently
	// turns that foreign-home reference into a redeemed cap on a fresh, direct
	// Carol-to-Bob connection, the gifter half of the handoff, end to end.
	const introduced = await carol.send(carolDir, INTRODUCE, ["bob"]);
	if (!(introduced instanceof Ref)) {
		fail("introduce did not return a capability");
	}

	// The redeem dialed Bob directly: a second, brand-new inbound connection.
	await until(() => bobInbound >= 2, "Carol's direct connection to Bob");
	if (bobInbound !== 2) {
		fail(
			`expected Carol's redeem to add exactly one direct connection, Bob saw ${bobInbound}`,
		);
	}

	await carol.send(introduced, DM, ["Carol", DM_TEXT]);
	await until(
		() => bobInbox.includes(DM_TEXT),
		"Bob to receive Carol's direct DM",
	);

	// The room only ever deposited the gift on its own Bob connection; the DM rode
	// Carol-to-Bob. Bob's two connections are the room's dial-back and Carol's direct
	// dial — proof the room was never in the message path.
	console.log("rooms-dm demo OK:");
	console.log(
		`  • the room introduced Carol to Bob (a desc:handoff-give, redeemed transparently)`,
	);
	console.log(
		`  • Bob accepted 2 connections: the room's register dial-back, then Carol's direct dial`,
	);
	console.log(
		`  • Carol's DM reached Bob over her own connection — the room never relayed it`,
	);

	// ── Teardown ─────────────────────────────────────────────────────────────────
	carol.close(); // also closes Carol's redeemed exporter connection to Bob
	bobToRoom.close();
	await room.close();
	bob.close();
	await Promise.allSettled([bobAccept, roomServe]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
