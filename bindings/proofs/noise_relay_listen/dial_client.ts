// The known-good dial half of the noise-relay managed-listen proof: connect
// to the listener's advertised locator through the relay route it carries,
// fetch the host giftable, and require the greeting. The listener under test
// varies per binding; this client stays fixed so a red run points at the
// listener's binding.
//
// Run by `harness.ts` with the advertised `ocapn://` locator as argv.

import { parseLocator, Runtime } from "@pancake/runtime";
import { provider, routeFromLocator } from "@pancake/relay";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

if (Deno.args.length < 1) fail("usage: dial_client.ts <locator>");
const partner = parseLocator(Deno.args[Deno.args.length - 1]);
if (partner.transport !== "noise-relay") {
	fail(`listener advertised ${partner.transport}, expected noise-relay`);
}
const relayUrl = routeFromLocator(partner);
if (relayUrl == null) fail("the advertised locator carries no rendezvous-relay route");

await using runtime = await Runtime.open({ providers: [provider({ relayUrl })] });
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter");
const reply = await session.send(greeter, "greet", ["proof"]);
if (reply !== "Hello, proof") fail(`unexpected greeting: ${JSON.stringify(reply)}`);
console.log("PASS: dialed the managed listener and the sealed session answered");
