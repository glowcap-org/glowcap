import { locator } from "@pancake/tcp";
import { init } from "@pancake/web";

const web = await init({
	wasm: fetch("/pancake_host.wasm"),
	// A page cannot open raw TCP, so a relay carries the bytes.
	wsUrl: (host, port) => `ws://127.0.0.1:9000/?to=${host}:${port}`,
});
await using runtime = web.runtime;
const partner = locator("127.0.0.1", 9099);
// From here, the CapTP workflow is transport-independent.
await using session = await runtime.connect(partner);
const greeter = await session.fetch("greeter"); // a capability this peer published
const reply = await session.send(greeter, "greet", ["world"]);
console.log(reply);
