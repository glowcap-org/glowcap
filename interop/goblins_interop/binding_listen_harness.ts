// Shared external-listener proof: start one language binding, wait for its
// ephemeral TCP port, and let a real Spritely Goblins vat enliven and call the
// Host-wide actor it published. The language child must serve exactly one
// session and retire itself after the caller closes.
//
// Run: deno run -A interop/goblins_interop/binding_listen_harness.ts -- <listener argv...>

const ROOT = new URL("../../", import.meta.url).pathname;
const LIB_DIR = new URL("../../zig-out/lib/", import.meta.url).pathname;
const ACTOR_SWISS = "glowcapActorSwissnumABCDEFGH1234";
const DIALER = "conformance/goblins-peer/racket/glowcap-actor-call.rkt";
const EXPECTED = 'DIAL OK: "Hello from a binding host: world"';
const installedArchiveEnv = {
	GLOWCAP_LIB_DIR: LIB_DIR,
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
	() => fail("binding Goblins-listen proof timed out after 120s"),
	120_000,
);

async function awaitPort(child: Deno.ChildProcess): Promise<number> {
	const prefix = "GOBLINS-LISTENER-READY ";
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) fail("listener exited before publishing its port");
		buffered += value;
		let newline: number;
		while ((newline = buffered.indexOf("\n")) !== -1) {
			const line = buffered.slice(0, newline).trim();
			buffered = buffered.slice(newline + 1);
			if (line.length !== 0) console.log(`  [listener] ${line}`);
			if (!line.startsWith(prefix)) continue;
			const port = Number(line.slice(prefix.length));
			if (!Number.isInteger(port) || port < 1 || port > 65535) {
				fail(`listener published an invalid port: ${JSON.stringify(line)}`);
			}
			void (async () => {
				try {
					while (!(await reader.read()).done) { /* drain */ }
				} catch { /* child ended */ }
			})();
			return port;
		}
	}
}

const listener = new Deno.Command(listenerArgv[0], {
	args: listenerArgv.slice(1),
	cwd: ROOT,
	env: installedArchiveEnv,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

let dialCode = 1;
let dialOutput = "";
let listenerCode: number | null = null;
let listenerForcedClosed = false;
try {
	const port = await awaitPort(listener);
	const dial = await new Deno.Command("racket", {
		args: [DIALER, String(port), ACTOR_SWISS, "world", "0"],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	}).output();
	dialCode = dial.code;
	dialOutput = new TextDecoder().decode(dial.stdout).trim();
	if (dialOutput !== "") console.log(`  [goblins] ${dialOutput}`);
} finally {
	clearTimeout(deadline);
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

if (dialCode !== 0) fail(`Goblins dialer exited ${dialCode}`);
if (!dialOutput.includes(EXPECTED)) {
	fail(`Goblins read ${JSON.stringify(dialOutput)}, expected ${JSON.stringify(EXPECTED)}`);
}
if (listenerForcedClosed) fail("listener did not close itself after the served session");
if (listenerCode !== 0) fail(`listener exited ${listenerCode}`);
console.log("PASS: Goblins dialed, enlivened, and called the binding-hosted actor");
