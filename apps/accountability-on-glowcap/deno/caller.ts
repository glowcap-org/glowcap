import * as tcp from "@glowcap/tcp";
// Deno caller for the accountability-on-glowcap cross-seam demo.
//
// Connects to a running Zig host, builds a KERI-anchored identity with a real
// key event log (`identity.ts`), rotates it once, then invokes the Affordance
// capability: it signs the attestation preimage `invoke|<subject>|<request>` and
// hands over the log that binds its signing key to the AID it claims. Three
// paths are exercised, because all three are the contract:
//
//   * a legitimate invocation, which the host attests, binds, and acks;
//   * a corrupted signature, which the host cannot attest;
//   * a key the log has already rotated away from, which the host can attest but
//     will not bind to the claimed AID.
//
// Usage:
//   deno run --allow-ffi --allow-read --allow-net caller.ts <port>
//
// Or driven by the demo.ts orchestrator, which starts the Zig host first.

import { type Argument, Runtime } from "@glowcap/runtime";
import { b64url, Identity } from "./identity.ts";

function fail(msg: string): never {
	console.error(`FAIL: ${msg}`);
	Deno.exit(1);
}

async function main(): Promise<void> {
	const port = Number(Deno.args[0]);
	if (!port) {
		console.error("usage: caller.ts <port>");
		Deno.exit(2);
	}

	console.log("accountability-on-glowcap deno caller");
	console.log(`  connecting to 127.0.0.1:${port}…`);

	// `connect` completes the keyed op:start-session handshake before returning.
	await using runtime = await Runtime.open({ providers: [tcp.provider()] });
	const session = await runtime.connect(tcp.locator("127.0.0.1", port));
	// `fetch`/`send` drive the inbound loop themselves, no separate serve() call.
	const affordance = await session.fetch("affordance");

	// Incept an identity above glowcap, just like the Zig side, then rotate it
	// once so the log the host reads is a chain and not a lone inception event.
	const caller = await Identity.incept();
	await caller.rotate();
	const retired = caller.retired ?? fail("rotation left no retired key");

	console.log(`  subject (AID): ${caller.aid}`);

	// --- Legitimate invocation -------------------------------------------------
	const request = "read-thermostat";
	// The subject is in the signed bytes so the host can tell that this caller
	// really is claiming this AID, and not borrowing somebody else's. The log
	// rides alongside so the host can check that this key speaks for that AID.
	const preimage = `invoke|${caller.aid}|${request}`;
	const sigRaw = await caller.current.sign(preimage);

	console.log("  sending legitimate invoke…");
	let result: Argument;
	try {
		result = await session.send(affordance, "invoke", [
			caller.aid,
			caller.current.verkey,
			request,
			b64url(sigRaw),
			caller.kel,
		]);
	} catch (err) {
		fail(
			`legitimate invoke broke: ${err instanceof Error ? err.message : err}`,
		);
	}

	if (typeof result! !== "string" || !result!.startsWith("ack:")) {
		fail(`unexpected result: ${result!}`);
	}
	console.log(`  result: ${result!}`);

	// --- Tampered signature (should be refused) --------------------------------
	console.log("  sending tampered invoke (should be refused)…");
	const badSig = new Uint8Array(sigRaw);
	badSig[0] ^= 0xff;

	const tampered = await refusal(() =>
		session.send(affordance, "invoke", [
			caller.aid,
			caller.current.verkey,
			request,
			b64url(badSig),
			caller.kel,
		])
	);
	if (!tampered) fail("tampered invoke was NOT refused");
	console.log(`  correctly refused: ${tampered}`);

	// --- Retired key (should be refused) ---------------------------------------
	// This signature is genuine: the caller really held this key, and it really
	// signed this subject and request. What fails is the binding, because the log
	// the caller hands over rotated past that key.
	console.log("  sending invoke signed by a retired key (should be refused)…");
	const staleSig = b64url(await retired.sign(preimage));
	const stale = await refusal(() =>
		session.send(affordance, "invoke", [
			caller.aid,
			retired.verkey,
			request,
			staleSig,
			caller.kel,
		])
	);
	if (!stale) fail("a retired pre-rotation key was NOT refused");
	console.log(`  correctly refused: ${stale}`);

	session.close();
	console.log(
		"\naccountability-on-glowcap deno caller OK: same application, two languages.",
	);
}

/** Run an invocation expecting a broken promise. The reason, or null if it settled. */
async function refusal(send: () => Promise<unknown>): Promise<string | null> {
	try {
		await send();
		return null;
	} catch (err) {
		return err instanceof Error ? err.message : String(err);
	}
}

await main();
