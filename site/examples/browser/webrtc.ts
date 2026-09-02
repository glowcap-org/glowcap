import { connector, locator, type SignalingAuthority } from "@glowcap/webrtc";
import { init } from "@glowcap/web";

declare const signaling: SignalingAuthority;
const web = await init({
	wasm: fetch("/glowcap_host.wasm"),
	connectors: [connector(signaling)],
});
await using runtime = web.runtime;
const partner = locator("<64 lowercase hex characters from the peer>");
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
