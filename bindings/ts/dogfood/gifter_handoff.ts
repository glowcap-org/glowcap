// Glowcap-only three-party handoff (TCP): the gifter half, end to end, with
// glowcap as all three parties, with no Goblins and no manual export bookkeeping.
//
//   Exporter  (Bob)    publishes a Host-published "dm" inbox and listens.
//   Gifter    (Broker) holds Bob's dm and exposes an "introducer".
//   Recipient (Carol)  asks the broker to introduce her, transparently redeems
//                      the give, and DMs Bob *directly*.
//
// The proof: Carol's message reaches Bob's inbox, and it travels on Carol's own
// direct connection to Bob. The broker is never in the message path. This is
// the exporter half of ADR-0039 the engine's swiss re-resolution makes possible:
// the gift is deposited on the broker-to-Bob connection and withdrawn on the
// separate Carol-to-Bob connection, against one host-wide object identity.

import process from "node:process";
import { Ref, Runtime } from "@glowcap/runtime";
import { listen, locator, provider } from "@glowcap/tcp";

function fail(message: string): never {
	console.error(`gifter-handoff: FAIL, ${message}`);
	process.exit(1);
}

async function main(): Promise<void> {
	// ── Exporter (Bob): publishes a Host-published inbox, listens for dials ───────
	const inbox: string[] = [];
	const bob = await listen("127.0.0.1", 0);
	bob.host.publish("dm", (verb, args) => {
		if (verb === "tell") inbox.push(String(args[0]));
		return null;
	});
	const bobAccept = (async () => {
		for await (const session of bob) session.serve().catch(() => {});
	})();
	const bobPort = bob.port;

	// ── Gifter (Broker): holds Bob's dm, introduces members to it ────────────────
	const broker = await listen("127.0.0.1", 0);
	const brokerPort = broker.port;
	await using brokerRuntime = await Runtime.open({
		providers: [provider()],
		adoptHost: broker.host,
	});
	const brokerAccept = (async () => {
		for await (const session of broker) session.serve().catch(() => {});
	})();

	// The broker dials Bob as a member would (keyed with the broker node's own
	// identity) and fetches Bob's Host publication dm. The fetched ref's home is this
	// broker-to-Bob connection, so the broker can re-gift it.
	const brokerToBob = await brokerRuntime.connect(locator("127.0.0.1", bobPort));
	brokerToBob.serve().catch(() => {});
	const bobDm = await brokerToBob.fetch("dm");

	// Replace the alias with a decoy before any introduction: the gift must
	// retain the exact inbox the broker holds, not whatever the name resolves
	// to at withdrawal (ADR-0026's exact-object identity, on the binding path).
	const decoyInbox: string[] = [];
	bob.host.publish("dm", (verb, args) => {
		if (verb === "tell") decoyInbox.push(String(args[0]));
		return null;
	});

	// Returning Bob's dm to a *different* connection (Carol's) trips the
	// transparent gifter, which originates the three-party handoff.
	broker.host.publish(
		"introducer",
		(verb) => (verb === "introduce" ? bobDm : null),
	);

	// ── Recipient (Carol): get introduced, redeem transparently, DM directly ─────
	await using carolRuntime = await Runtime.open({ providers: [provider()] });
	const carol = await carolRuntime.connect(locator("127.0.0.1", brokerPort));
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
	if (decoyInbox.length !== 0) {
		fail(`the DM leaked to the alias's decoy (got ${JSON.stringify(decoyInbox)})`);
	}
	console.log(
		"gifter-handoff: OK, Carol DMed Bob's exact inbox via a broker introduction, across an alias replacement (broker never relayed)",
	);

	// ── Teardown ─────────────────────────────────────────────────────────────────
	await Promise.all([
		carol.close(), // closes Carol's dialed exporter connection too
		brokerToBob.close(),
		broker.close(),
		bob.close(),
	]);
	await Promise.allSettled([bobAccept, brokerAccept]);
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
