import { connect } from "@pancake/stack";
import { Reachability } from "@pancake/iroh";

// Discovery resolves a bare iroh node ID without an address hint.
const partner = "ocapn://3b6a…da29.iroh";

const session = await connect(partner, Reachability.Discovery);
session.serve().catch(() => {});

const greeter = await session.fetch("greeter"); // a capability, by name
try {
	const reply = await session.send(greeter, "greet", ["world"]);
	console.log(reply);
} catch (reason) {
	console.error("the greeter refused:", reason);
}

session.close();
