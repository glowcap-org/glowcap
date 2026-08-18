import { Runtime } from "@pancake/runtime";
import { keyed, provider } from "@pancake/relay";

// The key names the peer; the hint names the relay that can reach it.
const peerKey = "<64 lowercase hex characters from the server>";
const relayUrl = "ws://192.0.2.10:8080/relay";
const partner = keyed.locator(peerKey, relayUrl);

await using runtime = await Runtime.open({
	providers: [provider({ relayUrl })],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
