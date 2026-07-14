// Cross-language rooms demo orchestrator.
//
// Starts the Deno rooms server, then joins one client per available language —
// Deno and the native Zig client always, plus Python, Racket, and Rust when their
// runtimes are on PATH — into one capability-secure chat room over TCP. Each
// client subscribes, waits for every roster member to be present, posts one
// line, and must receive every roster member's line back through the capability
// callback. The orchestrator
// asserts every participating client exits 0, so `zig build demo-rooms` is an honest
// proof that one OCapN room holds members written in several languages at once.
//
// It does not require every runtime: a language whose runtime is missing is
// skipped with a note, not treated as a failure, so the demo runs on whatever
// machine you have. Deno is the floor — it hosts the room and runs this script.
//
// Run by `zig build demo-rooms`, which passes the built Zig client's path as argv[0].
// `--port=N` (from `-Dport`) pins the server's port instead of an ephemeral one;
// `--attach` (from `-Dattach`, requires `--port`) joins a server you already
// started on that port instead of spawning one. `--transport=iroh` runs the room
// over iroh's encrypted QUIC instead of TCP (the server then announces an
// ocapn:// URI and every client dials it). The clients assert against the
// demo's own member roster, so an attached room may have other people in it,
// chatting away — they are shown in the transcripts but never counted.

import { ANNOUNCE_RE, announceToLocator, loopbackTcpDesignator } from "./deno/lib/locator.ts";
import {
	buildRust,
	onPath,
	parseCliArgs,
	requireZigClientPath,
	runChild,
	stopSpawnedServer,
	validatePortOptions,
} from "../_demo/orchestrator.ts";

const positional: string[] = [];
const cliArgs: string[] = [];
let transport: "tcp" | "iroh" = "tcp";
for (const a of Deno.args) {
	if (a === "--attach" || a.startsWith("--port=")) cliArgs.push(a);
	else if (a.startsWith("--transport=")) {
		const t = a.slice("--transport=".length);
		if (t !== "tcp" && t !== "iroh") {
			console.error('demo.ts: --transport must be "tcp" or "iroh"');
			Deno.exit(2);
		}
		transport = t;
	} else positional.push(a);
}
const { pinPort, attach } = parseCliArgs(cliArgs);
const ZIG_CLIENT = requireZigClientPath(
	positional,
	"demo.ts: missing the Zig client path (run via `zig build demo-rooms`)",
);
validatePortOptions(pinPort, attach, "demo.ts");

const ROOT = Deno.cwd();
// The one room every demo client enters. The first client to run opens it; the
// rest enter it. It is named so the demo exercises the directory's open/enter,
// not a single hardcoded room.
const ROOM = "demo";
// iroh dials through the sidecar over Deno's nonblocking FFI, which needs
// --unstable-ffi (and the iroh lib reads its own path), so iroh mode runs the
// child processes with broader permissions.
const DENO_FLAGS = transport === "iroh"
	? ["run", "-A", "--unstable-ffi"]
	: ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];

interface Member {
	name: string;
	/** The nick this member joins with, the roster every client asserts against. */
	nick: string;
	cmd: string;
	/** The client's args, once we know the locator and the full member roster. */
	argv: (locator: string, roster: string) => string[];
}

/** True if `cmd` can be spawned at all, the cross-platform way to ask "is this
 * runtime on PATH?" without a shell. */
async function buildRustClient(): Promise<boolean> {
	const features = transport === "iroh" ? ["iroh"] : undefined;
	return buildRust(ROOT, "examples/apps/rooms/rust/Cargo.toml", features);
}

/** Decide who plays. Deno and Zig always; the others only when present. */
async function roster(): Promise<{ members: Member[]; skipped: string[] }> {
	const members: Member[] = [
		{
			name: "deno",
			nick: "deno-ada",
			cmd: "deno",
			argv: (
				loc,
				r,
			) => [
				...DENO_FLAGS,
				`${ROOT}/examples/apps/rooms/deno/client.ts`,
				loc,
				ROOM,
				"deno-ada",
				"hello from deno",
				r,
			],
		},
		{
			name: "zig",
			nick: "zig-niklaus",
			cmd: ZIG_CLIENT,
			argv: (loc, r) => [loc, ROOM, "zig-niklaus", "hello from zig", r],
		},
	];
	const skipped: string[] = [];

	if (await onPath("python3")) {
		members.push({
			name: "python",
			nick: "py-grace",
			cmd: "python3",
			argv: (
				loc,
				r,
			) => [
				`${ROOT}/examples/apps/rooms/python/client.py`,
				loc,
				ROOM,
				"py-grace",
				"hello from python",
				r,
			],
		});
	} else skipped.push("python (no python3 on PATH)");

	if (await onPath("racket")) {
		members.push({
			name: "racket",
			nick: "rkt-alan",
			cmd: "racket",
			argv: (
				loc,
				r,
			) => [
				`${ROOT}/examples/apps/rooms/racket/client.rkt`,
				loc,
				ROOM,
				"rkt-alan",
				"hello from racket",
				r,
			],
		});
	} else skipped.push("racket (no racket on PATH)");

	if (await onPath("cargo")) {
		if (await buildRustClient()) {
			members.push({
				name: "rust",
				nick: "rs-barbara",
				cmd: `${ROOT}/examples/apps/rooms/rust/target/debug/rooms-client`,
				argv: (loc, r) => [loc, ROOM, "rs-barbara", "hello from rust", r],
			});
		} else skipped.push("rust (cargo build failed)");
	} else skipped.push("rust (no cargo on PATH)");

	return { members, skipped };
}

/** Wait for the server's first line, "ROOMS-SERVER-LISTENING <token>", and
 * resolve it to a dial locator (a TCP host:port, or an iroh ocapn:// URI). */
async function readLocator(server: Deno.ChildProcess): Promise<string> {
	const reader = server.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value);
		const m = buf.match(ANNOUNCE_RE);
		if (m) {
			reader.releaseLock();
			return announceToLocator(m[1]);
		}
	}
	reader.releaseLock();
	throw new Error("server never announced its locator");
}

async function runMember(m: Member, locator: string, roster: string) {
	const r = await runChild(m.cmd, m.argv(locator, roster), ROOT);
	return { name: m.name, code: r.code, out: r.out };
}

const { members, skipped } = await roster();
for (const s of skipped) console.log(`rooms demo: skipping ${s}`);

if (attach && transport === "iroh") {
	console.error(
		"demo.ts: --attach is TCP-only (an iroh room has no fixed port to rejoin)",
	);
	Deno.exit(2);
}

// With --attach the server is yours, already running; otherwise spawn one on the
// chosen transport (TCP on the pinned/ephemeral port, or iroh on a fresh
// endpoint that announces its ocapn:// URI).
const serverArgs = transport === "iroh"
	? [`${ROOT}/examples/apps/rooms/deno/server.ts`, "--transport=iroh"]
	: [`${ROOT}/examples/apps/rooms/deno/server.ts`, String(pinPort)];
const server = attach ? null : new Deno.Command("deno", {
	args: [...DENO_FLAGS, ...serverArgs],
	stdout: "piped",
	stderr: "inherit",
	cwd: ROOT,
}).spawn();

let failed = false;
try {
	// No liveness probe in attach mode: on loopback a missing server refuses each
	// client's connect immediately, which is already a loud, fast failure.
	const locator = server ? await readLocator(server) : loopbackTcpDesignator(pinPort!);
	// Every client asserts against this roster — exactly the demo's own members —
	// so residents of an attached room (and their chatter) are shown but never
	// counted, and cannot fake or break the all-to-all proof.
	const roster = members.map((m) => m.nick).join(",");
	console.log(
		`rooms demo: server at ${locator}; joining ${members.length} members (${
			members.map((m) => m.name).join(", ")
		})\n`,
	);

	const results = await Promise.all(
		members.map((m) => runMember(m, locator, roster)),
	);
	for (const r of results) {
		console.log(`──────── ${r.name} (exit ${r.code}) ────────`);
		console.log(r.out.trimEnd());
		console.log("");
		if (r.code !== 0) failed = true;
	}

	if (failed) {
		console.error(
			"rooms demo FAILED: at least one client did not complete the all-to-all broadcast",
		);
	} else {
		const langs = members.length === 1 ? "1 language" : `${members.length} languages`;
		console.log(
			`rooms demo OK: ${langs} held one capability-secure room and every member saw every message`,
		);
		if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
	}
} finally {
	await stopSpawnedServer(server);
}

Deno.exit(failed ? 1 : 0);
