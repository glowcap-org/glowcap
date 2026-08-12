import { listenNoiseTcp } from "@pancake/stack";

// Same bind as keyed-tcp; Noise_XK seals every accepted CapTP stream.
const seed = crypto.getRandomValues(new Uint8Array(32));
const server = listenNoiseTcp("127.0.0.1", 9099, seed);
console.log(server.uri); // hand this locator to partners
for await (const session of server) {
	session.publish("greeter", (_verb, args) => `hello, ${args[0]}`);
	session.serve().catch(() => {});
}
