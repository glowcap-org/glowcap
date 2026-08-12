import { type IrohConfig, listenIroh, Reachability } from "@pancake/iroh";

// Bind a key, not a place. Partners can dial this node id from anywhere.
const config: IrohConfig = { reachability: Reachability.Discovery };
const server = await listenIroh(config);
console.log(server.uri); // hand this locator to partners
for await (const session of server) {
	session.publish("greeter", (_verb, args) => `hello, ${args[0]}`);
	session.serve().catch(() => {});
}
