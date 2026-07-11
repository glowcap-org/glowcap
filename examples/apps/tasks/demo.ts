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

import {
	buildRust,
	onPath,
	parseCliArgs,
	readListeningPort,
	requireZigClientPath,
	runChild,
	stopSpawnedServer,
	validatePortOptions,
} from "../_demo/orchestrator.ts";

const positional: string[] = [];
const cliArgs: string[] = [];
for (const a of Deno.args) {
	if (a === "--attach" || a.startsWith("--port=")) cliArgs.push(a);
	else positional.push(a);
}
const { pinPort, attach } = parseCliArgs(cliArgs);
const ZIG_CLIENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig client path (run via `zig build demo-tasks`)",
);
validatePortOptions(pinPort, attach, "demo.ts");

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Member {
	name: string;
	cmd: string;
	argv: (port: number) => string[];
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
		if (await buildRust(ROOT, "examples/apps/tasks/rust/Cargo.toml")) {
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

const { members, skipped } = await roster();
for (const s of skipped) console.log(`tasks demo: skipping ${s}`);

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
	const port = server
		? await readListeningPort(
			server,
			/TASKS-SERVER-LISTENING (\d+)/,
			"server never announced its port",
		)
		: pinPort;
	console.log(
		`tasks demo: server on 127.0.0.1:${port}; running ${members.length} client(s) (${
			members.map((m) => m.name).join(", ")
		})\n`,
	);

	for (const m of members) {
		const r = await runChild(m.cmd, m.argv(port), ROOT);
		console.log(`──────── ${m.name} (exit ${r.code}) ────────`);
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
	await stopSpawnedServer(server);
}

Deno.exit(failed ? 1 : 0);
