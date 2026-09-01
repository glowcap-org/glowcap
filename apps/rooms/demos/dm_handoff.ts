// The three-party handoff choreography the rooms DM demos share.
//
// A rendezvous room introduces two members who then talk *directly*, with the
// room out of the message path — the headline of the direct-message story. It is
// the rooms-app face of `deno-gifter-handoff`: the same three-party handoff
// (ADR-0009), dressed in the rooms protocol (`register`/`introduce` on the
// directory, a member `dm` object) so the demo exercises the real server
// behaviour, not a bespoke one.
//
//   Room   (rendezvous / gifter)  serves the directory; `introduce` hands on the
//                                 inbox the member offered for that caller, as a
//                                 gift.
//   Bob    (member / exporter)    one Host that listens and dials the room,
//                                 registers, and mints one inbox per peer the
//                                 directory asks him for.
//   Carol  (member / recipient)   registers too — the name the room grants her is
//                                 what Bob's inbox is minted for — then asks to be
//                                 introduced to Bob, redeems the gift, and DMs him
//                                 over her own *direct* connection.
//
// Four proofs, all asserted:
//   1. Carol's first `introduce` is refused `introduction-pending`, because Bob
//      has not offered an inbox for her yet, and the retry after his offer works.
//   2. Carol's DM arrives on the inbox Bob minted for Carol, so Bob knows who
//      sent it without the message naming anyone.
//   3. Bob accepts a brand-new inbound connection for the DM — Carol reached Bob
//      directly by the gift's locator, not through the room.
//   4. Nobody dials Carol, so the DM travelled solely on Carol-to-Bob and the
//      room carried none of it.
//
// Only the transport differs between the demos (loopback TCP, iroh Direct with
// address hints, iroh Discovery by node id alone); each supplies a `DmTransport`
// and this runner drives the identical handoff and assertions over it.

import process from "node:process";
import { Ref } from "@pancake/runtime";
import type { Behavior, Host, Session } from "@pancake/runtime";
import { RoomServer } from "../server/room_server.ts";
import { dial } from "../lib/locator.ts";
import { DIRECTORY, DM, INTRODUCE, NOTIFY, REGISTER } from "../lib/protocol.ts";
import { INTRODUCTION_PENDING, roomErrorOf } from "../lib/errors.ts";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { Directory } from "../lib/room/client.ts";
import type { RoomsRuntime } from "../lib/locator.ts";

/** A stream of inbound sessions: each value yielded is one accepted connection. Both
 * Bob's direct-dial accepts and the room's listener are this same shape. */
type SessionStream = AsyncIterable<Session>;

/** One member's endpoint: the Host its inboxes are published on (reused to dial
 * the room), the stream of inbound direct connections (each accept is one direct
 * dial), its dialable locator, and a listener close. */
interface MemberEndpoint {
	host: Host;
	runtime: RoomsRuntime;
	sessions: SessionStream;
	locator: string;
	close(): void | Promise<void>;
}

/** The rendezvous room's listener (served as the directory) and its dialable
 * locator. */
interface RoomEndpoint {
	/** The Host the room's directory is published on. The directory belongs to
	 * the Host rather than to any one accepted session, so it has to be reachable
	 * before the first dial rather than published as each arrives. */
	host: Host;
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
	/** The "OK" bullets, transport-specific wording. */
	bullets: readonly string[];
	/** Stand up one member: a Host that listens for direct dials. Called once for
	 * Bob and once for Carol — both register, because a name the room granted is
	 * what an inbox is minted for. Awaited by the caller, so a transport whose
	 * setup is synchronous returns the endpoint directly rather than wrapping it
	 * in an idle promise. */
	startMember(who: string): MemberEndpoint | Promise<MemberEndpoint>;
	/** Stand up the rendezvous room's listener and its dialable locator. Awaited
	 * like `startBob`, and synchronous for the same reason. */
	startRoom(): RoomEndpoint | Promise<RoomEndpoint>;
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

	// Every DM Bob received, with the peer whose inbox it arrived on. The name is
	// never read off the message: `dmFor` closes over the peer the inbox was minted
	// for, so a spoofed name cannot reach the wrong thread.
	const bobInbox: { from: string; text: string }[] = [];
	// How many direct connections each member has accepted. Read through a function
	// so a `!== 0` guard cannot false-narrow a later `!== 1` assertion to a literal
	// (the mutation lives in an accept loop TypeScript's flow analysis cannot see).
	let bobInbound = 0;
	let carolInbound = 0;
	const bobInboundCount = () => bobInbound;
	const carolInboundCount = () => carolInbound;
	const dmFor = (peer: string): Behavior => (verb, args) => {
		if (verb !== DM) throw new Error(`dm has no method ${verb}`);
		bobInbox.push({ from: peer, text: String(args[0]) });
		return null;
	};
	const received = (from: string, text: string) => bobInbox.some((m) => m.from === from && m.text === text);

	try {
		const bob = await t.startMember("bob");
		const carol = await t.startMember("carol");
		const bobAccept = (async () => {
			for await (const session of bob.sessions) {
				bobInbound += 1;
				session.serve().catch(() => {});
			}
		})();
		const carolAccept = (async () => {
			for await (const session of carol.sessions) {
				carolInbound += 1;
				session.serve().catch(() => {});
			}
		})();

		const room = await t.startRoom();
		const server = new RoomServer();
		const roomServe = server.serve(room.host, room.listener);

		// Bob dials the room on his own Host and registers his dialable locator, so
		// `introduce` can hand an inbox of his on as a gift. The shared inbox publisher
		// answers the directory's requests for one, which is the same code the
		// browser peer runs.
		const bobDirectory = await Directory.connect(
			room.locator,
			(locator) => dial(locator, bob.runtime),
		);
		let asked: string | null = null;
		const bobOfferer = inboxPublisher(bob.host).offerer({
			dir: () => bobDirectory,
			behaviorFor: dmFor,
			onError: (peer, err) => fail(`Bob could not offer an inbox for ${peer}: ${err}`),
		});
		const bobRegistrationId = await bobDirectory.register("bob", bob.locator, (peer, registrationId) => {
			asked = peer;
			bobOfferer.offer(peer, registrationId);
		});

		if (bobInboundCount() !== 0) {
			fail(
				`expected 0 inbound connections after register (no dial-back), saw ${bobInboundCount()}`,
			);
		}

		// Carol registers too: the room grants her the name Bob's inbox is minted
		// for, and it is the name the directory reads off her connection rather than
		// anything she says in a message.
		const carolToRoom = await dial(room.locator, carol.runtime);
		carolToRoom.serve().catch(() => {});
		const carolDir = await carolToRoom.fetch(DIRECTORY);
		let carolRegistered = false;
		let introducible = false;
		const carolReg = carolToRoom.spawn((verb, args) => {
			if (verb !== NOTIFY) return null;
			if (args[0] === "registered") carolRegistered = true;
			if (args[0] === "introducible" && args[1] === "bob") introducible = true;
			return null;
		});
		await carolToRoom.send(carolDir, REGISTER, ["carol", carol.locator, carolReg]);
		await until(() => carolRegistered, "the room to register Carol");

		// First contact: Bob has offered no inbox for Carol, so the directory asks
		// him for one and refuses this ask. One extra round trip, once per pair.
		let pending = false;
		try {
			await carolToRoom.send(carolDir, INTRODUCE, ["bob", bobRegistrationId]);
		} catch (err) {
			pending = roomErrorOf(err)?.code === INTRODUCTION_PENDING;
			if (!pending) throw err;
		}
		if (!pending) fail("expected the first introduce to be refused introduction-pending");
		await until(() => introducible, "Bob to offer the room an inbox for Carol");
		if (asked !== "carol") {
			fail(`expected Bob to be asked for an inbox for carol, got ${asked}`);
		}

		// Now it lands: the directory hands Carol the inbox Bob minted for her, as a
		// gift, and her send redeems it onto a fresh direct connection to Bob.
		const direct = await carolToRoom.send(carolDir, INTRODUCE, ["bob", bobRegistrationId]);
		if (!(direct instanceof Ref)) fail("introduce did not return a capability");

		await until(() => bobInboundCount() >= 1, "Carol's direct connection to Bob");
		if (bobInboundCount() !== 1) {
			fail(
				`expected Carol's redeem to add exactly one direct connection, Bob saw ${bobInboundCount()}`,
			);
		}

		await carolToRoom.send(direct, DM, [t.dmText]);
		await until(() => received("carol", t.dmText), "Bob to receive Carol's direct DM");
		if (carolInboundCount() !== 0) {
			fail(`expected nobody to dial Carol, she saw ${carolInboundCount()}`);
		}

		console.log(`${t.label} demo OK:`);
		for (const bullet of t.bullets) console.log(`  • ${bullet}`);

		await carolToRoom.close();
		await bobDirectory.close();
		await room.close();
		await bob.close();
		await carol.close();
		await Promise.allSettled([bobAccept, carolAccept, roomServe]);
		await server.close();
		process.exit(0);
	} catch (err) {
		fail(err instanceof Error ? (err.stack ?? err.message) : String(err));
	}
}
