// Per-binding keyed-relay rendezvous proof: the Deno (stack) binding
// cold-dials a non-listening peer by its key designator through the reference
// relay's rendezvous bridge (ADR-0088). The core classifies the locator as
// the `rendezvous` dial shape; the stack opens the WebSocket leg the
// locator's `rendezvous-relay` hint names, the one rendezvous routing
// authority.
//
// Run via `zig build deno-keyed-relay-rendezvous` (the harness passes
// `<locator>`).

import { GlowcapError, parseLocator, Runtime } from "@glowcap/runtime";
import { connector, keyed, provider } from "@glowcap/relay";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

if (Deno.args.length < 1) fail("usage: deno_client.ts <locator>");
const partner = parseLocator(Deno.args[Deno.args.length - 1]);
const wssRelayUrl = Deno.env.get("GLOWCAP_PROOF_WSS_RELAY_URL");
const wssCaFile = Deno.env.get("GLOWCAP_PROOF_WSS_RELAY_CA_FILE");

async function expectWssRefusal(
	route: string,
	trust: { readonly kind: "system" } | { readonly kind: "copied-pem"; readonly pem: Uint8Array },
	expectedCause: string,
): Promise<void> {
	await using runtime = await Runtime.open({ providers: [provider({ relayUrl: route, trust })] });
	let refused: unknown = null;
	let session: Awaited<ReturnType<typeof runtime.connect>> | null = null;
	try {
		session = await runtime.connect(keyed.locator(partner.designator, route));
	} catch (error) {
		refused = error;
	}
	if (session !== null) {
		await session.close();
		fail(`WSS unexpectedly accepted ${expectedCause}`);
	}
	if (!(refused instanceof GlowcapError)) fail(`WSS returned ${String(refused)}`);
	if (refused.carrierFailure?.phase !== "secureHandshake" || refused.carrierFailure.verificationFlags === 0) {
		fail(`WSS omitted secure-handshake verification detail: ${refused}`);
	}
	if (!refused.message.includes(expectedCause)) {
		fail(`WSS reported ${JSON.stringify(refused.message)}, expected ${expectedCause}`);
	}
}

let runtime: Runtime;
if (wssRelayUrl == null) {
	runtime = await Runtime.open({ connectors: [connector()] });
} else {
	if (wssCaFile == null) fail("WSS proof needs GLOWCAP_PROOF_WSS_RELAY_CA_FILE");
	const pem = await Deno.readFile(wssCaFile);
	const wrongHost = new URL(wssRelayUrl);
	wrongHost.hostname = "127.0.0.1";
	await expectWssRefusal(wrongHost.href, { kind: "copied-pem", pem }, "CertificateNameMismatch");
	await expectWssRefusal(wssRelayUrl, { kind: "system" }, "CertificateUntrusted");
	runtime = await Runtime.open({
		providers: [provider({ relayUrl: wssRelayUrl, trust: { kind: "copied-pem", pem } })],
	});
}
await using ownedRuntime = runtime;
const session = await ownedRuntime.connect(partner);
const serving = session.serve();
try {
	const greeter = await session.fetch("greeter");
	const reply = await session.send(greeter, "greet", ["deno"]);
	const expected = "hello deno, cold-dialed by rendezvous";
	if (reply !== expected) fail(`unexpected greeting: ${String(reply)}`);
} finally {
	await session.close();
	await serving;
}
console.log(
	"PASS: the Deno binding cold-dialed a registered peer by rendezvous — the core " +
		"used the locator's rendezvous-relay route, and the keyed session answered",
);
Deno.exit(0);
