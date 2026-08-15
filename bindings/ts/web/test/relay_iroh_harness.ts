// The iroh leg of the relay proof, parameterized over the relay program. A wasm
// browser peer holds a live OCapN session with a real iroh endpoint through a
// byte relay whose iroh leg dials the exporter over QUIC. One harness proves this
// for every runtime's relay; the relay under test is named on the command line.
//
// Three processes keep the module graphs honest:
//   serve_iroh_host.ts   native dlopen runtime; binds a real iroh endpoint
//                        (relay-less Direct on loopback) and publishes a greeter.
//   the relay            the program under test, dialing `?locator=<uri>` over
//                        iroh and piping bytes both ways without parsing them.
//   the probe            `iroh_relay_probe.ts` bundled through
//                        `browser-bundle.json`, so `@pancake/iroh` resolves to
//                        the browser arm exactly as a page's bundle does.
//
// The assertion is a fetch-and-call round trip through the whole chain.

import {
	fail,
	kill,
	parseHarnessArgs,
	readToken,
	ROOT,
	spawnNative,
	spawnRelay,
	WASM,
} from "./relay_harness_common.ts";

const HOST = new URL("./serve_iroh_host.ts", import.meta.url).pathname;
const PROBE = new URL("./iroh_relay_probe.ts", import.meta.url).pathname;
const BUNDLE_CONFIG = new URL("../browser-bundle.json", import.meta.url).pathname;

const inv = parseHarnessArgs(Deno.args);
const deadline = setTimeout(
	() => fail(`${inv.label} iroh relay scenario timed out after 120s`),
	120_000,
);
Deno.unrefTimer(deadline);

const host = spawnNative(HOST);
const relay = spawnRelay(inv);

try {
	const uri = await readToken(host, /IROH-HOST-READY (\S+)/);
	const relayPort = await readToken(relay, new RegExp(`${inv.marker} (\\d+)`));

	// Bundle the probe with the browser mapping, then run the bundle.
	const bundle = await new Deno.Command(Deno.execPath(), {
		args: [
			"bundle",
			"--platform",
			"browser",
			"--no-lock",
			"--quiet",
			"--config",
			BUNDLE_CONFIG,
			PROBE,
		],
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (bundle.code !== 0) {
		fail(`deno bundle of the probe failed: ${new TextDecoder().decode(bundle.stderr).trim()}`);
	}
	const bundlePath = await Deno.makeTempFile({ suffix: ".mjs" });
	await Deno.writeFile(bundlePath, bundle.stdout);

	const probe = await new Deno.Command(Deno.execPath(), {
		args: ["run", "--allow-read", "--allow-net", bundlePath, WASM, relayPort, uri],
		cwd: ROOT,
		stdout: "inherit",
		stderr: "inherit",
	}).output();
	await Deno.remove(bundlePath);
	if (probe.code !== 0) {
		fail(`probe did not complete the iroh relay round trip through the ${inv.label} relay`);
	}

	console.log(`OK: browser peer held a live iroh session through the ${inv.label} relay`);
	clearTimeout(deadline);
} finally {
	kill(host);
	kill(relay);
}
Deno.exit(0);
