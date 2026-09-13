import * as tcp from "@glowcap/tcp";
// Live interop proof for the Deno binding: a peer built on `libglowcap`'s C ABI
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

import { formatLocatorUri, Ref, Runtime } from "@glowcap/runtime";
import { fail, readSturdyrefPath } from "../_common/deno/helpers.ts";

// The build enables V8's collector, as the binding's GC smoke does. Native
// answer lifetime follows the promise wrapper even after its value settles.
declare const gc: () => void;

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
const RACKET = "racket";
const HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt";

const child = new Deno.Command(RACKET, {
	args: [HOST_SCRIPT, HOST, String(PORT)],
	stdout: "piped",
	stderr: "piped",
}).spawn();

const stdoutReader = child.stdout.getReader();

let ok = false;
try {
	const sturdyrefPath = await readSturdyrefPath(
		stdoutReader,
		"deno-goblins-interop",
		"never saw the Goblins echo sturdyref path readiness field",
	);
	console.log(
		`deno-goblins-interop: goblins published its echo sturdyref path on ${HOST}:${PORT}`,
	);

	// `connect` completes the keyed handshake; reaching here means Goblins accepted
	// our signed start-session and we accepted its.
	const locator = tcp.locator(HOST, PORT);
	await using runtime = await Runtime.open({ providers: [tcp.provider()] });
	const session = await runtime.connect(locator);
	console.log(
		"deno-goblins-interop: session open, keyed start-session accepted by goblins",
	);
	session.serve().catch(() => {}); // the partner hanging up ends the serve loop

	// Peer URI host is ignored once the session is open; enliven keys on swiss.
	// A sturdyref names a peer, and the enliven checks that peer against the
	// session it rides (ADR-0098). Build it from the very locator this session
	// dialed, so the two cannot drift apart.
	const sturdyref = `${formatLocatorUri(locator)}/s/${sturdyrefPath}`;
	const echo = await session.enliven(sturdyref);
	console.log("deno-goblins-interop: enlivened goblins echo cap, calling it");

	// Goblins invokes a cap positionally (no method symbol), so send with verb "".
	// The echo actor is `(lambda args args)`: it returns its argument list, so
	// assert the content survived the round-trip (the native driver's bar),
	// not merely that something resolved.
	const assertEchoed = (reply: unknown, expected: string): void => {
		if (!Array.isArray(reply) || reply.length !== 1 || !(reply[0] instanceof Uint8Array)) {
			fail(
				"deno-goblins-interop",
				`echo reply is not a one-bytes list: ${JSON.stringify(reply)}`,
			);
		}
		const text = new TextDecoder().decode(reply[0] as Uint8Array);
		if (text !== expected) {
			fail(
				"deno-goblins-interop",
				`echo returned ${JSON.stringify(text)}, expected ${expected}`,
			);
		}
	};
	assertEchoed(
		await session.send(echo, "", [new TextEncoder().encode("glowcap-ping")]),
		"glowcap-ping",
	);

	const again = await session.enliven(sturdyref);
	if (echo.id !== again.id) {
		fail(
			"deno-goblins-interop",
			"repeat enliven did not return the same Host identity (dedup miss)",
		);
	}
	assertEchoed(
		await session.send(again, "", [new TextEncoder().encode("glowcap-ping-again")]),
		"glowcap-ping-again",
	);
	console.log(
		"deno-goblins-interop: repeat enliven same import (dedup), second call resolved",
	);

	const probe = await session.fetch("glowcapGcProbeSwissnumABCDEF1234");
	const made = await session.send(probe, "make", []);
	if (!Array.isArray(made) || made.length !== 2 || !(made[0] instanceof Ref) || !(made[1] instanceof Ref)) {
		fail("deno-goblins-interop", "GC probe did not return two capabilities");
	}
	const [first, second] = made as [Ref, Ref];
	session.release(first);
	if (
		await session.send(second, "read", []) !== "still held" || await session.send(probe, "collected?", []) !== false
	) {
		fail("deno-goblins-interop", "releasing one occurrence lost the held capability");
	}
	session.release(second);
	const deadline = performance.now() + 5_000;
	while (await session.send(probe, "collected?", []) !== true) {
		if (performance.now() >= deadline) fail("deno-goblins-interop", "Goblins retained the released object");
		gc();
		await new Promise((resolve) => setTimeout(resolve, 0));
	}
	session.release(probe);
	console.log("deno-goblins-interop: Goblins reclaimed the released object with the session open");

	ok = true;
	console.log(
		"deno-goblins-interop OK: keyed handshake + enliven/dedup + echo deliver/resolve with live Goblins",
	);
	await session.close();
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
