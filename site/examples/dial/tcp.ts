import { connect, tcpLocator } from "@pancake/stack";

// Plain TCP uses a cleartext host and port.
const partner = tcpLocator("127.0.0.1", 9099);

const session = await connect(partner);
session.serve().catch(() => {});

const greeter = await session.fetch("greeter"); // a capability, by name
try {
	const reply = await session.send(greeter, "greet", ["world"]);
	console.log(reply);
} catch (reason) {
	console.error("the greeter refused:", reason);
}

session.close();
