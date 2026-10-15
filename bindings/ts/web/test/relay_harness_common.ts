// Shared spine for the three relay contract harnesses (tcp, backpressure,
// iroh). Each harness spawns a relay program named on its own command line and
// drives one scenario against it, so one harness proves the same contract for
// every runtime's relay: the Deno reference, the Python relay, the Rust relay,
// and any binding added later. The per-runtime differences (which program, its
// ready marker, its environment) are arguments, not forked copies.
//
// Argument shape, parsed by `parseHarnessArgs`:
//   --marker <READY-MARKER> --label <Name> [--env KEY=VALUE]... -- <relay argv...>
// Everything after `--` is the relay program and its args (the trailing port
// argument is "0" for an ephemeral port). `--env` pairs are merged into the
// relay subprocess environment (the Rust iroh relay needs `LD_LIBRARY_PATH`).

const ROOT = new URL("../../../../", import.meta.url).pathname;

export { ROOT };
export const WASM = `${ROOT}zig-out/wasm/glowcap_host.wasm`;

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

/** One relay program to launch and the marker it prints when listening. */
export interface RelayInvocation {
	marker: string;
	label: string;
	env: Record<string, string>;
	command: string[];
}

/** Parse the harness command line into a relay invocation. */
export function parseHarnessArgs(argv: string[]): RelayInvocation {
	let marker: string | null = null;
	let label: string | null = null;
	const env: Record<string, string> = {};
	let i = 0;
	for (; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--") {
			i++;
			break;
		} else if (arg === "--marker") {
			marker = argv[++i];
		} else if (arg === "--label") {
			label = argv[++i];
		} else if (arg === "--env") {
			const pair = argv[++i] ?? "";
			const eq = pair.indexOf("=");
			if (eq === -1) fail(`--env expects KEY=VALUE, got "${pair}"`);
			env[pair.slice(0, eq)] = pair.slice(eq + 1);
		} else {
			fail(`unexpected harness argument "${arg}"`);
		}
	}
	const command = argv.slice(i);
	if (marker === null || label === null || command.length === 0) {
		fail("usage: --marker <M> --label <L> [--env K=V]... -- <relay argv...>");
	}
	return { marker, label, env, command };
}

/** Launch the relay program under test, from the repository root. */
export function spawnRelay(inv: RelayInvocation): Deno.ChildProcess {
	return new Deno.Command(inv.command[0], {
		args: inv.command.slice(1),
		cwd: ROOT,
		env: inv.env,
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
}

/** Spawn an FFI side process (dlopen runtime; needs FFI), from the root. */
export function spawnFfi(script: string): Deno.ChildProcess {
	return new Deno.Command(Deno.execPath(), {
		args: [
			"run",
			"--allow-ffi",
			"--unstable-ffi",
			"--allow-read",
			"--allow-net",
			"--allow-env",
			script,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
}

/** Read the first whitespace-delimited token after `marker` from a process's
 * stdout, then keep draining so the child never blocks on a full pipe. */
export async function readToken(proc: Deno.ChildProcess, marker: RegExp): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) throw new Error(`process exited before ${marker}`);
		buf += decoder.decode(value);
		const match = buf.match(marker);
		if (match) {
			(async () => {
				while (!(await reader.read()).done) { /* discard */ }
			})().catch(() => {});
			return match[1];
		}
	}
}

/** Kill a child, tolerating an already-exited process. */
export function kill(proc: Deno.ChildProcess): void {
	try {
		proc.kill("SIGTERM");
	} catch {
		// already exited
	}
}
