// Cross-language tasks demo orchestrator.
//
// Starts the Deno tasks server, then joins one client per available language —
// Deno and the native Zig client always, plus Python, Racket, and Rust when
// their runtimes are on PATH — into one capability-secure task board over TCP. Each
// client adds a task, lists tasks, marks its task done, and confirms the
// change. The orchestrator asserts every participating client exits 0, so
// `zig build demo-tasks` proves that one OCapN task board holds clients written
// in several languages at once.
//
// Run by `zig build demo-tasks`, which passes the built Zig client's path as argv[0].
// `--port=N` (from `-Dport`) pins the server's port instead of an ephemeral one;
// `--attach` (from `-Dattach`, requires `--port`) joins a server you already
// started on that port instead of spawning one. An attached board should be
// otherwise idle: the clients assert against the board state their own
// operations produce.

import {
	buildRust,
	DENO_FLAGS,
	onPath,
	type Participant,
	requireZigClientPath,
	runCrossLangDemo,
	splitDemoArgs,
	validatePortOptions,
} from "../_demo/orchestrator.ts";

const { positional, options: { pinPort, attach } } = splitDemoArgs(Deno.args);
const ZIG_CLIENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig client path (run via `zig build demo-tasks`)",
);
validatePortOptions(pinPort, attach, "demo.ts");

const ROOT = Deno.cwd();

async function roster(): Promise<{ participants: Participant[]; skipped: string[] }> {
	const participants: Participant[] = [
		{
			name: "deno",
			cmd: "deno",
			argv: (
				p,
			) => [
				...DENO_FLAGS,
				`${ROOT}/apps/tasks/deno/client.ts`,
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
		participants.push({
			name: "python",
			cmd: "python3",
			argv: (
				p,
			) => [
				`${ROOT}/apps/tasks/python/client.py`,
				"127.0.0.1",
				String(p),
				"py-grace",
				"try capabilities",
			],
		});
	} else skipped.push("python (no python3 on PATH)");

	if (await onPath("racket")) {
		participants.push({
			name: "racket",
			cmd: "racket",
			argv: (
				p,
			) => [
				"-y",
				`${ROOT}/apps/tasks/racket/client.rkt`,
				"127.0.0.1",
				String(p),
				"rkt-alan",
				"spawn an actor",
			],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRust(ROOT, "apps/tasks/rust/Cargo.toml")) {
			participants.push({
				name: "rust",
				cmd: `${ROOT}/apps/tasks/rust/target/debug/tasks-client`,
				argv: (
					p,
				) => ["127.0.0.1", String(p), "rs-barbara", "zero-copy everything"],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { participants, skipped };
}

await runCrossLangDemo(
	{
		label: "tasks",
		serverNoun: "server",
		clientNoun: "client",
		serverScript: `${ROOT}/apps/tasks/deno/server.ts`,
		listenPattern: /TASKS-SERVER-LISTENING (\d+)/,
		listenMiss: "server never announced its port",
		roster,
		failLine:
			"tasks demo FAILED: at least one client did not complete the add-list-done-list round trip",
		okLine: (langs) =>
			`tasks demo OK: ${langs} held one capability-secure task board and every client completed a round trip`,
	},
	pinPort,
	attach,
);
