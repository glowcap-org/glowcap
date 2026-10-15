import { Runtime } from "@glowcap/runtime";
import { locator } from "@glowcap/webrtc";
import { provider, type SignalingAuthority } from "@glowcap/webrtc/driver";

// Your signaling carries the offer and each candidate to the peer the locator
// names, over a path you already hold, such as an OCapN capability both peers
// can reach, and brings the answer and the peer's candidates back. In a
// browser, `connector(signaling)` from `@glowcap/webrtc` takes its place.
declare const signaling: SignalingAuthority;
const peerKey = "<64 lowercase hex characters from the peer>";
const partner = locator(peerKey);

await using runtime = await Runtime.open({
	providers: [provider(signaling)],
});
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
