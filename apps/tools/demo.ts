// Cross-language tools showcase orchestrator.
//
// Starts the Deno tools coordinator, then runs one agent per available language
// against it: Zig and Deno always, plus Python (python3), Racket (racket), and
// Rust (cargo) when each is on PATH. Each agent
// proves the capability trio (delegation, attenuation, revocation) over an OCapN session on the `tcp` netlayer.
// The coordinator and the agent are different languages on the wire, so the
// capability passing, attenuation, and revocation cross a real wire.
//
// Run by `zig build demo-tools`, which passes the built Zig agent's path as argv[0].
// `--port=N` (from `-Dport`) pins the coordinator's port instead of an ephemeral
// one; `--attach` (from `-Dattach`, requires `--port`) runs the agents against a
// coordinator you already started on that port instead of spawning one.

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
const ZIG_AGENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig agent path (run via `zig build demo-tools`)",
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
		participants.push({
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
		participants.push({
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
			participants.push({
				name: "rust",
				cmd: `${ROOT}/apps/tools/rust/target/debug/tools-agent`,
				argv: (p) => ["127.0.0.1", String(p), "rs-agent"],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { participants, skipped };
}

await runCrossLangDemo(
	{
		label: "tools",
		serverNoun: "coordinator",
		clientNoun: "agent",
		serverScript: `${ROOT}/apps/tools/deno/server.ts`,
		listenPattern: /TOOLS-SERVER-LISTENING (\d+)/,
		listenMiss: "coordinator never announced its port",
		roster,
		failLine: "tools demo FAILED: an agent did not prove the capability properties",
		okLine: (langs) => `tools demo OK: ${langs} proved delegation, attenuation, and revocation over OCapN`,
	},
	pinPort,
	attach,
);
