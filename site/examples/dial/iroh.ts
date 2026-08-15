import { Runtime } from "@pancake/runtime";
import { locator, provider, Reachability } from "@pancake/iroh";

// Discovery resolves a bare iroh node ID without an address hint.
const nodeId = "<64 lowercase hex characters from the server>";
const partner = locator(nodeId);

await using runtime = await Runtime.open({
	providers: [provider({ reachability: Reachability.Discovery })],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
