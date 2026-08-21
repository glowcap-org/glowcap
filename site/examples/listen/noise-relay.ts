import type { Argument } from "@pancake/runtime";
import { noise } from "@pancake/relay";

// Register this key at the relay; Noise_XK seals every accepted CapTP stream.
const seed = crypto.getRandomValues(new Uint8Array(32));
await using server = await noise.listen({
	relayUrl: "wss://relay.example/relay",
	registerUrl: "wss://relay.example/register",
	seed,
});
// From here, the CapTP workflow is transport-independent.
console.log(server.uri); // hand this locator to partners

function greeter(verb: string, args: Argument[]): string {
	if (verb !== "greet") throw new Error("no such method");
	if (args.length !== 1 || typeof args[0] !== "string") {
		throw new Error("bad invocation");
	}
	return `Hello, ${args[0]}`;
}

server.host.publishGiftable("greeter", greeter);
for await (const accepted of server) {
	await using session = accepted;
	await session.serve();
}
