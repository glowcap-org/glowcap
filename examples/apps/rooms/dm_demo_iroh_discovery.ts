// Rooms direct-message-by-introduction over iroh, dial-by-node-id (three-party
// handoff, gifter side, discovery posture).
//
// The discovery sibling of `dm_demo_iroh.ts`. Same three-party handoff (ADR-0009)
// and the same three proofs, but every hop reaches its partner by **node id
// alone** over iroh's real discovery infrastructure (n0 relays + DNS/pkarr) —
// the `Discovery` posture — instead of by direct-address hints. No address is
// ever passed around: a member advertises a bare `ocapn://<nodeid>.iroh` URI, the
// gift names the exporter by id with no hints, and the recipient resolves that id
// through discovery and dials whatever path it finds (relayed or hole-punched).
// This is the OCapN-inevitable shape — the node id is a self-authenticating
// designator, so naming the exporter by id is sufficient.
//
//   Room   (rendezvous / gifter)  binds a discovery endpoint, serves the
//                                 directory; on `register` it dials a member back
//                                 by id and holds its `dm`; `introduce` mints a
//                                 gift whose exporter location is the member's
//                                 node id alone (no direct-addresses).
//   Bob    (member / exporter)    binds its own discovery endpoint, exports a
//                                 node-giftable `dm` inbox, joins the room, and
//                                 registers its bare `ocapn://<nodeid>.iroh` URI.
//   Carol  (member / recipient)   joins the room, asks it to introduce her to
//                                 Bob, transparently redeems the gift by
//                                 resolving Bob's id through discovery, and DMs
//                                 him directly.
//
// Three proofs, all asserted (identical to the Direct gate):
//   1. Carol's DM reaches Bob's inbox (the introduction produced a live cap).
//   2. Bob accepts a brand-new inbound iroh connection for the DM, distinct from
//      the room's register dial-back — Carol reached Bob directly, by resolving
//      his id, not through the room.
//   3. The room never carries the DM: it only deposited the gift on its own
//      connection to Bob; the DM text travels solely on Carol<->Bob.
//
// NOT a hermetic gate. Like `zig build iroh-reachability`, this step touches
// public n0 infrastructure (`*.relay.iroh.network`, `dns.iroh.link`) and pkarr
// publish-propagation timing is seconds-scale and variable, so it can never be
// part of `zig build check`. It runs only as the opt-in
// `zig build demo-rooms-dm-iroh-discovery`. The deterministic, offline proof of
// the same handoff is `zig build demo-rooms-dm-iroh` (the `Direct` posture).

import process from "node:process";
import { formatPeerUri, Host, Ref } from "@pancake/stack";
import { IrohServer, listenIroh, Reachability } from "@pancake/iroh";
import { serveDirectory } from "./deno/server.ts";
import { dial } from "./deno/lib/locator.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "./deno/lib/protocol.ts";

const DM_TEXT = "hi Bob, privately, from Carol, by node id over iroh discovery";

function fail(message: string): never {
	console.error(`rooms-dm-iroh-discovery demo FAILED: ${message}`);
	process.exit(1);
}

/** Resolve once `ready` is true, polling briefly; reject past `timeoutMs`.
 * Generous by default: every dial here resolves a node id through real discovery
 * and retries while the partner's pkarr record propagates, which is seconds-scale
 * and variable. */
async function until(
	ready: () => boolean,
	what: string,
	timeoutMs = 150_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!ready()) {
		if (Date.now() > deadline) fail(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

/** The bare `ocapn://<nodeid>.iroh` URI — node id alone, no direct-address
 * hints — so a dialer must resolve it through discovery (the Discovery posture).
 */
function idOnlyUri(server: IrohServer): string {
	return formatPeerUri("iroh", server.nodeId);
}

async function main(): Promise<void> {
	// ── Bob (member / exporter): a node-giftable dm inbox on its own endpoint ────
	const bobInbox: string[] = [];
	let bobInbound = 0; // every connection Bob accepts, the new-inbound proof
	const bob = listenIroh(Reachability.Discovery);
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
	const bobLocator = idOnlyUri(bob);
	console.log(`rooms-dm-iroh-discovery: Bob published ${bobLocator} (id only)`);

	// ── Room (rendezvous / gifter): the real directory, with introductions ───────
	// One shared node across the listener and the directory behavior, so the
	// register dial-back and the introduce gift origination present one identity.
	const roomHost = new Host();
	const room = listenIroh(Reachability.Discovery, undefined, roomHost);
	const roomServe = serveDirectory(room, roomHost);
	const roomUri = idOnlyUri(room);
	console.log(`rooms-dm-iroh-discovery: Room published ${roomUri} (id only)`);

	// ── Bob joins the room and registers his bare id URI ─────────────────────────
	// The room resolves that id through discovery, dials Bob back, fetches his
	// `dm`, and signals readiness on the inbox Bob hands it, so `introduce` cannot
	// race the dial-back.
	const bobToRoom = await dial(roomUri);
	bobToRoom.serve().catch(() => {});
	const bobDir = await bobToRoom.fetch(DIRECTORY);
	let registered = false;
	const regInbox = bobToRoom.spawn((verb, args) => {
		if (verb === NOTIFY && args[0] === "registered") registered = true;
		return null;
	});
	await bobToRoom.send(bobDir, REGISTER, ["bob", bobLocator, regInbox]);
	await until(() => registered, "the room to register Bob (dial-back by id)");

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
	// `introduce` returns Bob's dm (home = room<->Bob); the binding transparently
	// turns that foreign-home reference into a redeemed cap on a fresh Carol<->Bob
	// iroh connection, the gifter half of the handoff, end to end, with the
	// exporter reached by resolving its node id through discovery (no hints).
	const introduced = await carol.send(carolDir, INTRODUCE, ["bob"]);
	if (!(introduced instanceof Ref)) {
		fail("introduce did not return a capability");
	}

	// The redeem resolved Bob's id and dialed him: a second, brand-new inbound.
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

	console.log("rooms-dm-iroh-discovery demo OK:");
	console.log(
		`  • the room introduced Carol to Bob over iroh discovery (a desc:handoff-give naming the exporter by node id alone, redeemed transparently)`,
	);
	console.log(
		`  • Bob accepted 2 iroh connections: the room's register dial-back, then Carol's direct dial — both reached by resolving an id, no addresses shared`,
	);
	console.log(
		`  • Carol's DM reached Bob over her own encrypted-QUIC connection — the room never relayed it`,
	);

	// ── Teardown ─────────────────────────────────────────────────────────────────
	// Close the dialing connections first — each owns its endpoint, so it releases
	// its connection then its netlayer in order — then the servers. Closing a
	// server stops its loop, which releases every accepted connection still
	// borrowing that server's netlayer before the netlayer is freed.
	carol.close(); // also closes Carol's redeemed exporter connection to Bob
	bobToRoom.close();
	room.close();
	bob.close();
	await Promise.allSettled([bobAccept, roomServe]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
