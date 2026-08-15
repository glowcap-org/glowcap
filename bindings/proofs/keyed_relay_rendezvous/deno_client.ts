// Per-binding keyed-relay rendezvous proof: the Deno (stack) binding
// cold-dials a non-listening peer by its key designator through the reference
// relay's rendezvous bridge (ADR-0088). The core classifies the locator as
// the `rendezvous` dial shape; the stack opens the WebSocket leg the
// locator's `rendezvous-relay` hint names, the one rendezvous routing
// authority.
//
// Run via `zig build deno-keyed-relay-rendezvous` (the harness passes
// `<locator>`).

import { parseLocator, Runtime } from "@pancake/runtime";
import { connector } from "@pancake/relay";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

if (Deno.args.length < 1) fail("usage: deno_client.ts <locator>");
const partner = parseLocator(Deno.args[Deno.args.length - 1]);

await using runtime = await Runtime.open({ connectors: [connector()] });
const session = await runtime.connect(partner);
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
		"used the locator's rendezvous-relay route, and the keyed session answered",
);
Deno.exit(0);
