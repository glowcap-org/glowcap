// Live interop proof for the Deno binding: a peer built on `libpancake`'s C ABI
// holds a *keyed* OCapN conversation with a real Spritely Goblins vat over TCP —
// driven through the *same* `connect`/`enliven`/`send` application surface the
// cross-language demos use, so what is proven against a real Goblins vat is the
// application API itself, not a bespoke handshake script.
//
// It spawns the conformance Goblins host, learns the echo cap's swiss-num from
// its NDJSON readiness line, then: `connect` (keyed `op:start-session`),
// `enliven` the echo sturdyref (bootstrap fetch + ADR-0012 dedup cache),
// `send` a positional call, then a repeat `enliven` of the same swiss-num
// (cache hit, no second bootstrap). Needs `racket` + `goblins` on PATH;
// `zig build deno-goblins-interop`.

import { connect, tcpLocator } from "@pancake/stack";
import { fail, readSwiss } from "../_common/deno/helpers.ts";

const HOST = "127.0.0.1";
// The Goblins vat's fixed port; `--port=N` (from
// `zig build deno-goblins-interop -Dport=N`) moves it when 22098 is taken.
let PORT = 22098;
for (const a of Deno.args) {
	if (a.startsWith("--port=")) PORT = Number(a.slice("--port=".length));
	else fail("deno-goblins-interop", `unknown argument '${a}'`);
}
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
	fail("deno-goblins-interop", "--port must be an integer in 1..65535");
}
const RACKET = "/usr/local/bin/racket";
const HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt";

const child = new Deno.Command(RACKET, {
	args: [HOST_SCRIPT, HOST, String(PORT)],
	stdout: "piped",
	stderr: "piped",
}).spawn();

const stdoutReader = child.stdout.getReader();

let ok = false;
try {
	const swiss = await readSwiss(
		stdoutReader,
		"deno-goblins-interop",
		"never saw the Goblins echo cap readiness line",
	);
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

	// Peer URI host is ignored once the session is open; enliven keys on swiss.
	const sturdyref = `ocapn://goblins-echo.tcp/s/${swiss}`;
	const echo = await conn.enliven(sturdyref);
	console.log("deno-goblins-interop: enlivened goblins echo cap, calling it");

	// Goblins invokes a cap positionally (no method symbol), so send with verb "".
	// The echo actor is `(lambda args args)`: it returns its argument list, so
	// assert the content survived the round-trip (the native driver's bar),
	// not merely that something resolved.
	const assertEchoed = (reply: unknown, expected: string): void => {
		if (!Array.isArray(reply) || reply.length !== 1 || !(reply[0] instanceof Uint8Array)) {
			fail("deno-goblins-interop", `echo reply is not a one-bytes list: ${JSON.stringify(reply)}`);
		}
		const text = new TextDecoder().decode(reply[0] as Uint8Array);
		if (text !== expected) {
			fail("deno-goblins-interop", `echo returned ${JSON.stringify(text)}, expected ${expected}`);
		}
	};
	assertEchoed(await conn.send(echo, "", [new TextEncoder().encode("pancake-ping")]), "pancake-ping");

	const again = await conn.enliven(sturdyref);
	if (
		echo.reference.kind !== "far" ||
		again.reference.kind !== "far" ||
		echo.reference.id !== again.reference.id
	) {
		fail(
			"deno-goblins-interop",
			"repeat enliven did not return the same far import (dedup miss)",
		);
	}
	assertEchoed(
		await conn.send(again, "", [new TextEncoder().encode("pancake-ping-again")]),
		"pancake-ping-again",
	);
	console.log(
		"deno-goblins-interop: repeat enliven same import (dedup), second call resolved",
	);

	ok = true;
	console.log(
		"deno-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins",
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
