import { listen } from "@pancake/stack";

// Plain TCP binds the host and port you choose.
const server = listen("127.0.0.1", 9099);
for await (const session of server) {
	session.publish("greeter", (_verb, args) => `hello, ${args[0]}`);
	session.serve().catch(() => {});
}
