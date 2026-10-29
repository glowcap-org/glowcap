// Per-binding noise-relay managed-listen proof, Deno half: `noise.listen`
// registers a fresh durable key at the reference relay and serves accepted
// Noise_XK-sealed sessions. Run by `harness.ts`, which appends
// `<relayUrl> <registerUrl>` and dials the printed locator.

import type { Argument } from "@glowcap/runtime";
import { noise } from "@glowcap/relay";

if (Deno.args.length < 2) {
	console.error("usage: deno_listener.ts <relayUrl> <registerUrl>");
	Deno.exit(2);
}
const [relayUrl, registerUrl] = Deno.args.slice(-2);

const seed = crypto.getRandomValues(new Uint8Array(32));
await using server = await noise.listen({ relayUrl, registerUrl, seed });

server.host.publish("greeter", (verb: string | null, args: Argument[]) => {
	if (verb !== "greet") throw new Error("no such method");
	if (args.length !== 1 || typeof args[0] !== "string") throw new Error("bad invocation");
	return `Hello, ${args[0]}`;
});
console.log(`RELAY-LISTENER-READY ${server.uri}`);

for await (const accepted of server) {
	await using session = accepted;
	await session.serve();
	break;
}
