// Per-binding keyed-relay rendezvous proof: the Deno (stack) binding
// cold-dials a non-listening peer by its key designator through the reference
// relay's rendezvous bridge (ADR-0088). The core classifies the locator as
// the `rendezvous` dial shape; the stack opens the WebSocket leg the host's
// advertised locator names while the Host's fallback is deliberately dead.
//
// Run via `zig build deno-keyed-relay-rendezvous` (the harness passes
// `<locator>`).

import { connect, Host } from "@pancake/stack";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

if (Deno.args.length < 1) fail("usage: deno_client.ts <locator>");
const locator = Deno.args[Deno.args.length - 1];

const host = new Host();
host.setRendezvousUrl((id) => `ws://127.0.0.1:1/relay?rendezvous=${id}`);
const session = await connect(locator, undefined, host);
session.serve().catch(() => {});
try {
	const greeter = await session.fetch("greeter");
	const reply = await session.send(greeter, "greet", ["deno"]);
	const expected = "hello deno, cold-dialed by rendezvous";
	if (reply !== expected) fail(`unexpected greeting: ${String(reply)}`);
} finally {
	session.close();
}
console.log(
	"PASS: the Deno binding cold-dialed a registered peer by rendezvous — the core " +
		"used the locator's rendezvous-relay route instead of the dead Host fallback, " +
		"and the keyed session answered",
);
Deno.exit(0);
