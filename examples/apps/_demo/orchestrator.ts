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
	if (!built.success) console.log("demo: skipping Rust, cargo build failed");
	return built.success;
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

export async function runChild(
	cmd: string,
	args: string[],
	root: string,
): Promise<{ code: number; out: string }> {
	const out = await new Deno.Command(cmd, {
		args,
		stdout: "piped",
		stderr: "piped",
		cwd: root,
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
