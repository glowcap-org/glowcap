// The browser side of the iroh-relay proof, bundled through
// `browser-bundle.json` so its module graph is exactly a page's: the wasm
// peer, the stack, and `@pancake/iroh` mapped to the browser arm — no dlopen
// anywhere. It dials the iroh locator through the ordinary `connect`, which
// lands in the browser arm's `_connectIroh` and rides the relay named by
// `init({ relayUrl })`. Argv: <wasm-path> <relay-port> <ocapn-uri>.

import { init } from "@pancake/web";

const [wasmPath, relayPort, uri] = Deno.args;
if (!wasmPath || !relayPort || !uri) {
	console.error("usage: iroh_relay_probe <wasm-path> <relay-port> <ocapn-uri>");
	Deno.exit(2);
}

const stack = await init({
	wasm: await Deno.readFile(wasmPath),
	relayUrl: (locator) =>
		`ws://127.0.0.1:${relayPort}/relay?locator=${encodeURIComponent(locator)}`,
});

// A raw iroh dial names its reachability; the locator carries direct
// addresses, so the relay reaches the exporter directly. In the browser the
// posture only unlocks the core's dial plan — the relay owns how it actually
// dials — but the core still requires the caller to state it, exactly as a
// native iroh `connect` does.
const session = await stack.connect(uri, stack.Reachability.Direct);
const greeter = await session.fetch("greeter");
const reply = await session.send(greeter, "greet", ["browser"]);
const expected = "hello browser over iroh relay";
if (reply !== expected) {
	console.error(`FAIL: expected "${expected}", got "${String(reply)}"`);
	Deno.exit(1);
}
console.log("IROH-RELAY-PROBE-OK");
await session.close();
Deno.exit(0);
