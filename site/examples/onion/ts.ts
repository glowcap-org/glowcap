import type { Argument } from "@pancake/runtime";
import { listen } from "@pancake/onion";

// pancake starts no Tor. Name an already-running daemon's SOCKS (and control to host).
await using server = await listen({
	socks: "/run/tor/socks",
	control: "/run/tor/control",
});
const _serviceKey = server.serviceKey; // persist securely to restore this service
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
