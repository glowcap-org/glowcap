// The shared stand for the keyed-relay rendezvous proof family (ADR-0088):
// start the reference relay (`bindings/ts/relay/serve.ts`, which owns the
// `/register` and `?rendezvous=` legs), start the registered non-listening
// peer, then run one binding's client with its complete hinted locator appended
// to argv. Each client configures an unusable local fallback, so success proves
// the target's advertised relay route selected the bridge.
//
// Run: deno run -A bindings/proofs/keyed_relay_rendezvous/harness.ts [--native-wss] -- <client argv...>

const ROOT = new URL("../../../", import.meta.url).pathname;
const TLS_CERT = new URL("../../../test/net/fixtures/tls_server.pem", import.meta.url).pathname;
const TLS_KEY = new URL("../../../test/net/fixtures/tls_server.key", import.meta.url).pathname;
const TLS_ROOT = new URL("../../../test/net/fixtures/tls_root.pem", import.meta.url).pathname;
const LIB_DIR = new URL("../../../zig-out/lib/", import.meta.url).pathname;
const installedArchiveEnv = {
	PANCAKE_LIB_DIR: LIB_DIR,
	...(Deno.build.os === "darwin" ? { DYLD_LIBRARY_PATH: LIB_DIR } : { LD_LIBRARY_PATH: LIB_DIR }),
};

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

const sep = Deno.args.indexOf("--");
const harnessArgs = sep === -1 ? [...Deno.args] : Deno.args.slice(0, sep);
if (harnessArgs.some((arg) => arg !== "--native-wss")) {
	fail(`unknown harness option: ${harnessArgs.find((arg) => arg !== "--native-wss")}`);
}
const nativeWss = harnessArgs.includes("--native-wss");
const clientArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (clientArgv.length === 0) fail("harness needs a client argv after --");

const deadline = setTimeout(
	() => fail("keyed-relay rendezvous proof timed out after 120s"),
	120_000,
);

// Read `child`'s stdout line by line until `prefix` appears, echoing everything
// so a red run carries the child's own diagnostics; resolve the line's tail.
async function awaitMarker(
	child: Deno.ChildProcess,
	prefix: string,
	who: string,
): Promise<string> {
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) fail(`${who} exited before printing ${prefix}`);
		buffered += value;
		let newline: number;
		while ((newline = buffered.indexOf("\n")) !== -1) {
			const line = buffered.slice(0, newline).trim();
			buffered = buffered.slice(newline + 1);
			if (line.length !== 0) console.log(`  [${who}] ${line}`);
			if (line.startsWith(prefix)) {
				// Keep draining in the background so the child never blocks on a
				// full stdout pipe.
				void (async () => {
					try {
						while (!(await reader.read()).done) { /* drain */ }
					} catch { /* child ended */ }
				})();
				return line.slice(prefix.length).trim();
			}
		}
	}
}

const relay = new Deno.Command("deno", {
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
			PANCAKE_RELAY_TLS_CERT: TLS_CERT,
			PANCAKE_RELAY_TLS_KEY: TLS_KEY,
		}
		: installedArchiveEnv,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

let peer: Deno.ChildProcess | null = null;
let clientCode = 1;
try {
	const relayPort = await awaitMarker(relay, "DENO-RELAY-READY", "relay");
	const relayUrl = `${nativeWss ? "wss" : "ws"}://localhost:${relayPort}/relay`;

	peer = new Deno.Command("deno", {
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
	}).spawn();
	const locator = await awaitMarker(peer, "REGISTERED-PEER-READY", "peer");

	const client = new Deno.Command(clientArgv[0], {
		args: [...clientArgv.slice(1), locator],
		cwd: ROOT,
		env: nativeWss
			? {
				...installedArchiveEnv,
				PANCAKE_PROOF_NATIVE_RELAY_URL: relayUrl,
				PANCAKE_PROOF_NATIVE_RELAY_CA_FILE: TLS_ROOT,
			}
			: installedArchiveEnv,
		stdout: "inherit",
		stderr: "inherit",
	}).spawn();
	clientCode = (await client.status).code;
} finally {
	clearTimeout(deadline);
	try {
		peer?.kill();
	} catch { /* already gone */ }
	try {
		relay.kill();
	} catch { /* already gone */ }
	await peer?.status;
	await relay.status;
}
if (clientCode !== 0) fail(`client exited ${clientCode}`);
console.log("PASS: harness relayed a green client run");
Deno.exit(0);
