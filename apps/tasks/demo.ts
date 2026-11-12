// Cross-language tasks demo orchestrator.
//
// Starts the Zig tasks server on a fresh SQLite store directory, then joins one client
// per available language (Deno and Zig always, plus Python, Racket, and Rust
// when their runtimes are on PATH) to its board over encrypted Noise TCP. Each client watches
// the board, adds a task to the first list, marks it done by moving it to the
// second, and confirms the move and the change. The orchestrator asserts every participating client exits
// 0, so `zig build demo-tasks` proves one board saved in Loam holds clients
// written in several languages at once.
//
// Run by `zig build demo-tasks`, which passes the built Zig client and server
// paths. `--port=N` (from `-Dport`) pins the server's port. The board's name is
// a secret the server announces when it starts, so there is no `--attach`.
// Every client dials the locator the server announces.

import {
	buildRust,
	DENO_FLAGS,
	onPath,
	type Participant,
	rejectAttach,
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
const ZIG_SERVER = requireZigClientPath(
	positional.slice(1),
	"demo.ts: missing the Zig server path (run via `zig build demo-tasks`)",
);
validatePortOptions(pinPort, attach, "demo.ts");
rejectAttach(attach, "demo.ts", "the board's name is announced only by a server this demo starts");

const ROOT = Deno.cwd();
const DATA = await Deno.makeTempDir({ prefix: "glowcap-tasks-" });

async function roster(): Promise<{ participants: Participant[]; skipped: string[] }> {
	const participants: Participant[] = [
		{
			name: "deno",
			cmd: "deno",
			argv: (
				_port,
				[name, locator],
			) => [
				...DENO_FLAGS,
				`${ROOT}/apps/tasks/deno/client.ts`,
				locator,
				name,
				"deno-ada",
				"learn OCapN",
			],
		},
		{
			name: "zig",
			cmd: ZIG_CLIENT,
			argv: (_port, [name, locator]) => [locator, name, "zig-niklaus", "write glowcap apps"],
		},
	];
	const skipped: string[] = [];

	if (await onPath("python3")) {
		participants.push({
			name: "python",
			cmd: "python3",
			argv: (
				_port,
				[name, locator],
			) => [
				`${ROOT}/apps/tasks/python/client.py`,
				locator,
				name,
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
				_port,
				[name, locator],
			) => [
				"-y",
				`${ROOT}/apps/tasks/racket/client.rkt`,
				locator,
				name,
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
					_port,
					[name, locator],
				) => [locator, name, "rs-barbara", "zero-copy everything"],
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
		server: { cmd: ZIG_SERVER, args: (pinPort) => [`--data=${DATA}`, `--port=${pinPort}`] },
		listenPattern: /TASKS-SERVER-LISTENING (\d+) (\S+) (\S+)/,
		cleanup: () => Deno.remove(DATA, { recursive: true }),
		listenMiss: "server never announced its port",
		roster,
		failLine: "tasks demo FAILED: at least one client did not watch, add, move, and confirm its task",
		okLine: (langs) =>
			`tasks demo OK: ${langs} shared one task board saved in Loam, and every client moved its task to Done`,
	},
	pinPort,
	attach,
);
