// The shared stand for the verb-spine proof family: start the fixed Deno peer
// (`fixture_peer.ts`), take a second copy of that peer's address and kill it so
// there is a dead one to dial, then run one binding's client with
// both locators appended to argv and require the client's marker line for every
// scene, in order.
//
// The family exists because the four bindings' promise, dial, listen, and GC
// modules were held together by quoted grep markers in
// `tools/check/source_check/binding_spine/verb_spines.zig`. A textual presence
// check cannot see whether a verb behaves, and one already escaped it: the
// `failed` arm of a send that could never be issued existed in Rust alone, so
// two bindings shipped a promise-returning `send` that raised synchronously and
// no caller's failure handler could see it. `promise-failed` below is that
// escape, written as behavior.
//
// A proof that passes on a healthy tree has shown nothing, so this one was run
// against two injected defects in the TypeScript binding before it landed.
// Making the failed arm rethrow instead of returning a handle turns
// `gc-released` red with the exact diagnostic, and pointing the `untag`
// projection at `op:get` turns `promise-untag` red. That second one arrives as
// a broken intermediate projection rather than a `FAIL:` line, because a chain
// link nobody awaits reports its break on its own.
//
// Run: deno run -A bindings/proofs/verb_spine/harness.ts -- <client argv...>
//
// ── The client contract ──────────────────────────────────────────────────────
//
// The harness appends two arguments to the client's argv:
//
//   1. <peerUri>  the fixed peer's `ocapn://` locator; it is live and answers.
//   2. <deadUri>  an `ocapn://` locator whose address nothing is listening on.
//
// The peer publishes one object under the swiss-number `spine`, and it answers:
//
//     greet  [who]  ->  the string "hello, <who>"
//     list   []     ->  the list ["alpha", "beta", "gamma"]
//     boxed  []     ->  the tagged record `cell` over ["cell-0", "cell-1"]
//     record []     ->  the struct {name: "spine-record", rank: "two"}
//     mint   []     ->  a fresh capability answering `ping` with "pong"
//
// The client prints one line per scene on stdout:
//
//     VERB-SPINE <marker>[ <free-form detail>]
//
// The harness reads the marker word and ignores any detail after it, so a
// client may print whatever diagnostic helps a red run. Every marker must
// appear exactly once, in this order, and the client must exit 0:
//
//   dial-ok         Connected to <peerUri> and fetched the published `spine`.
//   promise-handle  Sent `greet` with one string argument and got a *handle*
//                   back from the call itself, not a value and not a raised
//                   error; awaiting the handle yields `hello, <argument>`.
//   promise-index   Sent `list`, and *before awaiting* projected element 1 at
//                   the answer; the projection settles to "beta".
//   promise-untag   Sent `boxed`, and before awaiting projected the `cell`
//                   payload and then element 1 of it; that settles to "cell-1".
//   promise-get     Sent `record`, and before awaiting projected field `name`
//                   at the answer; the projection settles to "spine-record".
//   gc-released     Opted the session into distributed GC, sent `mint`, called
//                   `ping` on the returned capability for "pong", then released
//                   that capability deterministically. If the binding's API can
//                   still name a released capability, a second release and a
//                   send through it must both be refused; a binding whose
//                   release consumes the handle satisfies that by construction.
//   promise-failed  Closed the session, then sent any verb on a capability from
//                   it. The call must *return a handle*: a raised error here is
//                   the escape this family exists for. Awaiting that handle must
//                   report the failure.
//   listen-served   Opened the binding's own plain-TCP listener on 127.0.0.1
//                   port 0, dialed its advertised locator from this same
//                   process, called a published object over the accepted
//                   session, and closed the listener.
//   dial-refused    Dialed <deadUri> and got the binding's typed refusal. A
//                   hang, a panic, or a successful connect all fail the scene.
//   ok              Every scene above passed and the client is exiting.
//
// No other `VERB-SPINE ` line may appear. A client that cannot reach a scene
// exits nonzero with a diagnostic on stderr rather than printing a later
// marker.

import { awaitMarker, fail, ProofProcesses, runProofOrFail } from "../_support/harness.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const LIB_DIR = new URL("../../../zig-out/lib/", import.meta.url).pathname;
const installedArchiveEnv = {
	GLOWCAP_LIB_DIR: LIB_DIR,
	...(Deno.build.os === "darwin" ? { DYLD_LIBRARY_PATH: LIB_DIR } : { LD_LIBRARY_PATH: LIB_DIR }),
};

/** Every marker a client prints, in the order the harness requires them. */
const EXPECTED = [
	"dial-ok",
	"promise-handle",
	"promise-index",
	"promise-untag",
	"promise-get",
	"gc-released",
	"promise-failed",
	"listen-served",
	"dial-refused",
	"ok",
] as const;

const MARKER_PREFIX = "VERB-SPINE ";

const sep = Deno.args.indexOf("--");
const clientArgv = sep === -1 ? [...Deno.args] : Deno.args.slice(sep + 1);
if (clientArgv.length === 0) fail("harness needs a client argv after --");

const seen: string[] = [];
function spawnPeer(processes: ProofProcesses): Deno.ChildProcess {
	return processes.spawn("deno", {
		args: [
			"run",
			"-A",
			"--unstable-ffi",
			"bindings/proofs/verb_spine/fixture_peer.ts",
		],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
}

/** Bind a peer, take its advertised locator, and let the process exit so the
 * address is dialable-but-refused. Killing a real listener is what makes the
 * dead locator realistic: it was minted by the same runtime as the live one, and
 * its port is released by process exit rather than by guesswork. */
async function deadLocator(processes: ProofProcesses): Promise<string> {
	const doomed = spawnPeer(processes);
	const uri = await awaitMarker(doomed, "VERB-SPINE-PEER-READY", "doomed peer");
	await processes.stop(doomed);
	return uri;
}

/** Read the client's stdout to end of stream, echoing every line so a red run
 * carries the client's own diagnostics, and collect the marker words. */
async function collectMarkers(child: Deno.ChildProcess): Promise<void> {
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) break;
		buffered += value;
		let newline: number;
		while ((newline = buffered.indexOf("\n")) !== -1) {
			const line = buffered.slice(0, newline).trim();
			buffered = buffered.slice(newline + 1);
			if (line.length !== 0) console.log(`  [client] ${line}`);
			if (line.startsWith(MARKER_PREFIX)) {
				seen.push(line.slice(MARKER_PREFIX.length).trim().split(/\s+/)[0]);
			}
		}
	}
}

const clientCode = await runProofOrFail({
	deadlineMs: 25_000,
	timeoutMessage: () =>
		`verb-spine proof timed out after 25s; markers seen: ${seen.length === 0 ? "(none)" : seen.join(", ")}`,
}, async (processes) => {
	const peer = spawnPeer(processes);
	const peerUri = await awaitMarker(peer, "VERB-SPINE-PEER-READY", "peer");
	const dead = await deadLocator(processes);

	const client = processes.spawn(clientArgv[0], {
		args: [...clientArgv.slice(1), peerUri, dead],
		cwd: ROOT,
		env: installedArchiveEnv,
		stdout: "piped",
		stderr: "inherit",
	});
	await collectMarkers(client);
	return (await processes.status(client)).code;
});

if (clientCode !== 0) fail(`client exited ${clientCode}`);
for (const [index, marker] of EXPECTED.entries()) {
	if (seen[index] !== marker) {
		fail(
			`client marker ${index + 1} is ${
				seen[index] === undefined ? "missing" : JSON.stringify(seen[index])
			}, expected ${JSON.stringify(marker)}`,
		);
	}
}
if (seen.length !== EXPECTED.length) {
	fail(`client printed ${seen.length} markers, expected ${EXPECTED.length}`);
}
console.log("PASS: the client walked the whole verb spine");
Deno.exit(0);
