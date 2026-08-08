// Live three-party handoff over iroh, all in the Deno binding (ADR-0009), the
// Deno sibling of the Python/Racket `iroh_handoff` clients and the iroh
// companion of `deno-goblins-handoff`. It proves both halves of an iroh
// handoff through the binding's own surface: the gifter mints a
// `desc:handoff-give` whose exporter location names an iroh endpoint by a
// `direct-addresses` dial hint, and the recipient redeems it transparently by
// dialing that endpoint directly over encrypted QUIC.
//
// Topology — three iroh endpoints (separate identities) in one process, the
// relay-less `Direct` posture on loopback, so the gate is deterministic and
// flake-free (no discovery service, no network):
//   Exporter  binds an iroh endpoint and publishes a node-giftable `greeter`.
//   Gifter    binds its own endpoint, dials the exporter (sharing one node
//             identity), fetches the greeter, records the exporter's dialable
//             URI as the give's exporter location, and publishes an
//             `introducer` that returns the greeter.
//   Recipient binds its own endpoint, dials the gifter, asks the introducer
//             for the greeter, transparently redeems the give by dialing the
//             exporter directly, and calls it — the reply must echo its name.
//
// Returning the exporter's greeter (home = gifter↔exporter) on the
// recipient's connection trips the transparent gifter; the recipient's `send`
// resolves to an ordinary capability whose calls route straight to the
// exporter. The proof is the greeter's reply carrying the name the recipient
// sent.
//
// Needs `deno` plus the iroh ABI companion library (`zig build iroh-abi`); run
// via `zig build deno-iroh-handoff`.

import {
	connect,
	encodePeerLocator,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	Ref,
	type Session,
	TRANSPORT_IROH,
} from "@pancake/stack";
import { type IrohServer, listenIroh, Reachability } from "@pancake/iroh";
import { fail, parseOptionalPortArg } from "../_common/deno/helpers.ts";

const GATE = "deno-iroh-handoff";
const NAME = "deno-iroh-carol";

parseOptionalPortArg(GATE);

// Deterministic and in-process, so a stall is a bug; fail loud instead of
// parking the gate. Unref'd so the timer never holds the loop open.
const watchdog = setTimeout(() => fail(GATE, "timed out after 90s"), 90_000);
Deno.unrefTimer(watchdog);

/** An iroh endpoint reports its direct addresses asynchronously after bind;
 * wait for at least one before reading the dialable id+addresses, a give
 * with no direct-addresses hint is not dialable under the relay-less Direct
 * posture. */
async function dialable(server: IrohServer): Promise<[string, string]> {
	for (let i = 0; i < 1000; i++) {
		const addrs = server.directAddresses;
		if (addrs.length > 0) return [server.nodeId, addrs];
		await new Promise((r) => setTimeout(r, 20));
	}
	fail(GATE, "timed out waiting for an endpoint's direct addresses");
}

/** Serve every connection the server accepts for the life of the run, and
 * remember it so teardown can close it. Ends when the server closes. */
async function acceptLoopWithServed(server: IrohServer, served: Session[]): Promise<void> {
	for await (const conn of server) {
		conn.serve().catch(() => {});
		served.push(conn);
	}
}

/** The published actor: answer `greet` by echoing the caller's name. */
function greeter(verb: string, args: unknown[]): string | null {
	if (verb !== "greet") return null;
	return `hello ${String(args[0] ?? "")} over iroh handoff`;
}

// ── Exporter: a node-giftable greeter on its own endpoint ────────────────────
const exporter = listenIroh({ reachability: Reachability.Direct });
exporter.host.publishGiftable("greeter", greeter);
const [exporterId, exporterAddrs] = await dialable(exporter);
const exporterServed: Session[] = [];
const exporterAccept = acceptLoopWithServed(exporter, exporterServed);
console.log(`${GATE}: exporter published greeter on ${exporterId}`);

// ── Gifter: dials the exporter under one identity, re-gifts the greeter ─────
const gifter = listenIroh({ reachability: Reachability.Direct });
const [gifterId, gifterAddrs] = await dialable(gifter);
const exporterUri = formatPeerUri(
	TRANSPORT_IROH,
	exporterId,
	new Map([[HINT_DIRECT_ADDRESSES, exporterAddrs]]),
);
const toExporter = await connect(exporterUri, Reachability.Direct, gifter.host);
const greeterRef = await toExporter.fetch("greeter");
// The exporter's own signed session record names it by node id alone — not
// dialable under the relay-less Direct posture — so record its full dialable
// location (id + direct-addresses) as the give's exporter location.
toExporter.setExporterLocator(
	encodePeerLocator({
		transport: "iroh",
		designator: exporterId,
		directAddresses: exporterAddrs,
	}),
);
gifter.host.publishGiftable("introducer", (verb) => {
	if (verb !== "get-greeter") return null;
	return greeterRef;
});
const gifterServed: Session[] = [];
const gifterAccept = acceptLoopWithServed(gifter, gifterServed);
console.log(`${GATE}: gifter published introducer on ${gifterId}`);

// ── Recipient: dials the gifter, redeems the give by dialing the exporter ───
const gifterUri = formatPeerUri(
	TRANSPORT_IROH,
	gifterId,
	new Map([[HINT_DIRECT_ADDRESSES, gifterAddrs]]),
);
const recipient = await connect(gifterUri, Reachability.Direct);
const introducerRef = await recipient.fetch("introducer");
const granted = await recipient.send(introducerRef, "get-greeter", []);
if (!(granted instanceof Ref)) {
	fail(GATE, `introduction did not redeem to a capability: ${JSON.stringify(granted)}`);
}
console.log(`${GATE}: recipient redeemed the give, got the greeter as an ordinary ref`);

const reply = await recipient.send(granted, "greet", [NAME]);
if (typeof reply !== "string" || !reply.includes(NAME)) {
	fail(GATE, `greeter reply did not carry the name back: ${JSON.stringify(reply)}`);
}
console.log(`${GATE}: greeter replied: ${reply}`);

console.log(
	`${GATE} OK: the Deno binding minted an iroh handoff give and redeemed it by dialing the ` +
		"exporter directly over encrypted QUIC",
);

// Teardown: close the dialing connections, then every accepted connection,
// then the servers, closing a server ends its accept loop, which we await so
// no readiness fd reader outlives the endpoint it watches.
recipient.close();
toExporter.close();
for (const conn of [...exporterServed, ...gifterServed]) conn.close();
exporter.close();
gifter.close();
await Promise.allSettled([exporterAccept, gifterAccept]);
Deno.exit(0);
