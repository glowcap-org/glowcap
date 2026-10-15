import * as tcp from "@glowcap/tcp";
// Live three-party handoff with the Deno binding as the recipient (Carol),
// proving the binding redeems a `desc:handoff-give` transparently, the same
// `connect`/`fetch`/`send` application surface the demos use, no bespoke handoff
// choreography in the app.
//
// It spawns the conformance Goblins introducer host (Alice on PORT, Bob the
// exporter on PORT+1), learns Alice's introducer swiss-num from its NDJSON
// readiness line, then:
//   1. `connect` to Alice and `fetch` the introducer.
//   2. `send(introducer, "get-greeter")`. Alice hands back Bob's greeter as a
//      three-party handoff give. The binding's machine redeems it: it dials Bob
//      directly (keyed with the *same* identity Alice saw), withdraws the gift,
//      and resolves the send to an ordinary capability, the app never sees the
//      give or the second connection.
//   3. `send(greeter, "", ["glowcap-carol"])`. The bytes go straight to Bob;
//      the reply must carry the name back, proving data integrity end to end.
//
// Needs `racket` plus the `goblins` collection on PATH, so it runs as the
// sibling build step `zig build deno-goblins-handoff`.

import { Ref, Runtime } from "@glowcap/runtime";
import { fail, readSwiss } from "../_common/deno/helpers.ts";

const HOST = "127.0.0.1";
// Alice's port; Bob (the exporter) listens on PORT+1. `--port=N` (from
// `zig build deno-goblins-handoff -Dport=N`) moves the pair when 22112 is taken.
let PORT = 22112;
for (const a of Deno.args) {
	if (a.startsWith("--port=")) PORT = Number(a.slice("--port=".length));
	else fail("deno-goblins-handoff", `unknown argument '${a}'`);
}
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65534) {
	fail("deno-goblins-handoff", "--port must be an integer in 1..65534 (bob listens on port+1)");
}
const RACKET = "racket";
const HOST_SCRIPT = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";

const child = new Deno.Command(RACKET, {
	args: [HOST_SCRIPT, String(PORT), String(PORT + 1)],
	stdout: "piped",
	stderr: "piped",
}).spawn();

const stdoutReader = child.stdout.getReader();

let ok = false;
try {
	const swiss = await readSwiss(
		stdoutReader,
		"deno-goblins-handoff",
		"never saw the introducer readiness line",
	);
	console.log(
		`deno-goblins-handoff: alice published introducer swiss=${swiss} on ${HOST}:${PORT}`,
	);

	// `connect` completes the keyed handshake; the machine's retained identity is
	// the recipient key the gift Alice deposits will name.
	await using runtime = await Runtime.open({ providers: [tcp.provider()] });
	const session = await runtime.connect(tcp.locator(HOST, PORT));
	console.log("deno-goblins-handoff: session open (recipient -> alice)");
	session.serve().catch(() => {}); // tolerant: the partner hanging up ends the serve loop

	const introducer = await session.fetch(swiss);
	console.log(
		"deno-goblins-handoff: enlivened alice's introducer, asking for the greeter",
	);

	// The introduction: Alice returns Bob's greeter as a handoff give. The binding
	// redeems it transparently, so this resolves to an ordinary capability `Ref`.
	const greeter = await session.send(introducer, "get-greeter", []);
	if (!(greeter instanceof Ref)) {
		fail(
			"deno-goblins-handoff",
			`introduction did not redeem to a capability: ${JSON.stringify(greeter)}`,
		);
	}
	console.log(
		"deno-goblins-handoff: introduction redeemed, got the greeter as an ordinary ref",
	);

	// Call the greeter. The send routes straight to Bob (the exporter); the reply
	// must echo the name we sent, so the handoff proves data integrity, not just
	// choreography.
	const reply = await session.send(greeter, "", ["glowcap-carol"]);
	if (typeof reply !== "string" || !reply.includes("glowcap-carol")) {
		fail(
			"deno-goblins-handoff",
			`greeter reply did not carry the name back: ${JSON.stringify(reply)}`,
		);
	}
	console.log(`deno-goblins-handoff: greeter replied: ${reply}`);

	ok = true;
	console.log(
		"deno-goblins-handoff OK: the Deno binding redeemed a three-party handoff from live Goblins and called the exporter directly",
	);
	session.close();
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
