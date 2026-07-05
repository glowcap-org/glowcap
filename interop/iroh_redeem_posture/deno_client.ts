// Hermetic proof that a recipient's *configured redeem posture* governs how a
// hint-less iroh handoff give is dialed (ADR-0009), all in the Deno binding —
// the sibling of the Rust/Python/Racket `iroh_redeem_posture` clients.
//
// A give whose exporter location names the exporter by node id alone (no
// `direct-addresses`) cannot be dialed `Direct` — the recipient must resolve the
// id. Which discovery posture it resolves under is the recipient node's
// `setRedeemReachability` knob: `Discovery` (n0 relays + DNS/pkarr) by default,
// lowerable for a deployment policy. This gate sets that knob to
// `LocalDiscovery` — an in-process address book, no network — and proves the
// hint-less redeem dials by id through it and withdraws the gift.
//
// It is a *discriminating* proof: with the default `Discovery`, the hint-less
// redeem would reach for n0's public relays + DNS and fail with no internet; the
// redeem succeeds here only because `dialExporter` honors the configured
// posture. Deterministic and flake-free — three `LocalDiscovery` endpoints in
// one process sharing one address book.
//
// Topology:
//   Exporter  binds a `LocalDiscovery` endpoint, publishes a node-giftable
//             `greeter`.
//   Gifter    binds its own endpoint, dials the exporter by id (one node
//             identity), fetches the greeter, and records the exporter's
//             id-only location as the give's exporter location — a hint-less
//             give.
//   Recipient binds its own endpoint, sets its redeem posture to
//             `LocalDiscovery`, dials the gifter, asks for the greeter, redeems
//             the hint-less give by resolving the exporter's id through the
//             book, and calls it.
//
// Needs `deno` plus the iroh ABI companion library (`zig build iroh-abi`); run
// via `zig build deno-iroh-redeem-posture`.

import { type Connection, encodePeerLocator, Ref } from "@pancake/stack";
import { connectIroh, listenIroh, Reachability } from "@pancake/iroh";

const NAME = "deno-redeem-posture-carol";

function fail(msg: string): never {
	console.error(`deno-iroh-redeem-posture FAILED: ${msg}`);
	Deno.exit(1);
}

// The gate takes no arguments; `-Dport` is meaningless for an in-process
// local-discovery run, so accept and ignore a `--port=` for build parity.
for (const a of Deno.args) {
	if (!a.startsWith("--port=")) fail(`unknown argument '${a}'`);
}

// The whole run is in-process and deterministic, so a stall is a bug; fail loud
// instead of parking the gate. Unref'd so the timer never holds the loop open.
const watchdog = setTimeout(() => fail("timed out after 90s"), 90_000);
Deno.unrefTimer(watchdog);

// Serve every connection a server accepts for the life of the run.
async function acceptLoop(server: AsyncIterable<Connection>): Promise<void> {
	for await (const conn of server) conn.serve().catch(() => {});
}

// ── Exporter: a node-giftable greeter on its own local-discovery endpoint ─────
const exporter = listenIroh(Reachability.LocalDiscovery);
exporter.node.publishGiftable("greeter", (verb, args) => {
	if (verb !== "greet") return null;
	return `hello ${String(args[0] ?? "")} over a configured-posture redeem`;
});
const exporterId = exporter.nodeId;
const exporterAccept = acceptLoop(exporter);
console.log(`deno-iroh-redeem-posture: exporter published greeter on ${exporterId}`);

// ── Gifter: dials the exporter by id, re-gifts the greeter under a hint-less give
const gifter = listenIroh(Reachability.LocalDiscovery);
const gifterId = gifter.nodeId;
const toExporter = await connectIroh(exporterId, "", Reachability.LocalDiscovery, gifter.node);
toExporter.serve().catch(() => {});
const greeterRef = await toExporter.fetch("greeter");
// Record the exporter's location by node id alone — no direct-addresses. This
// is what forces the recipient down the configured-posture redeem path instead
// of a Direct dial.
toExporter.setExporterLocator(
	encodePeerLocator({ transport: "iroh", designator: exporterId }),
);
gifter.node.publishGiftable("introducer", (verb) => {
	if (verb !== "get-greeter") return null;
	return greeterRef;
});
const gifterAccept = acceptLoop(gifter);
console.log(`deno-iroh-redeem-posture: gifter published introducer on ${gifterId}`);

// ── Recipient: configures its redeem posture, then redeems the hint-less give ─
const recipient = await connectIroh(gifterId, "", Reachability.LocalDiscovery);
recipient.serve().catch(() => {});
// The knob under test: without it, the hint-less redeem defaults to Discovery
// (n0 relays + DNS) and would fail with no network. The node is shared, so this
// reaches the connection that performs the redeem.
recipient.node.setRedeemReachability(Reachability.LocalDiscovery);
const introducer = await recipient.fetch("introducer");
const granted = await recipient.send(introducer, "get-greeter", []);
if (!(granted instanceof Ref)) {
	fail(`introduction did not redeem to a capability: ${JSON.stringify(granted)}`);
}
console.log(
	"deno-iroh-redeem-posture: recipient redeemed the hint-less give under its " +
		"configured LocalDiscovery posture, got the greeter as an ordinary ref",
);

const reply = await recipient.send(granted, "greet", [NAME]);
if (typeof reply !== "string" || !reply.includes(NAME)) {
	fail(`greeter reply did not carry the name back: ${JSON.stringify(reply)}`);
}
console.log(`deno-iroh-redeem-posture: greeter replied: ${reply}`);

console.log(
	"deno-iroh-redeem-posture OK: a hint-less iroh give was redeemed by id through " +
		"the recipient's configured LocalDiscovery posture (default Discovery would need the network)",
);

// Teardown: dialing connections first — the recipient's close also tears down
// the node-dialed exporter connection its redeem opened — then the servers,
// whose close releases every accepted connection still borrowing their loop.
recipient.close();
toExporter.close();
exporter.close();
gifter.close();
await Promise.allSettled([exporterAccept, gifterAccept]);
Deno.exit(0);
