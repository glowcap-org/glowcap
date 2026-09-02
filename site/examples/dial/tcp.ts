import { locator, provider } from "@glowcap/tcp";
import { Runtime } from "@glowcap/runtime";

// Plain TCP uses a cleartext host and port.
const partner = locator("127.0.0.1", 9099);

await using runtime = await Runtime.open({ providers: [provider()] });
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
