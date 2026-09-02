import { noise, provider } from "@glowcap/tcp";
import { Runtime } from "@glowcap/runtime";

// Same TCP sockets as keyed dialing; Noise_XK seals the CapTP stream.
const peerKey = "<64 lowercase hex characters from the server>";
const partner = noise.locator(peerKey, "127.0.0.1", 9099);

await using runtime = await Runtime.open({ providers: [provider()] });
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
