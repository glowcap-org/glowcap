// The three-party handoff choreography the rooms DM demos share.
//
// A rendezvous room introduces two members who then talk *directly*, with the
// room out of the message path — the headline of the direct-message story. It is
// the rooms-app face of `deno-gifter-handoff`: the same three-party handoff
// (ADR-0009), dressed in the rooms protocol (`register`/`introduce` on the
// directory, a member `dm` object) so the demo exercises the real server
// behaviour, not a bespoke one.
//
//   Room   (rendezvous / gifter)  serves the directory; on `register` it fetches
//                                 `dm` on the registrar session; `introduce`
//                                 hands that reference on as a gift.
//   Bob    (member / exporter)    one Host that listens and dials the room,
//                                 publishes `dm` on the room session, registers.
//   Carol  (member / recipient)   joins the room, asks it to introduce her to
//                                 Bob, transparently redeems the gift, and DMs
//                                 Bob over her own *direct* connection.
//
// Three proofs, all asserted:
//   1. Carol's DM reaches Bob's inbox (the introduction produced a live cap).
//   2. Bob accepts a brand-new inbound connection for the DM — Carol reached Bob
//      directly by the gift's locator, not through the room.
//   3. The room never carries the DM: register did not dial Bob; the DM text
//      travels solely on Carol-to-Bob.
//
// Only the transport differs between the demos (loopback TCP, iroh Direct with
// address hints, iroh Discovery by node id alone); each supplies a `DmTransport`
// and this runner drives the identical handoff and assertions over it.

import process from "node:process";
import { type Behavior, type Host, Ref, type Session } from "@pancake/stack";
import { serveDirectory } from "./deno/server.ts";
import { dial } from "./deno/lib/locator.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "./lib/protocol.ts";

/** A stream of inbound sessions: each value yielded is one accepted connection. Both
 * Bob's direct-dial accepts and the room's listener are this same shape. */
type SessionStream = AsyncIterable<Session>;

/** Bob's endpoint: the giftable Host (reused to dial the room so `register` can
 * fetch `dm` on the room session), the stream of inbound direct connections
 * (each accept is one direct dial), Bob's dialable locator, and a listener
 * close. */
interface BobEndpoint {
	host: Host;
	sessions: SessionStream;
	locator: string;
	close(): void;
}

/** The rendezvous room's listener (served as the directory) and its dialable
 * locator. */
interface RoomEndpoint {
	listener: SessionStream;
	locator: string;
	close(): void | Promise<void>;
}

/** One transport's flavour of the handoff: the wording, the deadline, and how to
 * stand Bob and the room up. Everything else — register, introduce, the three
 * assertions, the DM, teardown — is identical and lives in `runDmHandoff`. */
export interface DmTransport {
	/** Prefix for the demo's FAILED/OK console lines, e.g. `"rooms-dm"`. */
	label: string;
	/** The private line Carol sends Bob once introduced. */
	dmText: string;
	/** Deadline for each wait; iroh Discovery over the real internet needs a
	 * generous one. */
	timeoutMs: number;
	/** The three "OK" bullets, transport-specific wording. */
	bullets: readonly [string, string, string];
	/** Stand up Bob: publish `dm` giftably and listen for direct dials. */
	startBob(dm: Behavior): Promise<BobEndpoint>;
	/** Stand up the rendezvous room's listener and its dialable locator. */
	startRoom(): Promise<RoomEndpoint>;
}

/** Poll `ready` until true, throwing `what` past `timeoutMs` so a stuck endpoint
 * fails loud instead of hanging. Exported for a transport that must wait for its
 * own endpoint to become dialable (iroh's direct addresses). */
export async function waitUntil(
	ready: () => boolean,
	timeoutMs: number,
	what: string,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!ready()) {
		if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 10));
	}
}

/** Drive the whole three-party handoff over `t`'s transport and assert the three
 * proofs, exiting 0 on success and 1 (with a `${label} demo FAILED:` line) on any
 * failure. */
export async function runDmHandoff(t: DmTransport): Promise<void> {
	// A function declaration, not an arrow: TypeScript propagates its `never`
	// return into control-flow narrowing (the `instanceof Ref` guard below).
	function fail(message: string): never {
		console.error(`${t.label} demo FAILED: ${message}`);
		process.exit(1);
	}
	const until = (ready: () => boolean, what: string) => waitUntil(ready, t.timeoutMs, what);

	// Bob's received DMs, and how many direct connections he has accepted. The
	// count is read through `inboundCount()` so a `!== 0` guard cannot
	// false-narrow the later `!== 1` assertion to a literal (the mutation lives in
	// the accept loop, which TypeScript's flow analysis cannot see across).
	const bobInbox: string[] = [];
	let inbound = 0;
	const inboundCount = () => inbound;
	const dmBehavior: Behavior = (verb, args) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		bobInbox.push(String(args[1]));
		return null;
	};

	try {
		const bob = await t.startBob(dmBehavior);
		const bobAccept = (async () => {
			for await (const session of bob.sessions) {
				inbound += 1;
				session.serve().catch(() => {});
			}
		})();

		const room = await t.startRoom();
		const roomServe = serveDirectory(room.listener);

		// Bob dials the room on his own Host, publishes `dm`, and registers his
		// dialable locator so `introduce` can hand it on as a gift.
		const bobToRoom = await dial(room.locator, bob.host);
		bobToRoom.serve().catch(() => {});
		bobToRoom.publish("dm", dmBehavior);
		const bobDir = await bobToRoom.fetch(DIRECTORY);
		let registered = false;
		const regInbox = bobToRoom.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") registered = true;
			return null;
		});
		await bobToRoom.send(bobDir, REGISTER, ["bob", bob.locator, regInbox]);
		await until(() => registered, "the room to register Bob");

		if (inboundCount() !== 0) {
			fail(
				`expected 0 inbound connections after register (no dial-back), saw ${inboundCount()}`,
			);
		}

		// Carol joins, asks the room to introduce her to Bob, and redeems the gift
		// transparently — her send lands on a fresh direct connection to Bob.
		const carol = await dial(room.locator);
		carol.serve().catch(() => {});
		const carolDir = await carol.fetch(DIRECTORY);
		const introduced = await carol.send(carolDir, INTRODUCE, ["bob"]);
		if (!(introduced instanceof Ref)) fail("introduce did not return a capability");

		await until(() => inboundCount() >= 1, "Carol's direct connection to Bob");
		if (inboundCount() !== 1) {
			fail(
				`expected Carol's redeem to add exactly one direct connection, Bob saw ${inboundCount()}`,
			);
		}

		await carol.send(introduced, DM, ["Carol", t.dmText]);
		await until(() => bobInbox.includes(t.dmText), "Bob to receive Carol's direct DM");

		console.log(`${t.label} demo OK:`);
		for (const bullet of t.bullets) console.log(`  • ${bullet}`);

		carol.close();
		bobToRoom.close();
		await room.close();
		bob.close();
		await Promise.allSettled([bobAccept, roomServe]);
		process.exit(0);
	} catch (err) {
		fail(err instanceof Error ? (err.stack ?? err.message) : String(err));
	}
}
