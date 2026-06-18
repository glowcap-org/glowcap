// Cross-language tools showcase orchestrator.
//
// Starts the Deno tools coordinator, then runs one agent per available language
// against it: Zig and Deno always, plus Python (python3), Racket (racket), and
// Rust (cargo) when each is on PATH. Each agent
// proves the capability trio (delegation, attenuation, revocation) over OCapN/TCP.
// The coordinator and the agent are different languages on the wire, so the
// capability passing, attenuation, and revocation are real, not in-process.
//
// Run by `zig build demo-tools`, which passes the built Zig agent's path as argv[0].
// `--port=N` (from `-Dport`) pins the coordinator's port instead of an ephemeral
// one; `--attach` (from `-Dattach`, requires `--port`) runs the agents against a
// coordinator you already started on that port instead of spawning one.

const positional: string[] = [];
let pinPort = 0;
let attach = false;
for (const a of Deno.args) {
	if (a === "--attach") attach = true;
	else if (a.startsWith("--port=")) pinPort = Number(a.slice("--port=".length));
	else positional.push(a);
}
const ZIG_AGENT = positional[0];
if (!ZIG_AGENT) {
	console.error(
		"demo.ts: missing the Zig agent path (run via `zig build demo-tools`)",
	);
	Deno.exit(2);
}
if (!Number.isInteger(pinPort) || pinPort < 0 || pinPort > 65535) {
	console.error("demo.ts: --port must be an integer in 1..65535");
	Deno.exit(2);
}
if (attach && pinPort === 0) {
	console.error(
		"demo.ts: --attach requires --port (there is no coordinator to join without one)",
	);
	Deno.exit(2);
}

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Agent {
	name: string;
	cmd: string;
	argv: (port: number) => string[];
}

async function onPath(cmd: string): Promise<boolean> {
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

async function buildRust(): Promise<boolean> {
	console.log("tools demo: building the Rust agent (cargo build)…");
	const built = await new Deno.Command("cargo", {
		args: [
			"build",
			"--manifest-path",
			`${ROOT}/examples/apps/tools/rust/Cargo.toml`,
		],
		cwd: ROOT,
		stdout: "inherit",
		stderr: "inherit",
	}).output();
	if (!built.success) {
		console.log("tools demo: skipping Rust — cargo build failed");
	}
	return built.success;
}

async function roster(): Promise<{ agents: Agent[]; skipped: string[] }> {
	const agents: Agent[] = [
		{
			name: "deno",
			cmd: "deno",
			argv: (
				p,
			) => [
				...DENO_FLAGS,
				`${ROOT}/examples/apps/tools/deno/agent.ts`,
				"127.0.0.1",
				String(p),
				"deno-agent",
			],
		},
		{
			name: "zig",
			cmd: ZIG_AGENT,
			argv: (p) => [String(p), "zig-agent"],
		},
	];
	const skipped: string[] = [];

	if (await onPath("python3")) {
		agents.push({
			name: "python",
			cmd: "python3",
			argv: (
				p,
			) => [
				`${ROOT}/examples/apps/tools/python/agent.py`,
				"127.0.0.1",
				String(p),
				"py-agent",
			],
		});
	} else skipped.push("python (no python3 on PATH)");

	if (await onPath("racket")) {
		agents.push({
			name: "racket",
			cmd: "racket",
			argv: (
				p,
			) => [
				`${ROOT}/examples/apps/tools/racket/agent.rkt`,
				"127.0.0.1",
				String(p),
				"rkt-agent",
			],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRust()) {
			agents.push({
				name: "rust",
				cmd: `${ROOT}/examples/apps/tools/rust/target/debug/tools-agent`,
				argv: (p) => ["127.0.0.1", String(p), "rs-agent"],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { agents, skipped };
}

async function readPort(server: Deno.ChildProcess): Promise<number> {
	const reader = server.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value);
		const m = buf.match(/TOOLS-SERVER-LISTENING (\d+)/);
		if (m) {
			reader.releaseLock();
			return Number(m[1]);
		}
	}
	reader.releaseLock();
	throw new Error("coordinator never announced its port");
}

async function runAgent(a: Agent, port: number) {
	const out = await new Deno.Command(a.cmd, {
		args: a.argv(port),
		stdout: "piped",
		stderr: "piped",
		cwd: ROOT,
	}).output();
	const text = new TextDecoder().decode(out.stdout) +
		new TextDecoder().decode(out.stderr);
	return { name: a.name, code: out.code, out: text };
}

const { agents, skipped } = await roster();
for (const s of skipped) console.log(`tools demo: skipping ${s}`);

// With --attach the coordinator is yours, already running; otherwise spawn one
// on the pinned port (or 0, which binds an ephemeral port and announces it).
const server = attach ? null : new Deno.Command("deno", {
	args: [
		...DENO_FLAGS,
		`${ROOT}/examples/apps/tools/deno/server.ts`,
		String(pinPort),
	],
	stdout: "piped",
	stderr: "inherit",
	cwd: ROOT,
}).spawn();

let failed = false;
try {
	// No liveness probe in attach mode: on loopback a missing coordinator refuses
	// each agent's connect immediately, which is already a loud, fast failure.
	const port = server ? await readPort(server) : pinPort;
	console.log(
		`tools demo: coordinator on 127.0.0.1:${port}; running ${agents.length} agent(s) (${
			agents.map((a) => a.name).join(", ")
		})\n`,
	);

	for (const a of agents) {
		const r = await runAgent(a, port);
		console.log(`──────── ${r.name} (exit ${r.code}) ────────`);
		console.log(r.out.trimEnd());
		console.log("");
		if (r.code !== 0) failed = true;
	}

	if (failed) {
		console.error(
			"tools demo FAILED: an agent did not prove the capability properties",
		);
	} else {
		const langs = agents.length === 1 ? "1 language" : `${agents.length} languages`;
		console.log(
			`tools demo OK: ${langs} proved delegation, attenuation, and revocation over OCapN`,
		);
		if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
	}
} finally {
	// An attached coordinator belongs to whoever started it; only a spawned one dies here.
	if (server) {
		try {
			server.kill("SIGTERM");
		} catch { /* already gone */ }
		await server.status;
	}
}

Deno.exit(failed ? 1 : 0);
