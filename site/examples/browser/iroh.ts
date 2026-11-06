import { init } from "@glowcap/web";

const web = await init({
	wasm: fetch("/glowcap_host.wasm"),
	relayUrl: (locator) => `wss://relay.example/relay?locator=${encodeURIComponent(locator)}`,
});
await using runtime = web.runtime;
// Copy the server's full URI, including direct-addresses reachable from the relay.
const peerUri = "ocapn://<64 lowercase hex characters>.iroh?direct-addresses=127.0.0.1%3A5000";
const partner = web.parseLocator(peerUri);
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
