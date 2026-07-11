// Cross-language accountability demo: Zig host + Deno caller + Python caller.
//
// Starts the Zig host binary (accountability-host), reads the port it prints,
// then runs each available caller against a fresh host. Both exit 0 exactly when:
//   - The legitimate invocation resolved with an ack, and
//   - The tampered invocation was refused as a broken promise.
//
// Run it with `zig build demo-accountability`, which passes the built host
// binary's path as argv[0]. Run by hand, it falls back to the installed host
// under zig-out/bin. `--port=N` (from `-Dport`) pins the hosts' port instead of
// an ephemeral one; each caller still gets a fresh host, rebound on the same
// port. `--attach` is rejected: a host serves exactly one caller and exits, so
// there is no long-lived server to join.

import {
	onPath,
	parseCliArgs,
	pythonCanImport,
	readPort,
	rejectAttach,
	runChild,
	stopSpawnedServer,
	validatePortOptions,
} from "../../_demo/orchestrator.ts";

const positional: string[] = [];
const cliArgs: string[] = [];
for (const a of Deno.args) {
	if (a === "--attach" || a.startsWith("--port=")) cliArgs.push(a);
	else positional.push(a);
}
const { pinPort, attach } = parseCliArgs(cliArgs);
rejectAttach(
	attach,
	"demo.ts",
	"--attach is not supported here, each caller needs a fresh host (drop -Dattach)",
);
validatePortOptions(pinPort, false, "demo.ts");

const ROOT = Deno.cwd();
const HOST_BIN = positional[0] ??
	`${ROOT}/zig-out/bin/accountability-host`;
const DENO_CALLER = new URL("./caller.ts", import.meta.url).pathname;
const PYTHON_CALLER = `${ROOT}/examples/apps/accountability-on-pancake/python/caller.py`;

interface CallerSpec {
	name: string;
	cmd: string;
	args: (port: number) => string[];
}

const callers: CallerSpec[] = [
	{
		name: "deno",
		cmd: "deno",
		args: (
			p,
		) => [
			"run",
			"--allow-ffi",
			"--allow-read",
			"--allow-net",
			DENO_CALLER,
			String(p),
		],
	},
];

if (await pythonCanImport("nacl.signing")) {
	callers.push({
		name: "python",
		cmd: "python3",
		args: (p) => [PYTHON_CALLER, String(p)],
	});
} else if (await onPath("python3")) {
	console.log("  skipping python (pynacl not installed)");
} else {
	console.log("  skipping python (python3 not on PATH)");
}

console.log(
	`accountability-on-pancake cross-seam demo: Zig host + ${
		callers.map((c) => c.name).join(" + ")
	} callers\n`,
);

let failed = false;
for (const caller of callers) {
	const host = new Deno.Command(HOST_BIN, {
		args: pinPort > 0 ? [`--port=${pinPort}`] : [],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();

	try {
		const port = await readPort(
			host,
			/ACCOUNTABILITY-HOST-LISTENING (\d+)/,
			"host never announced its port",
		);
		console.log(`──── ${caller.name} (host on 127.0.0.1:${port}) ────`);

		const result = await runChild(caller.cmd, caller.args(port), ROOT);
		console.log(result.out.trimEnd());
		if (result.code !== 0) {
			console.error(`  ${caller.name} caller FAILED (exit ${result.code})`);
			failed = true;
		}
		console.log("");
	} finally {
		await stopSpawnedServer(host);
	}
}

if (failed) {
	console.error("cross-seam demo FAILED");
	Deno.exit(1);
} else {
	const langs = callers.length + 1;
	console.log(
		`cross-seam demo OK: ${langs} languages held one OCapN accountability conversation`,
	);
}
