// Live three-party handoff with the Deno binding as the GIFTER (the introducer),
// proving glowcap can mint a `desc:handoff-give` that live Goblins redeems and a
// `deposit-gift` that live Goblins accepts, the exporter half of ADR-0039
// against a real cross-implementation peer, the mirror of `deno-goblins-handoff`
// (where glowcap is the recipient).
//
// Topology (all TCP loopback):
//   Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
//   Gifter (glowcap)           lifts Bob's greeter from a vendor reply, then
//                              publishes an "introducer" that returns it twice
//                              in one nested Passable value, and listens.
//   Carol  (Goblins recipient) dials the glowcap introducer, asks for the
//                              greeters, transparently redeems both gives, and
//                              calls both directly on Bob.
//
// glowcap is the gifter: when Carol asks for the greeters, glowcap deposits both
// occurrences with Bob and resolves Carol's send with two signed gives. Goblins
// must redeem both and reach Bob directly; Carol's `GIFT NESTED OK` line carries
// both replies and the distinct names she sent.
//
// Needs `deno` + `racket` + the `goblins` collection on PATH, so it runs as the
// sibling build step `zig build deno-goblins-gift`.

import { Ref, Runtime } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import { acceptLoop, awaitGreeterReady, fail, parsePort } from "../_common/deno/helpers.ts";

const HOST = "127.0.0.1";
// Bob (the Goblins exporter) listens on PORT; Carol binds her own peer on PORT+1.
// glowcap (the gifter) takes an ephemeral port, the recipient learns it at spawn
// time. `--port=N` (from `zig build deno-goblins-gift -Dport=N`) moves the pair.
const PORT = parsePort("deno-goblins-gift", 22120, 65534);
const RACKET = "racket";
const EXPORTER_SCRIPT = "conformance/goblins-peer/racket/gift-exporter-host.rkt";
const RECIPIENT_SCRIPT = "conformance/goblins-peer/racket/gift-recipient.rkt";
// glowcap hardcodes the same swiss the exporter host registers, the way the
// interop clients fix the echo swiss.
const GREETER_SWISS = "glowcapGiftGreeterSwissnum000001";
const VENDOR_SWISS = "glowcapGiftVendorSwissnum0000001";
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
})().catch(() => {}); // tolerant: the capture ends when the child's pipe closes, and the text is only printed on a failure that has its own cause.

let ok = false;
let carol: Deno.ChildProcess | null = null;
try {
	await awaitGreeterReady(bobStdout, "deno-goblins-gift");
	console.log(
		`deno-goblins-gift: goblins-bob exporting greeter swiss=${GREETER_SWISS} on ${HOST}:${PORT}`,
	);

	// glowcap (the gifter) listens for the recipient on an ephemeral port and runs
	// its accept loop. One node identity serves both the recipient connection and
	// the exporter connection, so the give's signature matches the deposit.
	const gifter = await tcp.listen(HOST, 0);
	const runtime = await Runtime.open({ providers: [tcp.provider()], adoptHost: gifter.host });
	const gifterAccept = acceptLoop(gifter);
	const gifterPort = gifter.port;

	// Fetch a vendor, then lift Bob's greeter from an ordinary call reply. That
	// reply ref's home is the gifter↔Bob connection, so glowcap can re-gift
	// it across to the recipient without an enrollment verb.
	const toBob = await runtime.connect(tcp.locator(HOST, PORT));
	// tolerant: serve rejects when Bob hangs up, which ends this session normally, and the script's own calls report real failures.
	toBob.serve().catch(() => {});
	const vendor = await toBob.fetch(VENDOR_SWISS);
	const greeter = await toBob.send(vendor, null, []);
	if (!(greeter instanceof Ref)) giftFail("the vendor reply was not a capability");
	console.log("deno-goblins-gift: lifted goblins-bob's greeter from a reply");

	// Publish the introducer host-wide. Two recursively placed occurrences of
	// Bob's greeter force the binding's complete Value lowering path and the
	// core's one-message/two-give transaction; neither is a top-level shortcut.
	gifter.host.publish(
		INTRODUCER_SWISS,
		(verb) => (verb === "get-greeter" ? [greeter, [greeter]] : null),
	);
	console.log(
		`deno-goblins-gift: glowcap publishing introducer swiss=${INTRODUCER_SWISS} on ${HOST}:${gifterPort}`,
	);

	// Spawn Carol (the Goblins recipient): she dials glowcap's introducer, asks
	// for both greeters, redeems both gives, and calls Bob directly.
	carol = new Deno.Command(RACKET, {
		args: [
			RECIPIENT_SCRIPT,
			tcp.addressDesignator(HOST, gifterPort),
			INTRODUCER_SWISS,
			String(PORT + 1),
			`nested=${tcp.addressDesignator(HOST, PORT)}`,
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
	if (
		!reply.startsWith("GIFT NESTED OK:") ||
		!reply.includes("goblins-carol-one") ||
		!reply.includes("goblins-carol-two")
	) {
		giftFail(
			`recipient did not confirm the greeter reply with its name: ${JSON.stringify(reply)}`,
		);
	}

	ok = true;
	console.log(
		"deno-goblins-gift OK: two nested binding values became distinct gives that live Goblins redeemed and called directly",
	);

	await gifter.close();
	await toBob.close();
	await runtime.close();
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
