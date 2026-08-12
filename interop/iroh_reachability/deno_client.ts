// Live real-internet iroh reachability proof in the Deno binding, the binding
// sibling of the Zig `iroh-reachability` driver. Two iroh endpoints in one
// process reach each other by node id ALONE over n0's public relays and
// DNS/pkarr discovery: no direct-address hints, no in-process address book.
//
// Both endpoints bind with the `Discovery` posture. The server publishes its
// node info to pkarr on bind; the client dials the server by its 64-hex node
// id with an empty hint set, so a session that opens proves the dial was
// resolved over real discovery infrastructure and carried over a real relay /
// hole-punched path, not hinted, not loopback-booked. The client's dial rides
// the `connect(locator)` `Discovery` retry that settles while the publish
// propagates.
//
// Not a hermetic gate. This step touches public n0 infrastructure
// (`*.relay.iroh.network`, `dns.iroh.link`), and discovery-propagation timing
// makes it unsuitable for `zig build check`. It runs only as the opt-in
// `zig build deno-iroh-reachability`, the same posture as
// `deno-iroh-loop`, so it can never make `check` flaky.
//
// Needs `deno` plus the iroh ABI companion library (`zig build iroh-abi`) and
// a live internet connection; run via `zig build deno-iroh-reachability`.

import { connect, formatPeerUri, type Session, TRANSPORT_IROH } from "@pancake/stack";
import { type IrohServer, listenIroh, Reachability } from "@pancake/iroh";
import { fail, parseOptionalPortArg } from "../_common/deno/helpers.ts";

const GATE = "deno-iroh-reachability";
const NAME = "deno-iroh-world";

parseOptionalPortArg(GATE);

// Discovery propagation over real n0 infrastructure can take a while; fail
// loud on a genuine stall instead of parking the gate. Unref'd so the timer
// never holds the loop open.
const watchdog = setTimeout(() => fail(GATE, "timed out after 120s"), 120_000);
Deno.unrefTimer(watchdog);

/** The published actor: answer `greet` by echoing the caller's name. */
function greeter(verb: string, args: unknown[]): string | null {
	if (verb !== "greet") return null;
	return `hello ${String(args[0] ?? "")} over iroh discovery`;
}

/** Serve every session the server accepts for the life of the run, and
 * remember it so teardown can close it. Ends when the server closes. */
async function acceptLoop(server: IrohServer, served: Session[]): Promise<void> {
	for await (const session of server) {
		session.serve().catch(() => {});
		served.push(session);
	}
}

// ── Server: a giftable greeter, dialable by node id alone over discovery ────
const server = await listenIroh({ reachability: Reachability.Discovery });
server.host.publishGiftable("greeter", greeter);
const serverId = server.nodeId;
const served: Session[] = [];
const serverTask = acceptLoop(server, served);
console.log(
	`${GATE}: server published greeter on ${serverId} (pkarr-published; no direct addrs shared)`,
);

// ── Client: dial by node id ALONE — empty hints — over real n0 discovery ────
const client = await connect(formatPeerUri(TRANSPORT_IROH, serverId), Reachability.Discovery);
console.log(`${GATE}: client dialed by node id alone and opened the keyed session`);

const greeterRef = await client.fetch("greeter");
const reply = await client.send(greeterRef, "greet", [NAME]);
if (typeof reply !== "string" || !reply.includes(NAME)) {
	fail(GATE, `greeter reply did not carry the name back: ${JSON.stringify(reply)}`);
}
console.log(`${GATE}: greeter replied: ${reply}`);

console.log(
	`${GATE} OK: the Deno binding reached a peer by node id alone over n0 relays + DNS/pkarr ` +
		"discovery, no direct-address hints",
);

// Teardown: close the dialing connection, then every accepted connection, then
// the server, closing the server ends its accept loop, which we await so no
// readiness fd reader outlives the endpoint it watches.
client.close();
for (const session of served) session.close();
server.close();
await serverTask;
Deno.exit(0);
