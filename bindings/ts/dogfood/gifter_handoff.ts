// Pancake-only three-party handoff (TCP): the gifter half, end to end, with
// pancake as all three parties — no Goblins, no manual export bookkeeping.
//
//   Exporter  (Bob)    publishes a host-giftable "dm" inbox and listens.
//   Gifter    (Broker) holds Bob's dm and exposes an "introducer".
//   Recipient (Carol)  asks the broker to introduce her, transparently redeems
//                      the give, and DMs Bob *directly*.
//
// The proof: Carol's message reaches Bob's inbox, and it travels on Carol's own
// direct connection to Bob — the broker is never in the message path. This is
// the exporter half of ADR-0009 the engine's swiss re-resolution makes possible:
// the gift is deposited on the broker↔Bob connection and withdrawn on the
// separate Carol↔Bob connection, against one host-wide object identity.

import process from "node:process";
import { connect, listen, Ref, tcpLocator } from "@pancake/stack";

function fail(message: string): never {
	console.error(`gifter-handoff: FAIL, ${message}`);
	process.exit(1);
}

async function main(): Promise<void> {
	// ── Exporter (Bob): publishes a host-giftable inbox, listens for dials ───────
	const inbox: string[] = [];
	const bob = listen("127.0.0.1", 0);
	bob.host.publishGiftable("dm", (verb, args) => {
		if (verb === "tell") inbox.push(String(args[0]));
		return null;
	});
	const bobAccept = (async () => {
		for await (const conn of bob) conn.serve().catch(() => {});
	})();
	const bobPort = await bob.ready();

	// ── Gifter (Broker): holds Bob's dm, introduces members to it ────────────────
	const broker = listen("127.0.0.1", 0);
	const brokerPort = await broker.ready();
	const brokerAccept = (async () => {
		for await (const conn of broker) conn.serve().catch(() => {});
	})();

	// The broker dials Bob as a member would — keyed with the broker node's own
	// identity — and fetches Bob's giftable dm. The fetched ref's home is this
	// broker↔Bob connection, which is what lets the broker re-gift it.
	const brokerToBob = await connect(
		tcpLocator("127.0.0.1", bobPort),
		undefined,
		broker.host,
	);
	brokerToBob.serve().catch(() => {});
	const bobDm = await brokerToBob.fetch("dm");

	// Returning Bob's dm to a *different* connection (Carol's) trips the
	// transparent gifter, which originates the three-party handoff.
	broker.host.publishGiftable(
		"introducer",
		(verb) => (verb === "introduce" ? bobDm : null),
	);

	// ── Recipient (Carol): get introduced, redeem transparently, DM directly ─────
	const carol = await connect(tcpLocator("127.0.0.1", brokerPort));
	carol.serve().catch(() => {});
	const introducer = await carol.fetch("introducer");
	const introduced = await carol.send(introducer, "introduce", []);
	if (!(introduced instanceof Ref)) {
		fail("introduce did not return a capability");
	}

	// Carol DMs Bob. The redeemed ref's home is her *direct* connection to Bob, so
	// the send routes straight there, the broker is never in the message path.
	await carol.send(introduced, "tell", ["hello bob, from carol"]);

	if (!inbox.includes("hello bob, from carol")) {
		fail(
			`Bob's inbox did not receive the direct DM (got ${JSON.stringify(inbox)})`,
		);
	}
	console.log(
		"gifter-handoff: OK, Carol DMed Bob directly via a broker introduction (broker never relayed)",
	);

	// ── Teardown ─────────────────────────────────────────────────────────────────
	carol.close(); // closes Carol's dialed exporter connection too
	brokerToBob.close();
	broker.close();
	bob.close();
	await Promise.allSettled([bobAccept, brokerAccept]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
