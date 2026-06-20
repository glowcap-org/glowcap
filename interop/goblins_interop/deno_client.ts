// Live interop proof for the Deno binding: a peer built on `libpancake`'s C ABI
// holds a *keyed* OCapN conversation with a real Spritely Goblins vat over TCP —
// driven through the *same* `connect`/`fetch`/`send` application surface the
// cross-language demos use, so what is proven against a real Goblins vat is the
// application API itself, not a bespoke handshake script.
//
// It spawns the conformance Goblins host, learns the echo cap's swiss-num from
// its NDJSON readiness line, then: `connect` (which completes the keyed
// `op:start-session` handshake), `fetch` the echo cap by swiss-num, and `send`
// it a positional call — asserting Goblins resolves it. Needs `racket` plus the
// `goblins` collection on PATH, so it runs as the sibling build step
// `zig build deno-goblins-interop`.

import { connect, tcpLocator } from "@pancake/stack";

const HOST = "127.0.0.1";
// The Goblins vat's fixed port; `--port=N` (from
// `zig build deno-goblins-interop -Dport=N`) moves it when 22098 is taken.
let PORT = 22098;
for (const a of Deno.args) {
	if (a.startsWith("--port=")) PORT = Number(a.slice("--port=".length));
	else fail(`unknown argument '${a}'`);
}
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
	fail("--port must be an integer in 1..65535");
}
const RACKET = "/usr/local/bin/racket";
const HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt";

function fail(msg: string): never {
	console.error(`deno-goblins-interop FAILED: ${msg}`);
	Deno.exit(1);
}

const child = new Deno.Command(RACKET, {
	args: [HOST_SCRIPT, HOST, String(PORT)],
	stdout: "piped",
	stderr: "piped",
}).spawn();

const stdoutReader = child.stdout.getReader();

async function readSwiss(): Promise<string> {
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await stdoutReader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		const m = buf.match(/"swiss":"([^"]+)"/);
		if (m) return m[1];
	}
	fail("never saw the Goblins echo cap readiness line");
}

let ok = false;
try {
	const swiss = await readSwiss();
	console.log(
		`deno-goblins-interop: goblins published echo swiss=${swiss} on ${HOST}:${PORT}`,
	);

	// `connect` completes the keyed handshake; reaching here means Goblins accepted
	// our signed start-session and we accepted its.
	const conn = await connect(tcpLocator(HOST, PORT));
	console.log(
		"deno-goblins-interop: session open, keyed start-session accepted by goblins",
	);
	conn.serve().catch(() => {}); // the partner hanging up ends the serve loop

	const echo = await conn.fetch(swiss);
	console.log("deno-goblins-interop: fetched goblins echo cap, calling it");

	// Goblins invokes a cap positionally (no method symbol), so send with verb "".
	await conn.send(echo, "", [new TextEncoder().encode("pancake-ping")]);

	ok = true;
	console.log(
		"deno-goblins-interop OK: keyed handshake + bootstrap fetch + echo deliver/resolve with live Goblins",
	);
	conn.close();
} finally {
	try {
		await stdoutReader.cancel();
	} catch { /* already released */ }
	try {
		await child.stderr.cancel();
	} catch { /* already released */ }
	try {
		child.kill();
	} catch { /* already gone */ }
	await child.status;
}

if (!ok) Deno.exit(1);
