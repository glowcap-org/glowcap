import { connect, noiseTcpLocator } from "@pancake/stack";

// Same TCP sockets as keyed dialing; Noise_XK seals the CapTP stream.
const partner = noiseTcpLocator(
	"<64 hex chars>",
	"127.0.0.1",
	9099,
);

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
