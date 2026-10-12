// The Deno half of the verb-spine proof family: one process that walks the
// promise, dial, listen, and GC verbs against the fixed peer and prints one
// `VERB-SPINE <marker>` line per scene. `harness.ts` owns the marker contract
// and the two locators appended to argv; read its header before porting this
// client to another binding.
//
// Run via `zig build deno-verb-spine`.

import { parseLocator, type Ref, Runtime, type Session } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function mark(marker: string, detail = ""): void {
	console.log(`VERB-SPINE ${marker}${detail === "" ? "" : ` ${detail}`}`);
}

function expectString(what: string, actual: unknown, wanted: string): void {
	if (actual === wanted) return;
	fail(`${what}: expected ${JSON.stringify(wanted)}, got ${JSON.stringify(actual)}`);
}

/** Whether a handle settled with a value. Every call site here expects a
 * reported failure, so the failure is consumed rather than escaping as an
 * unhandled rejection. */
async function settles(handle: PromiseLike<unknown>): Promise<boolean> {
	try {
		await handle;
		return true;
	} catch {
		return false;
	}
}

/** Send, and require that the call itself hands back a handle. A binding that
 * raises here has put a synchronous failure channel on a promise-returning
 * verb, which is the trap this family exists to catch. */
function sendHandle(
	from: Session,
	target: Ref,
	verb: string,
	args: string[],
	what: string,
): PromiseLike<unknown> {
	let handle: PromiseLike<unknown>;
	try {
		handle = from.send(target, verb, args);
	} catch (raised) {
		fail(`${what}: send raised instead of returning a handle: ${raised}`);
	}
	if (typeof (handle as { then?: unknown }).then !== "function") {
		fail(`${what}: send did not return an awaitable handle`);
	}
	return handle;
}

/** Publish `echo` on the first session this listener accepts, and serve it. */
async function serveOnce(listener: tcp.Server): Promise<void> {
	for await (const accepted of listener) {
		const served: Session = accepted;
		served.publish("echo", (verb, args) => {
			if (verb !== "echo") throw new Error(`echo has no verb ${verb}`);
			return typeof args[0] === "string" ? args[0] : "?";
		});
		served.serve();
		return;
	}
}

if (Deno.args.length < 2) fail("usage: deno_client.ts <peerUri> <deadUri>");
const [peerUri, deadUri] = Deno.args.slice(-2);

await using runtime = await Runtime.open({ providers: [tcp.provider()] });

// ── dial-ok ─────────────────────────────────────────────────────────────────
const session = await runtime.connect(parseLocator(peerUri));
session.withGc();
const spine = await session.fetch("spine");
mark("dial-ok", peerUri);

// ── promise-handle ──────────────────────────────────────────────────────────
expectString("greet", await sendHandle(session, spine, "greet", ["spine"], "greet"), "hello, spine");
mark("promise-handle");

// ── promise-index / promise-untag / promise-get ─────────────────────────────
// Each projection is issued at the unsettled answer, before anything awaits it:
// that is what makes a dependent read one round trip rather than two.
const listing = session.send(spine, "list", []);
const secondElement = listing.index(1);
expectString("list index 1", await secondElement, "beta");
mark("promise-index");

const boxed = session.send(spine, "boxed", []);
const cellTail = boxed.untag("cell").index(1);
expectString("boxed untag then index 1", await cellTail, "cell-1");
mark("promise-untag");

const record = session.send(spine, "record", []);
const recordName = record.get("name");
expectString("record field name", await recordName, "spine-record");
mark("promise-get");

// ── gc-released ─────────────────────────────────────────────────────────────
const minted = await session.send(spine, "mint", []) as Ref;
expectString("minted ping", await session.send(minted, "ping", []), "pong");
session.release(minted);
let secondReleaseAccepted = false;
try {
	session.release(minted);
	secondReleaseAccepted = true;
} catch { /* the refusal this scene requires */ }
if (secondReleaseAccepted) fail("releasing a spent capability twice was accepted");
const throughSpent = sendHandle(session, minted, "ping", [], "send through a released capability");
if (await settles(throughSpent)) fail("a send through a released capability was answered");
mark("gc-released");

// ── promise-failed ──────────────────────────────────────────────────────────
// The documented escape, as behavior: a send that could never be issued comes
// back as a settled failure, never as a raised error at the call.
await session.close();
const ghost = sendHandle(session, spine, "greet", ["ghost"], "send on a closed session");
if (await settles(ghost)) fail("a send on a closed session was answered");
mark("promise-failed");

// ── listen-served ───────────────────────────────────────────────────────────
const server = await tcp.listen("127.0.0.1", 0);
// A closed listener has no locator to read, so name it while it lives.
const ownUri = server.uri;
const serving = serveOnce(server);
const own = await runtime.connect(server.locator);
const echo = await own.fetch("echo");
expectString("own listener echo", await own.send(echo, "echo", ["heard"]), "heard");
await own.close();
await serving;
await server.close();
mark("listen-served", ownUri);

// ── dial-refused ────────────────────────────────────────────────────────────
let stray: Session | null = null;
try {
	stray = await runtime.connect(parseLocator(deadUri));
} catch (refusal) {
	mark("dial-refused", String(refusal));
}
if (stray !== null) {
	await stray.close();
	fail(`dialing ${deadUri} opened a session; nothing is listening there`);
}

mark("ok");
