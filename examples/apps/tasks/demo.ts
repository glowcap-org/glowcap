// Cross-language tasks demo orchestrator.
//
// Starts the Deno tasks server, then joins one client per available language —
// Deno and the native Zig client always, plus Python, Racket, and Rust when
// their runtimes are on PATH — into one capability-secure task board over TCP. Each
// client adds a task, lists tasks, marks its task done, and confirms the
// change. The orchestrator asserts every participating client exits 0, so
// `zig build demo-tasks` is an honest proof that one OCapN task board holds clients
// written in several languages at once.
//
// Run by `zig build demo-tasks`, which passes the built Zig client's path as argv[0].
// `--port=N` (from `-Dport`) pins the server's port instead of an ephemeral one;
// `--attach` (from `-Dattach`, requires `--port`) joins a server you already
// started on that port instead of spawning one. An attached board should be
// otherwise idle: the clients assert against the board state their own
// operations produce.

const positional: string[] = [];
let pinPort = 0;
let attach = false;
for (const a of Deno.args) {
	if (a === "--attach") attach = true;
	else if (a.startsWith("--port=")) pinPort = Number(a.slice("--port=".length));
	else positional.push(a);
}
const ZIG_CLIENT = positional[0];
if (!ZIG_CLIENT) {
	console.error(
		"demo.ts: missing the Zig client path (run via `zig build demo-tasks`)",
	);
	Deno.exit(2);
}
if (!Number.isInteger(pinPort) || pinPort < 0 || pinPort > 65535) {
	console.error("demo.ts: --port must be an integer in 1..65535");
	Deno.exit(2);
}
if (attach && pinPort === 0) {
	console.error(
		"demo.ts: --attach requires --port (there is no server to join without one)",
	);
	Deno.exit(2);
}

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Member {
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
	console.log("tasks demo: building the Rust client (cargo build)…");
	const built = await new Deno.Command("cargo", {
		args: [
			"build",
			"--manifest-path",
			`${ROOT}/examples/apps/tasks/rust/Cargo.toml`,
		],
		cwd: ROOT,
		stdout: "inherit",
		stderr: "inherit",
	}).output();
	if (!built.success) {
		console.log("tasks demo: skipping Rust, cargo build failed");
	}
	return built.success;
}

async function roster(): Promise<{ members: Member[]; skipped: string[] }> {
	const members: Member[] = [
		{
			name: "deno",
			cmd: "deno",
			argv: (
				p,
			) => [
				...DENO_FLAGS,
				`${ROOT}/examples/apps/tasks/deno/client.ts`,
				"127.0.0.1",
				String(p),
				"deno-ada",
				"learn OCapN",
			],
		},
		{
			name: "zig",
			cmd: ZIG_CLIENT,
			argv: (p) => [String(p), "zig-niklaus", "write pancake apps"],
		},
	];
	const skipped: string[] = [];

	if (await onPath("python3")) {
		members.push({
			name: "python",
			cmd: "python3",
			argv: (
				p,
			) => [
				`${ROOT}/examples/apps/tasks/python/client.py`,
				"127.0.0.1",
				String(p),
				"py-grace",
				"try capabilities",
			],
		});
	} else skipped.push("python (no python3 on PATH)");

	if (await onPath("racket")) {
		members.push({
			name: "racket",
			cmd: "racket",
			argv: (
				p,
			) => [
				`${ROOT}/examples/apps/tasks/racket/client.rkt`,
				"127.0.0.1",
				String(p),
				"rkt-alan",
				"spawn an actor",
			],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRust()) {
			members.push({
				name: "rust",
				cmd: `${ROOT}/examples/apps/tasks/rust/target/debug/tasks-client`,
				argv: (
					p,
				) => ["127.0.0.1", String(p), "rs-barbara", "zero-copy everything"],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { members, skipped };
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
		const m = buf.match(/TASKS-SERVER-LISTENING (\d+)/);
		if (m) {
			reader.releaseLock();
			return Number(m[1]);
		}
	}
	reader.releaseLock();
	throw new Error("server never announced its port");
}

async function runMember(m: Member, port: number) {
	const out = await new Deno.Command(m.cmd, {
		args: m.argv(port),
		stdout: "piped",
		stderr: "piped",
		cwd: ROOT,
	}).output();
	const text = new TextDecoder().decode(out.stdout) +
		new TextDecoder().decode(out.stderr);
	return { name: m.name, code: out.code, out: text };
}

const { members, skipped } = await roster();
for (const s of skipped) console.log(`tasks demo: skipping ${s}`);

// With --attach the server is yours, already running; otherwise spawn one on
// the pinned port (or 0, which binds an ephemeral port and announces it).
const server = attach ? null : new Deno.Command("deno", {
	args: [
		...DENO_FLAGS,
		`${ROOT}/examples/apps/tasks/deno/server.ts`,
		String(pinPort),
	],
	stdout: "piped",
	stderr: "inherit",
	cwd: ROOT,
}).spawn();

let failed = false;
try {
	// No liveness probe in attach mode: on loopback a missing server refuses each
	// client's connect immediately, which is already a loud, fast failure.
	const port = server ? await readPort(server) : pinPort;
	console.log(
		`tasks demo: server on 127.0.0.1:${port}; running ${members.length} client(s) (${
			members.map((m) => m.name).join(", ")
		})\n`,
	);

	// Run clients sequentially so each sees a clean, predictable board state.
	for (const m of members) {
		const r = await runMember(m, port);
		console.log(`──────── ${r.name} (exit ${r.code}) ────────`);
		console.log(r.out.trimEnd());
		console.log("");
		if (r.code !== 0) failed = true;
	}

	if (failed) {
		console.error(
			"tasks demo FAILED: at least one client did not complete the add-list-done-list round trip",
		);
	} else {
		const langs = members.length === 1 ? "1 language" : `${members.length} languages`;
		console.log(
			`tasks demo OK: ${langs} held one capability-secure task board and every client completed a round trip`,
		);
		if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
	}
} finally {
	// An attached server belongs to whoever started it; only a spawned one dies here.
	if (server) {
		try {
			server.kill("SIGTERM");
		} catch { /* already gone */ }
		await server.status;
	}
}

Deno.exit(failed ? 1 : 0);
