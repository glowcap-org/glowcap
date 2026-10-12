// A Host publication replies to its live caller over the arriving connection,
// with no dial-back: the receiver half of a fully bidirectional browser peer.
//
// A `Host.publish` object is bound to no single session: the same object
// answers calls on every connection, so it cannot close over one the way a
// `Session.spawn` actor does. `currentSession()` gives a Host publication the connection
// its current call arrived on, so it can send to a reply capability the caller
// handed it: the caller never has to be dialable.
//
//   Bob    publishes a Host publication `dm(text, reply)` and listens (TCP).
//   Alice  dials Bob, fetches `dm`, hands it a reply inbox she hosts on this
//          same connection, and sends one message.
//   Bob    reads `currentSession()` inside the Host publication, and answers Alice by
//          sending to her reply inbox over that connection.
//
// The reply reaches Alice though Alice never listens: it rides the connection
// she opened. This is the mechanism a browser peer (which cannot be dialed) uses
// to receive replies over any session it opened. Run by `zig build
// demo-rooms-dm-reply`.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-env apps/rooms/demos/dm_reply_demo.ts

import process from "node:process";

import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { DM } from "../lib/protocol.ts";
import { recordingReplyDm } from "../lib/dm_reply.ts";
import { DemoSessions, waitUntil } from "./dm_handoff.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";

const TEXT = "hi Bob, from Alice";
const REPLY = "re: hi Bob, from Alice";

function fail(message: string): never {
	console.error(`rooms-dm-reply demo FAILED: ${message}`);
	process.exit(1);
}

// Bob's inbox and how many connections he accepted, so we can assert the reply
// rode the one connection Alice opened rather than a fresh dial back to her.
const bobInbox: string[] = [];
let bobAccepts = 0;

// Bob's Host publication: record the message, then reply to the caller on the connection
// this call arrived on. The reply is a fresh eventual-send on a later turn (the
// host refuses a driving verb inside the callback frame), and `currentSession()`
// is captured synchronously because it is null once the turn returns, all owned
// by the shared `recordingReplyDm`.
const dmBehavior = recordingReplyDm(bobInbox, (text) => `re: ${text}`);

async function main(): Promise<void> {
	const services = new DemoSessions();
	const until = (ready: () => boolean, what: string) => waitUntil(ready, 10_000, what, () => services.check());
	const bobHost = roomsHost();
	bobHost.publish("dm", dmBehavior);
	const bob = await roomsListen("127.0.0.1", 0, bobHost);
	const bobLocator = loopbackTcpDesignator(bob.port);
	(async () => {
		for await (const session of bob) {
			bobAccepts += 1;
			services.serve(session);
		}
	})();

	// Alice dials Bob, fetches his `dm`, and hands it a reply inbox she hosts on
	// this same connection (a near export on her dialing session, so it rides the
	// call cleanly). Alice never listens.
	const aliceRuntime = await openRoomsRuntime();
	const alice = await dial(bobLocator, aliceRuntime);
	services.serve(alice);
	const bobDm = await alice.fetch("dm");

	const aliceReplies: string[] = [];
	const aliceInbox = alice.spawn((verb, args) => {
		if (verb === DM) aliceReplies.push(String(args[0]));
		return null;
	});

	await alice.send(bobDm, DM, [TEXT, aliceInbox]);
	await until(() => bobInbox.includes(TEXT), "Bob to receive Alice's message");
	await until(() => aliceReplies.includes(REPLY), "Bob's reply to reach Alice");

	if (bobAccepts !== 1) {
		fail(`expected Bob to accept exactly 1 connection (no dial-back), saw ${bobAccepts}`);
	}

	console.log("rooms-dm-reply demo OK:");
	console.log("  • a Host publication read its caller's connection via currentSession()");
	console.log(
		"  • it replied over that connection — Alice received it though she never listened",
	);
	console.log(
		"  • Bob accepted exactly one connection: no dial back to the non-listening caller",
	);

	alice.close();
	bob.close();
	await aliceRuntime.close();
	await services.settle();
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
