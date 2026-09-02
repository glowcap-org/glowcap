import { locator, provider } from "@glowcap/onion";
import { Runtime } from "@glowcap/runtime";

// glowcap starts no Tor; point the provider at an existing SOCKS endpoint.
const partner = locator("<56-character onion service id>");

await using runtime = await Runtime.open({
	providers: [provider({ socks: "/run/tor/socks" })],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
