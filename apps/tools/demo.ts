// Cross-language tools showcase orchestrator.
//
// Starts the Deno tools coordinator, then runs one agent per available language
// against it: Zig and Deno always, plus Python (python3), Racket (racket), and
// Rust (cargo) when each is on PATH. Each agent
// proves the capability trio (delegation, attenuation, revocation) over an OCapN session on the `tcp` netlayer.
// The coordinator and the agent are different languages on the wire, so the
// capability passing, attenuation, and revocation are real, not in-process.
//
// Run by `zig build demo-tools`, which passes the built Zig agent's path as argv[0].
// `--port=N` (from `-Dport`) pins the coordinator's port instead of an ephemeral
// one; `--attach` (from `-Dattach`, requires `--port`) runs the agents against a
// coordinator you already started on that port instead of spawning one.

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
const ZIG_AGENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig agent path (run via `zig build demo-tools`)",
);
validatePortOptions(pinPort, attach, "demo.ts");

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Agent {
	name: string;
	cmd: string;
	argv: (port: number) => string[];
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
				`${ROOT}/apps/tools/deno/agent.ts`,
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
				`${ROOT}/apps/tools/python/agent.py`,
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
				"-y",
				`${ROOT}/apps/tools/racket/agent.rkt`,
				"127.0.0.1",
				String(p),
				"rkt-agent",
			],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRust(ROOT, "apps/tools/rust/Cargo.toml")) {
			agents.push({
				name: "rust",
				cmd: `${ROOT}/apps/tools/rust/target/debug/tools-agent`,
				argv: (p) => ["127.0.0.1", String(p), "rs-agent"],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { agents, skipped };
}

const { agents, skipped } = await roster();
for (const s of skipped) console.log(`tools demo: skipping ${s}`);

const server = attach ? null : new Deno.Command("deno", {
	args: [
		...DENO_FLAGS,
		`${ROOT}/apps/tools/deno/server.ts`,
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
			/TOOLS-SERVER-LISTENING (\d+)/,
			"coordinator never announced its port",
		)
		: pinPort;
	console.log(
		`tools demo: coordinator on 127.0.0.1:${port}; running ${agents.length} agent(s) (${
			agents.map((a) => a.name).join(", ")
		})\n`,
	);

	for (const a of agents) {
		const r = await runChild(a.cmd, a.argv(port), ROOT);
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
	await stopSpawnedServer(server);
}

Deno.exit(failed ? 1 : 0);
