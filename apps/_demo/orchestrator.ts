// Shared cross-language demo orchestrator helpers.

export interface CliOptions {
	pinPort: number;
	attach: boolean;
}

export function parseCliArgs(args: string[]): CliOptions {
	let pinPort = 0;
	let attach = false;
	for (const a of args) {
		if (a === "--attach") attach = true;
		else if (a.startsWith("--port=")) {
			pinPort = Number(a.slice("--port=".length));
		} else {
			return { pinPort: -1, attach };
		}
	}
	return { pinPort, attach };
}

/** Split a demo's argv into its `--port=`/`--attach` options and everything
 * else (the positional Zig client/host path). The knowledge of which flags are
 * options lives here, once, beside `parseCliArgs`. */
export function splitDemoArgs(
	args: string[],
): { positional: string[]; options: CliOptions } {
	const positional: string[] = [];
	const optionArgs: string[] = [];
	for (const a of args) {
		if (a === "--attach" || a.startsWith("--port=")) optionArgs.push(a);
		else positional.push(a);
	}
	return { positional, options: parseCliArgs(optionArgs) };
}

/** The Deno permissions every demo server and client run under. */
export const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

export function requireZigClientPath(
	positional: string[],
	usage: string,
): string {
	const zigClient = positional[0];
	if (!zigClient) {
		console.error(usage);
		Deno.exit(2);
	}
	return zigClient;
}

export function validatePortOptions(
	pinPort: number,
	attach: boolean,
	script: string,
): void {
	if (!Number.isInteger(pinPort) || pinPort < 0 || pinPort > 65535) {
		console.error(`${script}: --port must be an integer in 1..65535`);
		Deno.exit(2);
	}
	if (attach && pinPort === 0) {
		console.error(
			`${script}: --attach requires --port (there is no server to join without one)`,
		);
		Deno.exit(2);
	}
}

/** True if `cmd` can be spawned at all. */
export async function onPath(cmd: string): Promise<boolean> {
	try {
		await new Deno.Command(cmd, {
			args: ["--version"],
			stdout: "null",
			stderr: "null",
		}).output();
		return true;
	} catch {
		return false;
	}
}

export async function buildRust(
	root: string,
	manifest: string,
	features?: string[],
): Promise<boolean> {
	console.log(`demo: building the Rust client (cargo build)…`);
	const cargoArgs = ["build", "--manifest-path", `${root}/${manifest}`];
	if (features) cargoArgs.push("--features", features.join(","));
	const built = await new Deno.Command("cargo", {
		args: cargoArgs,
		cwd: root,
		stdout: "inherit",
		stderr: "inherit",
	}).output();
	if (!built.success) {
		throw new Error(`cargo is available but failed to build ${manifest}`);
	}
	return true;
}

async function readAnnouncePort(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	pattern: RegExp,
	miss: string,
): Promise<number> {
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		const m = buf.match(pattern);
		if (m) {
			reader.releaseLock();
			return Number(m[1]);
		}
	}
	reader.releaseLock();
	throw new Error(miss);
}

export async function readListeningPort(
	server: Deno.ChildProcess,
	pattern: RegExp,
	miss: string,
): Promise<number> {
	return await readAnnouncePort(server.stdout.getReader(), pattern, miss);
}

/** Read a listening port (or similar token) announced on stderr. */
export async function readPort(
	proc: Deno.ChildProcess,
	pattern: RegExp,
	miss: string,
): Promise<number> {
	return await readAnnouncePort(proc.stderr.getReader(), pattern, miss);
}

export function rejectAttach(
	attach: boolean,
	script: string,
	reason: string,
): void {
	if (attach) {
		console.error(`${script}: ${reason}`);
		Deno.exit(2);
	}
}

/** True when ``python3`` is on PATH and can ``import`` ``moduleImport``. */
export async function pythonCanImport(moduleImport: string): Promise<boolean> {
	if (!(await onPath("python3"))) return false;
	const check = await new Deno.Command("python3", {
		args: ["-c", `import ${moduleImport}`],
		stdout: "null",
		stderr: "null",
	}).output();
	return check.code === 0;
}

/** Run a child to completion and answer with its exit code and everything it
 * said on both pipes. `env` is added to the environment this process already
 * has, so a caller names only what the child needs to be told. */
export async function runChild(
	cmd: string,
	args: string[],
	root: string,
	env: Record<string, string> = {},
): Promise<{ code: number; out: string }> {
	const out = await new Deno.Command(cmd, {
		args,
		stdout: "piped",
		stderr: "piped",
		cwd: root,
		env,
	}).output();
	const text = new TextDecoder().decode(out.stdout) +
		new TextDecoder().decode(out.stderr);
	return { code: out.code, out: text };
}

export async function stopSpawnedServer(
	server: Deno.ChildProcess | null,
): Promise<void> {
	if (!server) return;
	try {
		server.kill("SIGTERM");
	} catch { /* already gone */ }
	await server.status;
}

/** One cross-language client: a name for the divider, the command to run, and
 * the argv to build once the server's port is known. */
export interface Participant {
	name: string;
	cmd: string;
	argv: (port: number) => string[];
}

/** Everything a "one server, many-language clients over one OCapN session"
 * demo needs beyond the participants themselves. The `tasks` and `tools` demos
 * are the same orchestration spine with different nouns; it lives here so the
 * run loop — and the pass/fail accounting — has exactly one owner. */
export interface CrossLangDemo {
	/** The demo's name, used to prefix its log lines (e.g. "tasks"). */
	label: string;
	/** What the server is called in prose (e.g. "server", "coordinator"). */
	serverNoun: string;
	/** What a client is called in prose (e.g. "client", "agent"). */
	clientNoun: string;
	/** Absolute path to the Deno server script; run under `DENO_FLAGS`. */
	serverScript: string;
	/** Matches the server's port-announcement line on stdout (one capture). */
	listenPattern: RegExp;
	/** Reported if the server never announces its port. */
	listenMiss: string;
	/** The available clients plus a note on any that were skipped. */
	roster: () => Promise<{ participants: Participant[]; skipped: string[] }>;
	/** The success line, given a rendered language count ("3 languages"). */
	okLine: (langs: string) => string;
	/** The failure line, printed when any client exits non-zero. */
	failLine: string;
}

/** Run a cross-language demo to completion and exit the process: spawn the
 * server (unless attaching), run every rostered client against it in turn,
 * print each client's output under a divider, and report one pass/fail summary.
 * There is one run loop, so a client's divider can only ever name that client. */
export async function runCrossLangDemo(
	demo: CrossLangDemo,
	pinPort: number,
	attach: boolean,
): Promise<never> {
	const root = Deno.cwd();
	const { participants, skipped } = await demo.roster();
	for (const s of skipped) console.log(`${demo.label} demo: skipping ${s}`);

	const server = attach ? null : new Deno.Command("deno", {
		args: [...DENO_FLAGS, demo.serverScript, String(pinPort)],
		stdout: "piped",
		stderr: "inherit",
		cwd: root,
	}).spawn();

	let failed = false;
	try {
		const port = server ? await readListeningPort(server, demo.listenPattern, demo.listenMiss) : pinPort;
		console.log(
			`${demo.label} demo: ${demo.serverNoun} on 127.0.0.1:${port}; running ${participants.length} ${demo.clientNoun}(s) (${
				participants.map((p) => p.name).join(", ")
			})\n`,
		);

		for (const p of participants) {
			const r = await runChild(p.cmd, p.argv(port), root);
			console.log(`──────── ${p.name} (exit ${r.code}) ────────`);
			console.log(r.out.trimEnd());
			console.log("");
			if (r.code !== 0) failed = true;
		}

		if (failed) {
			console.error(demo.failLine);
		} else {
			const langs = participants.length === 1 ? "1 language" : `${participants.length} languages`;
			console.log(demo.okLine(langs));
			if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
		}
	} finally {
		await stopSpawnedServer(server);
	}

	Deno.exit(failed ? 1 : 0);
}
