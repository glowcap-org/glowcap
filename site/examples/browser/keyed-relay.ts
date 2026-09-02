import { connector, keyed } from "@glowcap/relay";
import { init } from "@glowcap/web";

const relayUrl = "wss://relay.example/rendezvous";
const web = await init({
	wasm: fetch("/glowcap_host.wasm"),
	connectors: [connector()],
});
await using runtime = web.runtime;
const partner = keyed.locator("<64 lowercase hex characters>", relayUrl);
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
