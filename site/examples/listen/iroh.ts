import type { Argument } from "@pancake/runtime";
import { type IrohConfig, listen, Reachability } from "@pancake/iroh";

// Bind a key, not a place. Partners can dial this node id from anywhere.
const config: IrohConfig = { reachability: Reachability.Discovery };
await using server = await listen(config);
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
