// Live iroh scale proof for the Deno binding: many concurrent connections
// served from one readiness loop (ADR-0057), the Deno sibling of the Zig
// `zig build iroh-loop` gate.
//
// The iroh netlayer has one I/O model, an event-driven readiness loop. This
// gate proves it through the binding: one `IrohServer` runs a single loop that
// registers the endpoint's readiness fd with the Deno event loop and serves
// every accepted connection's peer from that one loop. Many clients dial it at
// once, each over its own iroh endpoint, fetch the published greeter, and call
// it several times. Every reply must come back correct, so the one server
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

import { formatPeerUri, Runtime, type Session, TRANSPORT_IROH } from "@glowcap/runtime";
import { dialLocatorForRelay, listen, locator, provider, Reachability } from "@glowcap/iroh";
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
	for await (const session of server) {
		session.publish("greeter", greeter);
		session.serve().catch(() => {});
		served.push(session);
	}
}

/** One client: bind its own iroh endpoint, dial the server by id alone (the
 * local-discovery book resolves it), fetch the greeter, and call it
 * `CALLS_PER_CONN` times, checking every reply. */
async function clientOnce(serverId: string): Promise<void> {
	const partner = locator(serverId);
	const runtime = await Runtime.open({
		providers: [provider({ reachability: Reachability.LocalDiscovery })],
	});
	const session = await runtime.connect(partner);
	try {
		const greeterRef = await session.fetch("greeter");
		for (let i = 0; i < CALLS_PER_CONN; i++) {
			const reply = await session.send(greeterRef, "greet", ["world"]);
			if (reply !== GREETING) {
				throw new Error(`wrong reply: ${JSON.stringify(reply)}`);
			}
		}
	} finally {
		session.close();
		await runtime.close();
	}
}

const server = await listen({ reachability: Reachability.LocalDiscovery, workerThreads: 1 });
const serverId = server.nodeId;
console.log(`${GATE}: server endpoint id ${serverId}`);

const served: Session[] = [];
const acceptTask = runAccepts(server, served);

// An accepted QUIC stream that sends no CapTP hello must consume one bounded
// handshake seat, not serialize every later admission behind its timeout.
const silent = await dialLocatorForRelay(
	formatPeerUri(TRANSPORT_IROH, serverId),
	Reachability.LocalDiscovery,
);
// QUIC streams are lazy: a valid but incomplete outer length prefix makes the
// stream visible while leaving the CapTP frame delimiter waiting for its tail.
await silent.write(new Uint8Array(["1".charCodeAt(0)]));
await Promise.race([
	clientOnce(serverId),
	new Promise<never>((_, reject) =>
		setTimeout(() => reject(new Error("silent peer serialized iroh admission")), 8_000)
	),
]);
silent.close();

// Fan out all clients at once: they share nothing, so the only thing that can
// serve them all is the one server loop multiplexing.
const results = await Promise.allSettled(
	Array.from({ length: NUM_CONNS }, () => clientOnce(serverId)),
);

// Bring the server-side connections and the server down so the gate never
// hangs and no fd reader outlives the endpoint it watches.
for (const session of served) await session.close();
await server.close();
await acceptTask;

const errors = results.filter((r) => r.status === "rejected");
if (errors.length > 0) {
	const first = errors[0] as PromiseRejectedResult;
	fail(GATE, `${errors.length}/${NUM_CONNS} client(s) failed; first: ${first.reason}`);
}

// Host teardown owns admission on every transport. Prove a waiter parked on
// iroh's reactor wakes terminally rather than keeping the endpoint alive.
const closing = await listen({
	reachability: Reachability.LocalDiscovery,
	workerThreads: 1,
});
const iterator = closing[Symbol.asyncIterator]();
const pendingAccept = iterator.next();
await Promise.resolve();
const closingHost = closing.host.close();
const closedAccept = await Promise.race([
	pendingAccept,
	new Promise<never>((_, reject) =>
		setTimeout(() => reject(new Error("Host close did not wake iroh accept")), 2_000)
	),
]);
if (!closedAccept.done) fail(GATE, "a released Host admitted an iroh session");
await closingHost;
closing.close();

console.log(
	`${GATE}: OK, ${NUM_CONNS} concurrent iroh connections, ${CALLS_PER_CONN} calls each, ` +
		"served from one loop over the readiness fd + non-blocking frame I/O",
);

Deno.exit(0);
