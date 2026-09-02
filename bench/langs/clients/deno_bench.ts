// The Deno bench client for the per-language consumer-cost bench. It drives the
// taskboard unit against the fixed Zig host through glowcap's Deno binding (the
// same connect/fetch/send the demos use) and prints one NDJSON metric line in
// the shared schema (see bench/langs/contract.md).
//
//   deno run --allow-ffi --allow-read --allow-net deno_bench.ts <mode> <host> <port> <n>

import { type Argument, type Ref, Runtime, type Session } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";

const CLIENT = "deno";
const RUNTIME = `deno/${Deno.version.deno}`;

const [mode, host, portStr, nStr] = Deno.args;
const port = Number(portStr);
const N = Number(nStr ?? "0");
const decoder = new TextDecoder();
await using runtime = await Runtime.open({ providers: [tcp.provider()] });

// V8 only exposes a manual collection under `--v8-flags=--expose-gc`, which the
// orchestrator passes; calling it before each measured window gives Deno the
// same GC-settled start every other garbage-collected row gets. If the flag is
// ever absent this is a no-op rather than a crash.
const forceGc: () => void = (globalThis as { gc?: () => void }).gc ??
	(() => {});

function sleep(ms: number): Promise<void> {
	return new Promise((r) => setTimeout(r, ms));
}

function percentileMs(sorted: number[], p: number): number {
	if (sorted.length === 0) return 0;
	const rank = Math.ceil(p * sorted.length);
	return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

function statusText(v: Argument): string {
	if (v instanceof Uint8Array) return decoder.decode(v);
	return String(v);
}

// One bench unit: create -> assign -> complete -> status, asserting the status
// settles to the bytes `done`.
async function runUnit(conn: Session, root: Ref): Promise<void> {
	const task = await conn.send(root, "create", ["benchmark"]) as Ref;
	await conn.send(task, "assign", ["alice"]);
	await conn.send(task, "complete", []);
	const status = await conn.send(task, "status", []);
	if (statusText(status) !== "done") {
		throw new Error(`bad status: ${statusText(status)}`);
	}
}

// The same four verbs as runUnit, but pipelined (ADR-0007, questioner half):
// assign/complete/status are addressed at the answer `create` will resolve to —
// the RemotePromise it returns, passed as the send target. assign/complete are
// one-way deliveries; only status allocates an answer and is awaited. The unit
// costs one round trip without leaving discarded result promises behind.
async function runUnitPipelined(conn: Session, root: Ref): Promise<void> {
	const create = conn.send(root, "create", ["benchmark"]);
	await conn.tell(create, "assign", ["alice"]);
	await conn.tell(create, "complete", []);
	const status = await conn.send(create, "status", []);
	if (statusText(status) !== "done") {
		throw new Error(`bad status: ${statusText(status)}`);
	}
}

const WARMUP = Math.min(N, 500);

type HeldConnection = {
	readonly runtime: Runtime;
	readonly session: Session;
	readonly serving: Promise<void>;
	readonly closeRuntime: boolean;
};

async function openHeldConnection(reuse?: Runtime): Promise<HeldConnection> {
	const heldRuntime = reuse ?? await Runtime.open({ providers: [tcp.provider()] });
	try {
		const session = await heldRuntime.connect(tcp.locator(host, port));
		const serving = session.serve();
		await session.fetch("root");
		return { runtime: heldRuntime, session, serving, closeRuntime: reuse == null };
	} catch (error) {
		if (reuse == null) await heldRuntime.close().catch(() => {});
		throw error;
	}
}

async function closeHeldConnection(held: HeldConnection): Promise<void> {
	await Promise.all([held.session.close(), held.serving]);
	if (held.closeRuntime) await held.runtime.close();
}

async function warm(
	conn: Session,
	root: Ref,
	unit: (conn: Session, root: Ref) => Promise<void> = runUnit,
): Promise<void> {
	for (let i = 0; i < WARMUP; i++) await unit(conn, root);
	forceGc();
}

async function runLatency(): Promise<void> {
	const conn = await runtime.connect(tcp.locator(host, port));
	const serving = conn.serve();
	const root = await conn.fetch("root");
	await warm(conn, root);
	const lats: number[] = [];
	for (let i = 0; i < N; i++) {
		const s = performance.now();
		await runUnit(conn, root);
		lats.push(performance.now() - s);
	}
	await Promise.all([conn.close(), serving]);
	lats.sort((a, b) => a - b);
	const mean = lats.reduce((a, b) => a + b, 0) / Math.max(1, N);
	console.log(JSON.stringify({
		v: 1,
		metric: "latency",
		client: CLIENT,
		suite: "taskboard",
		n: N,
		p50_ms: +percentileMs(lats, 0.5).toFixed(4),
		p99_ms: +percentileMs(lats, 0.99).toFixed(4),
		p999_ms: +percentileMs(lats, 0.999).toFixed(4),
		mean_ms: +mean.toFixed(4),
		runtime: RUNTIME,
		warmup_n: WARMUP,
	}));
}

async function runThroughput(): Promise<void> {
	const conn = await runtime.connect(tcp.locator(host, port));
	const serving = conn.serve();
	const root = await conn.fetch("root");
	await warm(conn, root, runUnitPipelined);
	const t0 = performance.now();
	for (let i = 0; i < N; i++) await runUnitPipelined(conn, root);
	const total = performance.now() - t0;
	await Promise.all([conn.close(), serving]);
	console.log(JSON.stringify({
		v: 1,
		metric: "throughput",
		client: CLIENT,
		suite: "taskboard",
		n: N,
		total_ms: +total.toFixed(2),
		rps: Math.round(total <= 0 ? 0 : N / (total / 1000)),
		runtime: RUNTIME,
		warmup_n: WARMUP,
	}));
}

async function runConnections(): Promise<void> {
	const warmConns: HeldConnection[] = [];
	const warmup = Math.min(N, 5);
	for (let i = 0; i < warmup; i++) {
		warmConns.push(await openHeldConnection(i === 0 ? runtime : undefined));
	}
	forceGc();
	console.log(JSON.stringify({ v: 1, event: "warmed" }));
	await sleep(600);
	const handles: HeldConnection[] = [];
	const t0 = performance.now();
	for (let i = 0; i < N; i++) {
		handles.push(await openHeldConnection());
	}
	const total = performance.now() - t0;
	console.log(JSON.stringify({
		v: 1,
		metric: "connections",
		client: CLIENT,
		suite: "taskboard",
		conns: N,
		total_ms: +total.toFixed(2),
		per_conn_ms: +(total / Math.max(1, N)).toFixed(4),
		runtime: RUNTIME,
	}));
	await sleep(2500);
	for (const held of handles) await closeHeldConnection(held);
	for (const held of warmConns) await closeHeldConnection(held);
}

async function runCold(): Promise<void> {
	const conn = await runtime.connect(tcp.locator(host, port));
	const serving = conn.serve();
	const root = await conn.fetch("root");
	await runUnit(conn, root);
	await Promise.all([conn.close(), serving]);
	console.log(JSON.stringify({ v: 1, event: "cold-done", client: CLIENT }));
}

// The local-turn counter behavior: `hit` increments and returns the count, any
// other verb throws. Returned as a fresh closure per use so the two paths of
// runLocal never share a count.
function counterBehavior(): (verb: string) => bigint {
	let count = 0n;
	return (verb: string): bigint => {
		if (verb !== "hit") throw new Error(`counter: no such method ${verb}`);
		count += 1n;
		return count;
	};
}

// Run min(N, 500) warmup hits then N measured sequential send→settle units
// against `target`, asserting the final count equals warmup + N. Returns the
// sorted per-turn latencies in nanoseconds.
async function measureHits(conn: Session, target: Ref): Promise<number[]> {
	for (let i = 0; i < WARMUP; i++) await conn.send(target, "hit", []);
	forceGc();
	const lats: number[] = [];
	let last: Argument = 0n;
	for (let i = 0; i < N; i++) {
		const s = performance.now();
		last = await conn.send(target, "hit", []);
		lats.push((performance.now() - s) * 1e6);
	}
	if (Number(last) !== WARMUP + N) {
		throw new Error(`bad final count ${last} (expected ${WARMUP + N})`);
	}
	lats.sort((a, b) => a - b);
	return lats;
}

// The `local` mode (see contract.md): (a) in_lang — a counter spawned on this
// connection, dispatched in process by the binding's own local path; (b)
// via_host — the same behavior published across a loopback pair inside this
// process (listen on 127.0.0.1:0 + connect to itself), so every turn pays wire
// codec, feed, trampoline, and marshal both ways. The orchestrator's host/port
// arguments are unused; the pair is self-contained.
async function runLocal(): Promise<void> {
	const server = await tcp.listen("127.0.0.1", 0);
	const accepted = server[Symbol.asyncIterator]().next();
	const loopPort = server.port;
	const dial = await runtime.connect(tcp.locator("127.0.0.1", loopPort));
	const dialServing = dial.serve();
	const acceptedConn = (await accepted).value as Session;
	acceptedConn.publish("counter", counterBehavior());
	const acceptedServing = acceptedConn.serve();

	// (a) in_lang: the binding's in-process actor dispatch.
	const local = dial.spawn(counterBehavior());
	const inLang = await measureHits(dial, local);

	// (b) via_host: the published counter across the loopback pair.
	const far = await dial.fetch("counter");
	const viaHost = await measureHits(dial, far);

	await Promise.all([
		dial.close(),
		dialServing,
		acceptedConn.close(),
		acceptedServing,
		server.close(),
	]);

	const inMean = inLang.reduce((a, b) => a + b, 0) / Math.max(1, N);
	const viaMean = viaHost.reduce((a, b) => a + b, 0) / Math.max(1, N);
	console.log(JSON.stringify({
		v: 1,
		metric: "local",
		client: CLIENT,
		suite: "local-turn",
		n: N,
		in_lang_ns: +inMean.toFixed(1),
		in_lang_p99_ns: +percentileMs(inLang, 0.99).toFixed(1),
		via_host_ns: +viaMean.toFixed(1),
		via_host_p99_ns: +percentileMs(viaHost, 0.99).toFixed(1),
		ratio: inMean > 0 ? +(viaMean / inMean).toFixed(2) : 0,
		runtime: RUNTIME,
		warmup_n: WARMUP,
	}));
}

switch (mode) {
	case "latency":
		await runLatency();
		break;
	case "throughput":
		await runThroughput();
		break;
	case "connections":
		await runConnections();
		break;
	case "cold":
		await runCold();
		break;
	case "local":
		await runLocal();
		break;
	default:
		console.error(`unknown mode: ${mode}`);
		Deno.exit(2);
}
