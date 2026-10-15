import { init } from "@glowcap/web";

const web = await init({
	wasm: fetch("/glowcap_host.wasm"),
	relayUrl: (locator) => `wss://relay.example/?locator=${encodeURIComponent(locator)}`,
});
await using runtime = web.runtime;
// `@glowcap/iroh` loads a compiled library through FFI, so a page parses the locator on the web runtime.
const partner = web.parseLocator("ocapn://<64 lowercase hex characters>.iroh");
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
