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

import { awaitMarker, fail, runProofOrFail } from "../_support/harness.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const LIB_DIR = new URL("../../../zig-out/lib/", import.meta.url).pathname;
const installedArchiveEnv = {
	GLOWCAP_LIB_DIR: LIB_DIR,
	...(Deno.build.os === "darwin" ? { DYLD_LIBRARY_PATH: LIB_DIR } : { LD_LIBRARY_PATH: LIB_DIR }),
};

const sep = Deno.args.indexOf("--");
const listenerArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (listenerArgv.length === 0) fail("harness needs a listener argv after --");

const outcome = await runProofOrFail({
	// The build owner stops this process at 30 seconds. Keep the diagnostic
	// deadline inside it, with room for process-group teardown.
	deadlineMs: 27_000,
	timeoutMessage: () => "noise-relay listen proof timed out after 27s",
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
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
	const relayPort = await awaitMarker(relay, "DENO-RELAY-READY", "relay");
	const relayUrl = `ws://localhost:${relayPort}/relay`;
	const registerUrl = `ws://localhost:${relayPort}/register`;

	const listener = processes.spawn(listenerArgv[0], {
		args: [...listenerArgv.slice(1), relayUrl, registerUrl],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
	const locator = await awaitMarker(listener, "RELAY-LISTENER-READY", "listener");

	const client = processes.spawn("deno", {
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
	});
	const clientCode = (await processes.status(client)).code;

	const listenerStatus = processes.status(listener);
	const listenerExited = await Promise.race([
		listenerStatus.then(() => true),
		new Promise<false>((resolve) => setTimeout(() => resolve(false), 5_000)),
	]);
	if (!listenerExited) {
		await processes.stop(listener);
	}
	return {
		clientCode,
		listenerCode: (await listenerStatus).code,
		listenerForcedClosed: !listenerExited,
	};
});
if (outcome.clientCode !== 0) fail(`dial client exited ${outcome.clientCode}`);
if (outcome.listenerForcedClosed) fail("listener did not close itself after the served session");
if (outcome.listenerCode !== 0) fail(`listener exited ${outcome.listenerCode}`);
console.log("PASS: the managed listener registered, advertised, and served a sealed session");
Deno.exit(0);
