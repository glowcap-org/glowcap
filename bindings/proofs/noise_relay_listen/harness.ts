// The shared stand for the noise-relay managed-listen proof family: start the
// reference relay (`bindings/ts/relay/serve.ts`, which owns the `/register`
// and `?rendezvous=` legs), run one binding's *listener* with the relay and
// registration URLs appended to argv, wait for its advertised locator, then
// dial that locator with the known-good Deno client and require the greeting.
// Success proves the binding's managed listen helper registered the durable
// key, held the registration open, and served an accepted Noise_XK-sealed
// session end to end.
//
// Run: deno run -A bindings/proofs/noise_relay_listen/harness.ts -- <listener argv...>

const ROOT = new URL("../../../", import.meta.url).pathname;
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
const listenerArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (listenerArgv.length === 0) fail("harness needs a listener argv after --");

const deadline = setTimeout(
	() => fail("noise-relay listen proof timed out after 120s"),
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
	env: installedArchiveEnv,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

let listener: Deno.ChildProcess | null = null;
let clientCode = 1;
try {
	const relayPort = await awaitMarker(relay, "DENO-RELAY-READY", "relay");
	const relayUrl = `ws://localhost:${relayPort}/relay`;
	const registerUrl = `ws://localhost:${relayPort}/register`;

	listener = new Deno.Command(listenerArgv[0], {
		args: [...listenerArgv.slice(1), relayUrl, registerUrl],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
	const locator = await awaitMarker(listener, "RELAY-LISTENER-READY", "listener");

	const client = new Deno.Command("deno", {
		args: [
			"run",
			"-A",
			"--unstable-ffi",
			"bindings/proofs/noise_relay_listen/dial_client.ts",
			locator,
		],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "inherit",
		stderr: "inherit",
	}).spawn();
	clientCode = (await client.status).code;
} finally {
	clearTimeout(deadline);
	try {
		listener?.kill();
	} catch { /* already gone */ }
	try {
		relay.kill();
	} catch { /* already gone */ }
	await listener?.status;
	await relay.status;
}
if (clientCode !== 0) fail(`dial client exited ${clientCode}`);
console.log("PASS: the managed listener registered, advertised, and served a sealed session");
Deno.exit(0);
