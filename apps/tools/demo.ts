// Cross-language tools showcase orchestrator.
//
// Starts the Deno tools coordinator, then runs one agent per available language
// against it: Zig and Deno always, plus Python (python3), Racket (racket), and
// Rust (cargo) when each is on PATH. Each agent
// proves the capability trio (delegation, attenuation, revocation) over an OCapN session on encrypted
// Noise TCP, dialing the locator the coordinator announces.
// The coordinator and the agent are different languages on the wire, so the
// capability passing, attenuation, and revocation cross a real wire.
//
// Run by `zig build demo-tools`, which passes the built Zig agent's path as argv[0].
// `--port=N` (from `-Dport`) pins the coordinator's port instead of an ephemeral
// one; `--attach` (from `-Dattach`, requires `--port`) runs the agents against a
// coordinator you already started on that port instead of spawning one. That
// coordinator records its locator under `zig-out/state/tools/`.

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
import { locatorRecord } from "./deno/protocol.ts";

const { positional, options: { pinPort, attach } } = splitDemoArgs(Deno.args);
const ZIG_AGENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig agent path (run via `zig build demo-tools`)",
);
validatePortOptions(pinPort, attach, "demo.ts");

const ROOT = Deno.cwd();

/** The locator a coordinator already running on `port` recorded. */
async function attached(port: number): Promise<string[]> {
	const record = locatorRecord(port);
	try {
		return [(await Deno.readTextFile(record)).trim()];
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
		console.error(`demo.ts: no coordinator recorded a locator for port ${port}. Start one on that port first.`);
		Deno.exit(2);
	}
}

async function roster(): Promise<{ participants: Participant[]; skipped: string[] }> {
	const participants: Participant[] = [
		{
			name: "deno",
			cmd: "deno",
			argv: (_port, [locator]) => [...DENO_FLAGS, `${ROOT}/apps/tools/deno/agent.ts`, locator, "deno-agent"],
		},
		{
			name: "zig",
			cmd: ZIG_AGENT,
			argv: (_port, [locator]) => [locator, "zig-agent"],
		},
	];
	const skipped: string[] = [];

	if (await onPath("python3")) {
		participants.push({
			name: "python",
			cmd: "python3",
			argv: (_port, [locator]) => [`${ROOT}/apps/tools/python/agent.py`, locator, "py-agent"],
		});
	} else skipped.push("python (no python3 on PATH)");

	if (await onPath("racket")) {
		participants.push({
			name: "racket",
			cmd: "racket",
			argv: (_port, [locator]) => ["-y", `${ROOT}/apps/tools/racket/agent.rkt`, locator, "rkt-agent"],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRust(ROOT, "apps/tools/rust/Cargo.toml")) {
			participants.push({
				name: "rust",
				cmd: `${ROOT}/apps/tools/rust/target/debug/tools-agent`,
				argv: (_port, [locator]) => [locator, "rs-agent"],
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
		server: {
			cmd: "deno",
			args: (pinPort) => [
				...DENO_FLAGS,
				`--allow-write=${ROOT}/zig-out/state/tools`,
				`${ROOT}/apps/tools/deno/coordinator.ts`,
				String(pinPort),
			],
		},
		listenPattern: /TOOLS-SERVER-LISTENING (\d+) (\S+)/,
		attached,
		listenMiss: "coordinator never announced its port",
		roster,
		failLine: "tools demo FAILED: an agent did not prove the capability properties",
		okLine: (langs) => `tools demo OK: ${langs} proved delegation, attenuation, and revocation over OCapN`,
	},
	pinPort,
	attach,
);
