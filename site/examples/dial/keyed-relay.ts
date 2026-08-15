import { Runtime } from "@pancake/runtime";
import { keyed, provider } from "@pancake/relay";

// The key names the peer; the hint names the relay that can reach it.
const peerKey = "<64 lowercase hex characters from the server>";
const partner = keyed.locator(peerKey, "wss://relay.example/rendezvous");

await using runtime = await Runtime.open({
	providers: [provider({ relayUrl: "wss://relay.example/rendezvous" })],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
