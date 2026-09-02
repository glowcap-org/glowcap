import type { Argument } from "@glowcap/runtime";
import { noise } from "@glowcap/tcp";

// Same bind as keyed-tcp; Noise_XK seals every accepted CapTP stream.
const seed = crypto.getRandomValues(new Uint8Array(32));
await using server = await noise.listen("127.0.0.1", 9099, { seed });
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
