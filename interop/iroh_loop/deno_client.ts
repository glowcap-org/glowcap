// Live iroh scale proof for the Deno binding: many concurrent connections
// served from one readiness loop (ADR-0057), the Deno sibling of the Zig
// `zig build iroh-loop` gate.
//
// The iroh netlayer has one I/O model — an event-driven readiness loop. This
// gate proves it through the binding: one `IrohServer` runs a single loop that
// registers the endpoint's readiness fd with the Deno event loop and serves
// every accepted connection's peer from that one loop. Many clients dial it at
// once, each over its own iroh endpoint, fetch the published greeter, and call
// it several times. Every reply must come back correct — so the one server
// loop is provably multiplexing all the connections at once, not serving them
// one at a time.
//
// It exercises the whole loop surface live through the binding: the readiness
// fd, the records `drainReady` returns, non-blocking `tryAccept`, and
// `tryReadInto` / `tryWrite` with their WOULD_BLOCK re-arming. Teardown is
// non-blocking by construction, no parked read races a release.
//
// Needs `deno` plus the iroh ABI companion library (`zig build iroh-abi`); run
// via `zig build deno-iroh-loop`.

import { connect, formatPeerUri, type Session, TRANSPORT_IROH } from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { fail, parseOptionalPortArg } from "../_common/deno/helpers.ts";

const GATE = "deno-iroh-loop";

// Concurrent connections, each served on the one server loop; calls each makes
// before closing, several turns per connection so the proof is sustained
// multiplexing, not a single round trip. Mirrors the Zig iroh-loop gate.
const NUM_CONNS = 16;
const CALLS_PER_CONN = 4;
const GREETING = "hello over the iroh loop";

parseOptionalPortArg(GATE);

/** The published actor: answer `greet` with a static greeting. */
function greeter(verb: string): string | null {
	if (verb !== "greet") return null;
	return GREETING;
}

/** Accept every dial, publish this connection's greeter, and serve it, all
 * from the server's one readiness loop. Ends when the server closes. */
async function runAccepts(server: AsyncIterable<Session>, served: Session[]): Promise<void> {
	for await (const conn of server) {
		conn.publish("greeter", greeter);
		conn.serve().catch(() => {});
		served.push(conn);
	}
}

/** One client: bind its own iroh endpoint, dial the server by id alone (the
 * local-discovery book resolves it), fetch the greeter, and call it
 * `CALLS_PER_CONN` times, checking every reply. */
async function clientOnce(serverId: string): Promise<void> {
	const locator = formatPeerUri(TRANSPORT_IROH, serverId);
	const conn = await connect(locator, Reachability.LocalDiscovery);
	try {
		const greeterRef = await conn.fetch("greeter");
		for (let i = 0; i < CALLS_PER_CONN; i++) {
			const reply = await conn.send(greeterRef, "greet", ["world"]);
			if (reply !== GREETING) {
				throw new Error(`wrong reply: ${JSON.stringify(reply)}`);
			}
		}
	} finally {
		conn.close();
	}
}

const server = listenIroh(Reachability.LocalDiscovery);
const serverId = server.nodeId;
console.log(`${GATE}: server endpoint id ${serverId}`);

const served: Session[] = [];
const acceptTask = runAccepts(server, served);

// Fan out all clients at once: they share nothing, so the only thing that can
// serve them all is the one server loop multiplexing.
const results = await Promise.allSettled(
	Array.from({ length: NUM_CONNS }, () => clientOnce(serverId)),
);

// Bring the server-side connections and the server down so the gate never
// hangs and no fd reader outlives the endpoint it watches.
for (const conn of served) conn.close();
server.close();
await acceptTask;

const errors = results.filter((r) => r.status === "rejected");
if (errors.length > 0) {
	const first = errors[0] as PromiseRejectedResult;
	fail(GATE, `${errors.length}/${NUM_CONNS} client(s) failed; first: ${first.reason}`);
}

console.log(
	`${GATE}: OK, ${NUM_CONNS} concurrent iroh connections, ${CALLS_PER_CONN} calls each, ` +
		"served from one loop over the readiness fd + non-blocking frame I/O",
);

Deno.exit(0);
