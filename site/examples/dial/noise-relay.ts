import { Runtime } from "@pancake/runtime";
import { noise, provider } from "@pancake/relay";

// Noise_XK seals the session end to end; the relay forwards ciphertext.
const peerKey = "<64 lowercase hex characters from the server>";
const partner = noise.locator(peerKey, "wss://relay.example/rendezvous");

await using runtime = await Runtime.open({
	providers: [provider({ relayUrl: "wss://relay.example/rendezvous" })],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
