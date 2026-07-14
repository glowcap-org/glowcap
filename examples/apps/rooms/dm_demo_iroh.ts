// Rooms direct-message-by-introduction over iroh (three-party handoff, gifter
// side, cross-endpoint).
//
// The iroh sibling of `dm_demo.ts`: same three-party handoff (ADR-0009) and the
// same three proofs, but every hop rides iroh's encrypted QUIC instead of
// loopback TCP. It is the cross-process-shaped proof that a gift can name an
// exporter reachable only by a dial hint — an iroh endpoint's direct addresses —
// and a recipient redeems it by dialing that endpoint directly, with no
// discovery service and no relay (the `Direct` posture).
//
//   Room   (rendezvous / gifter)  binds an iroh endpoint, serves the directory;
//                                 on `register` it dials a member back over iroh
//                                 and holds its `dm`; `introduce` mints a gift
//                                 whose exporter location carries the member's
//                                 node id + direct-addresses.
//   Bob    (member / exporter)    binds its own iroh endpoint, exports a node-
//                                 giftable `dm` inbox, joins the room, registers
//                                 its `ocapn://…iroh?direct-addresses=…` URI.
//   Carol  (member / recipient)   joins the room, asks it to introduce her to
//                                 Bob, transparently redeems the gift by dialing
//                                 Bob's endpoint directly, and DMs him.
//
// Three proofs, all asserted (identical to the TCP gate):
//   1. Carol's DM reaches Bob's inbox (the introduction produced a live cap).
//   2. Bob accepts a brand-new inbound iroh connection for the DM, distinct from
//      the room's register dial-back — Carol reached Bob directly, by the gift's
//      direct-address hints, not through the room.
//   3. The room never carries the DM: it only deposited the gift on its own
//      connection to Bob; the DM text travels solely on Carol↔Bob.
//
// Three iroh endpoints (separate identities) in one process — a genuine
// cross-endpoint handoff over real QUIC sockets, run in one process so the
// assertions are precise and the gate is flake-free. Needs the iroh sidecar +
// the iroh C ABI companion. Run by `zig build demo-rooms-dm-iroh`.

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

/** Resolve once `ready` is true, polling briefly; reject past `timeoutMs`. */
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

/** An iroh endpoint reports its direct addresses asynchronously after bind, so
 * wait for at least one before reading the dialable URI, a URI with no
 * `direct-addresses` hint is not dialable under the relay-less Direct posture. */
async function dialableUri(server: IrohServer, what: string): Promise<string> {
	await until(() => server.directAddresses.length > 0, `${what} direct addresses`);
	return server.uri;
}

async function main(): Promise<void> {
	// ── Bob (member / exporter): a node-giftable dm inbox on its own endpoint ────
	const bobInbox: string[] = [];
	let bobInbound = 0; // every connection Bob accepts, the new-inbound proof
	// One seed for Bob's node identity and his endpoint (key unification), so
	// a dialer that pins the session identity to the dialed node id opens
	// cleanly.
	const bobSeed = crypto.getRandomValues(new Uint8Array(32));
	const bob = listenIroh(Reachability.Direct, bobSeed, new Host(bobSeed));
	bob.host.publishGiftable("dm", (verb, args) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		// dm(from, text): the sender names itself, and the text is what we assert on.
		bobInbox.push(String(args[1]));
		return null;
	});
	const bobAccept = (async () => {
		for await (const conn of bob) {
			bobInbound += 1;
			conn.serve().catch(() => {});
		}
	})();
	const bobLocator = await dialableUri(bob, "Bob");

	// ── Room (rendezvous / gifter): the real directory, with introductions ───────
	// One shared node across the listener and the directory behavior, so the
	// register dial-back and the introduce gift origination present one identity —
	// seeded with the endpoint's own seed (key unification), as above.
	const roomSeed = crypto.getRandomValues(new Uint8Array(32));
	const roomHost = new Host(roomSeed);
	const room = listenIroh(Reachability.Direct, roomSeed, roomHost);
	const roomServe = serveDirectory(room, roomHost);
	const roomUri = await dialableUri(room, "Room");

	// ── Bob joins the room and registers his dialable iroh URI ───────────────────
	// The room dials that URI back (id + direct-addresses), fetches Bob's `dm`, and
	// signals readiness on the inbox Bob hands it, so `introduce` cannot race the
	// dial-back.
	const bobToRoom = await dial(roomUri);
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
	const carol = await dial(roomUri);
	carol.serve().catch(() => {});
	const carolDir = await carol.fetch(DIRECTORY);
	// `introduce` returns Bob's dm (home = room↔Bob); the binding transparently
	// turns that foreign-home reference into a redeemed cap on a fresh, direct
	// Carol↔Bob iroh connection, the gifter half of the handoff, end to end, with
	// the exporter reached only by the gift's direct-address hints.
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

	console.log("rooms-dm-iroh demo OK:");
	console.log(
		`  • the room introduced Carol to Bob over iroh (a desc:handoff-give whose exporter location carries Bob's direct addresses, redeemed transparently)`,
	);
	console.log(
		`  • Bob accepted 2 iroh connections: the room's register dial-back, then Carol's direct dial`,
	);
	console.log(
		`  • Carol's DM reached Bob over her own encrypted-QUIC connection, the room never relayed it`,
	);

	// ── Teardown ─────────────────────────────────────────────────────────────────
	// Close the dialing connections first — each owns its endpoint, so it releases
	// its connection then its netlayer in order — then the servers. Closing a
	// server stops its loop, which releases every accepted connection still
	// borrowing that server's netlayer before the netlayer is freed, so no iroh
	// connection outlives the endpoint the C ABI would route it through. Identical
	// in shape to the TCP sibling's teardown.
	carol.close(); // also closes Carol's redeemed exporter connection to Bob
	bobToRoom.close();
	room.close();
	bob.close();
	await Promise.allSettled([bobAccept, roomServe]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
