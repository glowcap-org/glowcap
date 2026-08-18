// Per-binding keyed-relay rendezvous proof: the Deno (stack) binding
// cold-dials a non-listening peer by its key designator through the reference
// relay's rendezvous bridge (ADR-0088). The core classifies the locator as
// the `rendezvous` dial shape; the stack opens the WebSocket leg the
// locator's `rendezvous-relay` hint names, the one rendezvous routing
// authority.
//
// Run via `zig build deno-keyed-relay-rendezvous` (the harness passes
// `<locator>`).

import { PancakeError, parseLocator, Runtime } from "@pancake/runtime";
import { connector, keyed, provider } from "@pancake/relay";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

if (Deno.args.length < 1) fail("usage: deno_client.ts <locator>");
const partner = parseLocator(Deno.args[Deno.args.length - 1]);
const nativeRelayUrl = Deno.env.get("PANCAKE_PROOF_NATIVE_RELAY_URL");
const nativeCaFile = Deno.env.get("PANCAKE_PROOF_NATIVE_RELAY_CA_FILE");

async function expectNativeRefusal(
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
		fail(`native WSS unexpectedly accepted ${expectedCause}`);
	}
	if (!(refused instanceof PancakeError)) fail(`native WSS returned ${String(refused)}`);
	if (refused.carrierFailure?.phase !== "secureHandshake" || refused.carrierFailure.verificationFlags === 0) {
		fail(`native WSS omitted secure-handshake verification detail: ${refused}`);
	}
	if (!refused.message.includes(expectedCause)) {
		fail(`native WSS reported ${JSON.stringify(refused.message)}, expected ${expectedCause}`);
	}
}

let runtime: Runtime;
if (nativeRelayUrl == null) {
	runtime = await Runtime.open({ connectors: [connector()] });
} else {
	if (nativeCaFile == null) fail("native WSS proof needs PANCAKE_PROOF_NATIVE_RELAY_CA_FILE");
	const pem = await Deno.readFile(nativeCaFile);
	const wrongHost = new URL(nativeRelayUrl);
	wrongHost.hostname = "127.0.0.1";
	await expectNativeRefusal(wrongHost.href, { kind: "copied-pem", pem }, "CertificateNameMismatch");
	await expectNativeRefusal(nativeRelayUrl, { kind: "system" }, "CertificateUntrusted");
	runtime = await Runtime.open({
		providers: [provider({ relayUrl: nativeRelayUrl, trust: { kind: "copied-pem", pem } })],
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
