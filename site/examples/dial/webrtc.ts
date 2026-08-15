import { Runtime } from "@pancake/runtime";
import { connector, locator, type SignalingAuthority } from "@pancake/webrtc";

declare const signaling: SignalingAuthority;
const peerKey = "<64 lowercase hex characters from the peer>";
const partner = locator(peerKey);

await using runtime = await Runtime.open({
	connectors: [connector(signaling)],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
