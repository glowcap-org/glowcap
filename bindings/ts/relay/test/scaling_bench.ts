// The relay tier's answer to `bench-peer-scaling`: measure what one more relayed
// connection actually costs the reference relay, then extrapolate to the numbers
// a real host supports. The core's 500k figure is a property of the sans-io
// engine (~2 KiB per session); this is the separate, measured figure for the
// byte-transparent relay in front of it.
//
// The relay holds no CapTP session state. Per relayed connection it keeps a
// WebSocket, a ReadableStream over it, and the far socket it forwards to, so the
// marginal cost is runtime and kernel socket overhead, not pancake buffers. This
// harness stands up the real reference relay (through `scaling_probe.ts`, which
// imports `serve.ts` unchanged and reports the relay's own resident memory),
// opens N live relayed connections through it to a local TCP sink, and divides
// the resident-memory delta by N. From that one number it reports how many
// connections fit in common RAM sizes and under the host's own descriptor limit.
//
// It also *proves* the relay holds many connections at once, not the demo's
// conservative default: the run fails unless every opened connection was accepted
// end to end and the marginal cost stays under a ceiling, so a change that gave
// each connection a fat buffer would trip it.
//
// Run:
//   deno run --allow-net --allow-run --allow-write \
//     bindings/ts/relay/test/scaling_bench.ts [--conns=N] [--report] [--smoke] \
//     [--max-per-conn-kib=K]
//
// The measurement extrapolates, so N need only be large enough to average out
// runtime noise; it does not need to reach the target scale. A too-large N on a
// small host fails loudly ("only X/N established") rather than reporting a bad
// number; lower --conns to the host's descriptor budget.

interface Args {
	conns: number;
	report: boolean;
	smoke: boolean;
	maxPerConnKib: number | null;
}

function parseArgs(argv: string[]): Args {
	let conns = 2000;
	let report = false;
	let smoke = false;
	let maxPerConnKib: number | null = null;
	for (const a of argv) {
		if (a === "--report") report = true;
		else if (a === "--smoke") smoke = true;
		else if (a.startsWith("--conns=")) conns = Number(a.slice("--conns=".length));
		else if (a.startsWith("--max-per-conn-kib=")) {
			maxPerConnKib = Number(a.slice("--max-per-conn-kib=".length));
		}
	}
	if (smoke) conns = 64;
	return { conns, report, smoke, maxPerConnKib };
}

// The spawned relay is a separate process that Deno does not reap on `Deno.exit`,
// and `Deno.exit` skips `finally`, so every exit path must kill it explicitly or
// it survives holding its port and descriptors. `fail` reaps it before exiting.
let probeChild: Deno.ChildProcess | null = null;

function fail(msg: string): never {
	if (probeChild) {
		try {
			probeChild.kill("SIGKILL");
		} catch { /* already gone */ }
	}
	console.error(`relay-scaling: ${msg}`);
	Deno.exit(1);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function openWs(url: string): Promise<WebSocket> {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(url);
		ws.binaryType = "arraybuffer";
		ws.addEventListener("open", () => resolve(ws), { once: true });
		ws.addEventListener("error", () => reject(new Error("ws error")), { once: true });
	});
}

function humanBytes(n: number): string {
	if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(2)} GiB`;
	if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(2)} MiB`;
	if (n >= 1 << 10) return `${(n / (1 << 10)).toFixed(2)} KiB`;
	return `${n} B`;
}

interface RelayProbe {
	child: Deno.ChildProcess;
	port: number;
	/** Latest resident-memory sample the relay reported, in bytes. */
	rss: () => number;
}

/** Spawn the relay through the probe and track its reported resident memory from
 * stdout, live, while the harness opens connections. */
async function startRelayProbe(): Promise<RelayProbe> {
	const child = new Deno.Command(Deno.execPath(), {
		args: [
			"run",
			"--allow-net",
			"--allow-read",
			"--allow-env",
			"bindings/ts/relay/test/scaling_probe.ts",
			"0",
		],
		stdout: "piped",
		stderr: "inherit",
		// No application bytes ever traverse these connections, so the relay's
		// idle timeout must sit well above the run's wall clock, or the
		// earliest-opened connections could be reclaimed while the last ones are
		// still opening and spuriously fail the establish check.
		env: { PANCAKE_RELAY_IDLE_MS: "600000" },
	}).spawn();
	probeChild = child;

	let latestRss = 0;
	let resolvePort: (p: number) => void = () => {};
	const portReady = new Promise<number>((r) => (resolvePort = r));

	(async () => {
		const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
		let buf = "";
		while (true) {
			const { value, done } = await reader.read();
			if (done) break;
			buf += value;
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, nl);
				buf = buf.slice(nl + 1);
				const ready = line.match(/DENO-RELAY-READY (\d+)/);
				if (ready) {
					resolvePort(Number(ready[1]));
					continue;
				}
				const rss = line.match(/RELAY-RSS (\d+)/);
				if (rss) latestRss = Number(rss[1]);
			}
		}
	})();

	const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timeout")), 15_000));
	let readyPort: number;
	try {
		readyPort = await Promise.race([portReady, timeout]);
	} catch {
		fail("relay probe did not become ready"); // reaps probeChild before exit
	}
	return { child, port: readyPort, rss: () => latestRss };
}

async function main() {
	const args = parseArgs(Deno.args);
	const N = args.conns;

	// A local TCP sink: accept every relay dial and drain it, so a relayed
	// connection is a fully established end-to-end byte pipe, not a half-open one.
	const sink = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const sinkPort = (sink.addr as Deno.NetAddr).port;
	let sinkAccepted = 0;
	const sinkConns: Deno.Conn[] = [];
	(async () => {
		for await (const conn of sink) {
			sinkAccepted++;
			sinkConns.push(conn);
			(async () => {
				const b = new Uint8Array(4096);
				try {
					while (await conn.read(b) !== null) { /* drain */ }
				} catch { /* torn down */ }
			})();
		}
	})();

	const probe = await startRelayProbe();
	const relayPort = probe.port;

	const wsUrl = `ws://127.0.0.1:${relayPort}/relay?to=127.0.0.1:${sinkPort}`;
	const held: WebSocket[] = [];

	// Open more relayed connections (on top of whatever is already held) and wait
	// until every one is established end to end through the sink.
	const openUpTo = async (target: number): Promise<void> => {
		const batch = 128;
		for (let i = held.length; i < target; i += batch) {
			const chunk = [];
			for (let j = i; j < Math.min(i + batch, target); j++) chunk.push(openWs(wsUrl));
			try {
				for (const ws of await Promise.all(chunk)) held.push(ws);
			} catch {
				// A WebSocket that never opens is almost always fd exhaustion on this
				// host; report what was held and how to proceed, not a raw stack.
				fail(
					`only ${held.length}/${target} WebSockets opened (fd limit likely; lower --conns)`,
				);
			}
		}
		const deadline = Date.now() + 60_000;
		while (sinkAccepted < target && Date.now() < deadline) await sleep(20);
		if (sinkAccepted < target) {
			fail(`only ${sinkAccepted}/${target} relayed connections established end to end`);
		}
	};

	await sleep(400);
	const rss0 = probe.rss();

	// Two-point measurement. The first half pays the one-time costs (V8 JIT, the
	// relay's first-connection code paths, stream machinery), so the memory the
	// *second* half adds is the marginal cost of one more connection, with the
	// warmup already subtracted out.
	const warm = Math.max(1, Math.floor(N / 2));
	await openUpTo(warm);
	await sleep(600);
	const rssMid = probe.rss();

	await openUpTo(N);
	if (held.length !== N) fail(`only ${held.length}/${N} WebSockets opened`);
	await sleep(600);
	const rss1 = probe.rss();

	if (rss0 === 0 || rss1 === 0) fail("relay did not report resident memory");

	const marginalCount = N - warm;
	const perConn = marginalCount > 0 ? (rss1 - rssMid) / marginalCount : (rss1 - rss0) / N;
	const grossPerConn = (rss1 - rss0) / N;

	// RSS is a high-water mark that can also fall as V8 releases pages, so a quiet
	// run can sample a non-positive delta. On a real measurement that is noise, not
	// a number: fail loud rather than print a zero-fits table that looks
	// authoritative. A smoke run is only a functional check, so tolerate it.
	if (!args.smoke && !(perConn > 0)) {
		fail("non-positive marginal cost; the sample is noise, rerun with a larger --conns");
	}

	const ramBudgets = [1, 2, 4, 8, 16];
	const ramRows = ramBudgets.map((gib) => ({
		gib,
		fit: perConn > 0 ? Math.floor((gib * (1 << 30)) / perConn) : 0,
	}));

	const lines: string[] = [];
	lines.push("# Relay scaling");
	lines.push("");
	lines.push("The byte-transparent reference relay (`bindings/ts/relay/serve.ts`) holds no");
	lines.push("CapTP session state, so one more relayed connection costs only runtime and");
	lines.push("socket overhead. Measured here, then extrapolated.");
	lines.push("");
	lines.push(`- connections opened: ${N} (all established end to end)`);
	lines.push(`- relay resident before: ${humanBytes(rss0)}`);
	lines.push(`- relay resident after: ${humanBytes(rss1)}`);
	lines.push(
		`- marginal cost per connection: ${humanBytes(perConn)} ` +
			`(the second ${marginalCount}, warmup already paid)`,
	);
	lines.push(
		`- gross cost per connection: ${humanBytes(grossPerConn)} (includes warmup over all ${N})`,
	);
	lines.push("");
	lines.push("Connections that fit, by RAM budget (memory-bound):");
	lines.push("");
	lines.push("| RAM | connections |");
	lines.push("| --- | --- |");
	for (const r of ramRows) lines.push(`| ${r.gib} GiB | ${r.fit.toLocaleString()} |`);
	lines.push("");
	lines.push(
		"The other bound is file descriptors: each relayed connection is two, so a " +
			"host's open-file limit divided by two is the descriptor ceiling. A 65,536 " +
			"limit holds about 32k connections; a 1,048,576 limit holds about 500k.",
	);
	lines.push("");
	const report = lines.join("\n");
	console.log(report);

	if (args.report) {
		try {
			Deno.mkdirSync("zig-out/bench-reports", { recursive: true });
			Deno.writeTextFileSync("zig-out/bench-reports/relay-scaling.md", report + "\n");
			console.log("relay-scaling: wrote zig-out/bench-reports/relay-scaling.md");
		} catch (err) {
			console.error(`relay-scaling: could not write report: ${err}`);
		}
	}

	// Proof: the relay held every connection, and the marginal cost is small. The
	// ceiling bounds the gross figure, which folds the fixed warmup over N and so
	// runs higher at small N (about 90 KiB at N=2000, more below that). 160 KiB
	// clears that warmup headroom while still catching a real regression: a
	// per-connection buffer would push the cost into the hundreds of KiB or MiB.
	const ceilingKib = args.maxPerConnKib ?? (args.smoke ? null : 160);
	if (ceilingKib !== null && grossPerConn > ceilingKib * 1024) {
		fail(
			`gross cost ${humanBytes(grossPerConn)} exceeds the ${ceilingKib} KiB ceiling; ` +
				"a per-connection buffer regressed the relay's footprint",
		);
	}

	// Teardown.
	for (const ws of held) {
		try {
			ws.close();
		} catch { /* already closed */ }
	}
	for (const c of sinkConns) {
		try {
			c.close();
		} catch { /* already closed */ }
	}
	try {
		sink.close();
	} catch { /* already closed */ }
	try {
		probe.child.kill("SIGKILL");
	} catch { /* gone */ }
	await probe.child.status;

	console.log(
		`relay-scaling: held ${N} concurrent relayed connections at ` +
			`${humanBytes(perConn)} each, well past the conservative admission floor.`,
	);
	Deno.exit(0);
}

await main();
