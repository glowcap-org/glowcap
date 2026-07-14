// Live three-party handoff with the Deno binding as the GIFTER (the introducer),
// proving pancake can mint a `desc:handoff-give` that live Goblins redeems and a
// `deposit-gift` that live Goblins accepts, the exporter half of ADR-0009
// against a real cross-implementation peer, the mirror of `deno-goblins-handoff`
// (where pancake is the recipient).
//
// Topology (all TCP loopback):
//   Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
//   Gifter (pancake)           fetches Bob's greeter, publishes an "introducer"
//                              that returns it, and listens for the recipient.
//   Carol  (Goblins recipient) dials the pancake introducer, asks for the
//                              greeter, transparently redeems pancake's give, and
//                              calls the greeter directly on Bob.
//
// pancake is the gifter: when Carol asks for the greeter, pancake deposits it
// back with Bob over its own Bob connection and resolves Carol's send with a
// signed give. Goblins Bob must accept pancake's deposit; Goblins Carol must
// redeem pancake's give and reach Bob directly. The proof is Carol's `GIFT OK`
// line carrying the greeter's reply with the name she sent.
//
// Needs `deno` + `racket` + the `goblins` collection on PATH, so it runs as the
// sibling build step `zig build deno-goblins-gift`.

import { connect, listen, type Ref, socketAddrDesignator, tcpLocator } from "@pancake/stack";
import { acceptLoop, fail, parsePort } from "../_common/deno/helpers.ts";

const HOST = "127.0.0.1";
// Bob (the Goblins exporter) listens on PORT; Carol binds her own peer on PORT+1.
// pancake (the gifter) takes an ephemeral port, the recipient learns it at spawn
// time. `--port=N` (from `zig build deno-goblins-gift -Dport=N`) moves the pair.
const PORT = parsePort("deno-goblins-gift", 22120, 65534);
const RACKET = "/usr/local/bin/racket";
const EXPORTER_SCRIPT = "conformance/goblins-peer/racket/gift-exporter-host.rkt";
const RECIPIENT_SCRIPT = "conformance/goblins-peer/racket/gift-recipient.rkt";
// pancake hardcodes the same swiss the exporter host registers, the way the
// interop clients fix the echo swiss.
const GREETER_SWISS = "pancakeGiftGreeterSwissnum000001";
const INTRODUCER_SWISS = "introducer";

const children: Deno.ChildProcess[] = [];
function killChildren(): void {
	for (const c of children) {
		try {
			c.kill();
		} catch { /* already gone */ }
	}
}

function giftFail(msg: string): never {
	killChildren();
	fail("deno-goblins-gift", msg);
}

// Spawn Bob (the Goblins exporter) and wait for its readiness NDJSON.
const bob = new Deno.Command(RACKET, {
	args: [EXPORTER_SCRIPT, HOST, String(PORT)],
	stdout: "piped",
	stderr: "piped",
}).spawn();
children.push(bob);
const bobStdout = bob.stdout.getReader();

// Drain Bob's stderr in the background into a buffer. A piped child stream that
// is never read deadlocks the child once its OS pipe fills, Goblins logs to
// stderr during operation, so leaving it undrained stalls the deposit and the
// whole handoff times out. The captured text is printed only on failure.
const bobStderrChunks: Uint8Array[] = [];
const bobStderrDrain = (async () => {
	for await (const chunk of bob.stderr) bobStderrChunks.push(chunk);
})().catch(() => {});

async function awaitBobReady(): Promise<void> {
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await bobStdout.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		if (buf.includes('"name":"greeter"')) return;
	}
	giftFail("never saw the exporter's greeter readiness line");
}

let ok = false;
let carol: Deno.ChildProcess | null = null;
try {
	await awaitBobReady();
	console.log(
		`deno-goblins-gift: goblins-bob exporting greeter swiss=${GREETER_SWISS} on ${HOST}:${PORT}`,
	);

	// pancake (the gifter) listens for the recipient on an ephemeral port and runs
	// its accept loop. One node identity serves both the recipient connection and
	// the exporter connection, so the give's signature matches the deposit.
	const gifter = listen(HOST, 0);
	const gifterAccept = acceptLoop(gifter);
	const gifterPort = await gifter.ready();

	// Dial Bob and fetch his greeter. The fetched ref's home is this gifter↔Bob
	// connection, which is what lets pancake re-gift it across to the recipient.
	const toBob = await connect(tcpLocator(HOST, PORT), undefined, gifter.host);
	toBob.serve().catch(() => {});
	const greeter = await toBob.fetch(GREETER_SWISS);
	console.log("deno-goblins-gift: fetched goblins-bob's greeter");

	// Publish the introducer host-wide. Returning Bob's greeter (home = the Bob
	// connection) to the recipient's connection trips the transparent gifter,
	// which deposits with Bob and resolves the recipient with a signed give.
	gifter.host.publishGiftable(
		INTRODUCER_SWISS,
		(verb) => (verb === "get-greeter" ? greeter : null),
	);
	console.log(
		`deno-goblins-gift: pancake publishing introducer swiss=${INTRODUCER_SWISS} on ${HOST}:${gifterPort}`,
	);

	// Spawn Carol (the Goblins recipient): she dials pancake's introducer, asks
	// for the greeter, redeems pancake's give, and calls Bob directly.
	carol = new Deno.Command(RACKET, {
		args: [
			RECIPIENT_SCRIPT,
			socketAddrDesignator(HOST, gifterPort),
			INTRODUCER_SWISS,
			String(PORT + 1),
		],
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	children.push(carol);

	const carolOut = await carol.output();
	const reply = new TextDecoder().decode(carolOut.stdout).trim();
	const carolErr = new TextDecoder().decode(carolOut.stderr).trim();
	if (reply) console.log(`deno-goblins-gift: ${reply}`);
	if (!carolOut.success) {
		giftFail(
			`recipient exited non-zero${carolErr ? `; stderr:\n${carolErr}` : ""}`,
		);
	}
	if (!reply.startsWith("GIFT OK:") || !reply.includes("goblins-carol")) {
		giftFail(
			`recipient did not confirm the greeter reply with its name: ${JSON.stringify(reply)}`,
		);
	}

	ok = true;
	console.log(
		"deno-goblins-gift OK: pancake minted a three-party handoff give that live Goblins redeemed, reaching the exporter directly",
	);

	gifter.close();
	toBob.close();
	await Promise.allSettled([gifterAccept]);
} finally {
	try {
		bob.kill();
	} catch { /* already gone */ }
	await bob.status;
	try {
		await bobStdout.cancel();
	} catch { /* already released */ }
	await bobStderrDrain;
	if (!ok) {
		const err = new TextDecoder().decode(
			bobStderrChunks.reduce((acc, c) => {
				const out = new Uint8Array(acc.length + c.length);
				out.set(acc);
				out.set(c, acc.length);
				return out;
			}, new Uint8Array()),
		).trim();
		if (err) console.error(`deno-goblins-gift: exporter stderr:\n${err}`);
	}
	if (carol) {
		try {
			carol.kill();
		} catch { /* already exited */ }
		try {
			await carol.status;
		} catch { /* already reaped */ }
	}
}

if (!ok) Deno.exit(1);
