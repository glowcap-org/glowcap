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

import { awaitMarker, fail } from "../_support/harness.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const LIB_DIR = new URL("../../../zig-out/lib/", import.meta.url).pathname;
const installedArchiveEnv = {
	PANCAKE_LIB_DIR: LIB_DIR,
	...(Deno.build.os === "darwin" ? { DYLD_LIBRARY_PATH: LIB_DIR } : { LD_LIBRARY_PATH: LIB_DIR }),
};

const sep = Deno.args.indexOf("--");
const listenerArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (listenerArgv.length === 0) fail("harness needs a listener argv after --");

const deadline = setTimeout(
	() => fail("noise-relay listen proof timed out after 120s"),
	120_000,
);

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
let listenerCode: number | null = null;
let listenerForcedClosed = false;
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
	if (listener !== null) {
		const status = listener.status;
		const exited = await Promise.race([
			status.then(() => true),
			new Promise<false>((resolve) => setTimeout(() => resolve(false), 5_000)),
		]);
		if (!exited) {
			listenerForcedClosed = true;
			try {
				listener.kill();
			} catch { /* already gone */ }
		}
		listenerCode = (await status).code;
	}
	try {
		relay.kill();
	} catch { /* already gone */ }
	await relay.status;
}
if (clientCode !== 0) fail(`dial client exited ${clientCode}`);
if (listenerForcedClosed) fail("listener did not close itself after the served session");
if (listenerCode !== 0) fail(`listener exited ${listenerCode}`);
console.log("PASS: the managed listener registered, advertised, and served a sealed session");
Deno.exit(0);
