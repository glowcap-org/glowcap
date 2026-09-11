// The shared stand for the keyed-relay rendezvous proof family (ADR-0088):
// start the reference relay (`bindings/ts/relay/serve.ts`, which owns the
// `/register` and `?rendezvous=` legs), start the registered non-listening
// peer, then run one binding's client with its complete hinted locator appended
// to argv. Each client configures an unusable local fallback, so success proves
// the target's advertised relay route selected the bridge.
//
// Run: deno run -A bindings/proofs/keyed_relay_rendezvous/harness.ts [--native-wss] -- <client argv...>

import { awaitMarker, fail, runProofOrFail } from "../_support/harness.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const TLS_CERT = new URL("../../../test/net/fixtures/tls_server.pem", import.meta.url).pathname;
const TLS_KEY = new URL("../../../test/net/fixtures/tls_server.key", import.meta.url).pathname;
const TLS_ROOT = new URL("../../../test/net/fixtures/tls_root.pem", import.meta.url).pathname;
const LIB_DIR = new URL("../../../zig-out/lib/", import.meta.url).pathname;
const installedArchiveEnv = {
	GLOWCAP_LIB_DIR: LIB_DIR,
	...(Deno.build.os === "darwin" ? { DYLD_LIBRARY_PATH: LIB_DIR } : { LD_LIBRARY_PATH: LIB_DIR }),
};

const sep = Deno.args.indexOf("--");
const harnessArgs = sep === -1 ? [...Deno.args] : Deno.args.slice(0, sep);
if (harnessArgs.some((arg) => arg !== "--native-wss")) {
	fail(`unknown harness option: ${harnessArgs.find((arg) => arg !== "--native-wss")}`);
}
const nativeWss = harnessArgs.includes("--native-wss");
const clientArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (clientArgv.length === 0) fail("harness needs a client argv after --");

const clientCode = await runProofOrFail({
	// The build owner stops this process at 30 seconds. Keep the diagnostic
	// deadline inside it, with room for process-group teardown.
	deadlineMs: 27_000,
	timeoutMessage: () => "keyed-relay rendezvous proof timed out after 27s",
}, async (processes) => {
	const relay = processes.spawn("deno", {
		args: [
			"run",
			"--allow-net",
			"--allow-ffi",
			"--allow-env",
			"--allow-read",
			"bindings/ts/relay/serve.ts",
			"0",
		],
		cwd: ROOT,
		env: nativeWss
			? {
				...installedArchiveEnv,
				GLOWCAP_RELAY_TLS_CERT: TLS_CERT,
				GLOWCAP_RELAY_TLS_KEY: TLS_KEY,
			}
			: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
	const relayPort = await awaitMarker(relay, "DENO-RELAY-READY", "relay");
	const relayUrl = `${nativeWss ? "wss" : "ws"}://localhost:${relayPort}/relay`;

	const peer = processes.spawn("deno", {
		args: [
			"run",
			...(nativeWss ? ["--unsafely-ignore-certificate-errors=localhost"] : []),
			"--allow-net",
			"--allow-ffi",
			"--allow-env",
			"--allow-read",
			"bindings/proofs/keyed_relay_rendezvous/registered_peer.ts",
			relayUrl,
		],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
	const locator = await awaitMarker(peer, "REGISTERED-PEER-READY", "peer");

	const client = processes.spawn(clientArgv[0], {
		args: [...clientArgv.slice(1), locator],
		cwd: ROOT,
		env: nativeWss
			? {
				...installedArchiveEnv,
				GLOWCAP_PROOF_NATIVE_RELAY_URL: relayUrl,
				GLOWCAP_PROOF_NATIVE_RELAY_CA_FILE: TLS_ROOT,
			}
			: installedArchiveEnv,
		stdout: "inherit",
		stderr: "inherit",
	});
	return (await processes.status(client)).code;
});
if (clientCode !== 0) fail(`client exited ${clientCode}`);
console.log("PASS: harness relayed a green client run");
Deno.exit(0);
