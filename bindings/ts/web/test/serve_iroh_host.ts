// The iroh half of the browser-relay proof's native side: bind a real iroh
// endpoint (relay-less Direct on loopback), publish a greeter, print the
// dialable `ocapn://` URI, and serve every accepted session until killed.
// Runs in its own process so this native dlopen graph never shares a module
// graph with the wasm browser peer under test.

import { listenIroh, Reachability } from "@pancake/iroh";

const server = listenIroh({ reachability: Reachability.Direct });
server.host.publishGiftable("greeter", (verb: string, args: unknown[]) => {
	if (verb !== "greet") return null;
	return `hello ${String(args[0] ?? "")} over iroh relay`;
});

// Direct addresses surface asynchronously; the URI is dialable once they do.
for (let i = 0; i < 1000 && server.directAddresses.length === 0; i++) {
	await new Promise((r) => setTimeout(r, 20));
}
if (server.directAddresses.length === 0) {
	console.error("serve_iroh_host: no direct addresses after 20s");
	Deno.exit(1);
}
console.log(`IROH-HOST-READY ${server.uri}`);

for await (const session of server) {
	session.serve().catch(() => {});
}
