import { listenKeyedTcp } from "@pancake/stack";

// Key designator, cleartext CapTP. Reuse a 32-byte seed to keep the same key.
const seed = crypto.getRandomValues(new Uint8Array(32));
const server = listenKeyedTcp("127.0.0.1", 9099, seed);
console.log(server.uri); // hand this locator to partners
for await (const session of server) {
	session.publish("greeter", (_verb, args) => `hello, ${args[0]}`);
	session.serve().catch(() => {});
}
