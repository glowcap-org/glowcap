// Redeem attribution is deterministic: `Session.sendRedeeming` resolves the
// direct exporter session from the reply's own route, not by watching which
// dial the host happened to run during the send. This pins the property the
// route-based resolution guarantees and a capture-window heuristic could not
// (ADR-0088).
//
// The sharp case is a *second* redeem to an exporter already dialed. The first
// introduction dials Bob and resolves to that connection. The second reuses it —
// the node dedups the dial by exporter identity, so no new dial runs at all. A
// heuristic that captured "the exporter dialed during this send" would see none
// and surface `via = null`, and the sender would wrongly host its reply inbox on
// the directory session, where the member cannot call it back. Route-based
// resolution returns the same live exporter session both times, so the reply
// path keeps working on the reused connection.
//
// Run by `zig build demo-rooms-dm-reredeem`.
//   deno run --allow-ffi --allow-read --allow-net --allow-env apps/rooms/test/dm_reredeem_test.ts

import process from "node:process";
import { formatPeerUri, TRANSPORT_KEYED_RELAY } from "@pancake/runtime";
import { recordingReplyDm } from "../lib/dm_reply.ts";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { serveDirectory } from "../server/main.ts";
import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { DirectMessage, Directory, Room } from "../lib/room_client.ts";
import { waitUntil } from "../demos/dm_handoff.ts";
import { DM } from "../lib/protocol.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";

const ROOM = "lobby";

function fail(message: string): never {
	console.error(`rooms-dm-reredeem test FAILED: ${message}`);
	process.exit(1);
}

async function main(): Promise<void> {
	// Bob's giftable echoes each DM into an inbox and answers the sender over the
	// arriving connection, so a delivered reply proves the sender hosted its inbox
	// on a real exporter session (not the directory session).
	const bobInbox: string[] = [];
	const dmFor = (_peer: string) => recordingReplyDm(bobInbox, (text) => `got: ${text}`);

	const room = await roomsListen("127.0.0.1", 0);
	const roomLocator = loopbackTcpDesignator(room.port);
	const roomServe = serveDirectory(room.host, room);

	const bobHost = roomsHost();
	const bob = await roomsListen("127.0.0.1", 0, bobHost);
	const bobRuntime = await openRoomsRuntime({ host: bobHost });
	const bobLocator = loopbackTcpDesignator(bob.port);
	let bobAccepts = 0;
	(async () => {
		for await (const session of bob) {
			bobAccepts += 1;
			session.serve().catch(() => {});
		}
	})();

	const bobDir = await Directory.connect(roomLocator, (locator) => dial(locator, bobRuntime));
	const bobRoomRef = await enterOrOpen(bobDir, ROOM);
	await Room.subscribe(bobDir.session, bobRoomRef, "bob");
	const bobOfferer = inboxPublisher(bobHost).offerer({ dir: () => bobDir, behaviorFor: dmFor });
	await bobDir.register("bob", bobLocator, bobOfferer.offer);

	// Carol never listens. She registers to claim a name, then redeems an
	// introduction to Bob twice.
	const carolHost = roomsHost();
	const carolRuntime = await openRoomsRuntime({ host: carolHost });
	const carol = await Directory.connect(roomLocator, (locator) => dial(locator, carolRuntime));
	await carol.register("carol", formatPeerUri(TRANSPORT_KEYED_RELAY, carolHost.designator()));
	const first = await carol.introduceVia("bob");
	const second = await carol.introduceVia("bob");

	if (first.via === null) fail("first redeem surfaced no direct exporter session (via)");
	// The property under test: the re-redeem resolves the same live exporter,
	// even though it triggered no new dial. A capture-window heuristic returns
	// null here.
	if (second.via === null) {
		fail("re-redeem to an already-dialed exporter surfaced via=null (route not resolved)");
	}
	if (second.via !== first.via) {
		fail("re-redeem resolved a different session than the first — not the reused exporter");
	}
	// The reused exporter is a real connection Bob dialed once: no second dial.
	if (bobAccepts !== 1) {
		fail(`expected Bob to accept exactly 1 connection (dial reuse), saw ${bobAccepts}`);
	}

	// A reply inbox hosted on the re-redeemed `via` is callable, so the second
	// send round-trips over the reused connection.
	const replies: string[] = [];
	const inbox = second.via.spawn((verb, args) => {
		if (verb !== DM) throw new Error(`reply inbox has no method ${verb}`);
		replies.push(String(args[0]));
		return null;
	});
	await second.via.send(second.dm, DM, ["second", inbox]);
	await waitUntil(() => bobInbox.includes("second"), 10_000, "Bob to receive the re-redeemed DM");
	await waitUntil(
		() => replies.includes("got: second"),
		10_000,
		"Bob's reply over the reused exporter",
	);

	// Two lines to one member share one connection, so closing one must not
	// hang up the other. `ownsSession` used to be "a route came back", which is
	// a different question from "this line opened it": the second line resolves
	// the exporter the first already dialed, so both claimed it and whichever
	// closed first took the connection down with it.
	const firstLine = await DirectMessage.open(carol, "bob");
	const secondReplies: string[] = [];
	const secondLine = await DirectMessage.open(carol, "bob", {
		message: (text) => {
			secondReplies.push(text);
			return null;
		},
	});
	await firstLine.close();
	await secondLine.say("after the sibling closed");
	await waitUntil(
		() => bobInbox.includes("after the sibling closed"),
		10_000,
		"the surviving line to reach Bob after its sibling closed",
	);
	await waitUntil(
		() => secondReplies.includes("got: after the sibling closed"),
		10_000,
		"the surviving line's reply over the still-open connection",
	);
	// Closing the last line is what hangs up, and closing a spent line again is
	// not a second decrement against whoever holds the connection next.
	await secondLine.close();
	await secondLine.close();

	console.log("rooms-dm-reredeem test OK:");
	console.log("  • sendRedeeming resolves the direct exporter from the reply's route");
	console.log("  • a re-redeem to an already-dialed exporter resolves the same live session");
	console.log("  • no second dial ran (Bob accepted 1 connection), and the reply round-tripped");
	console.log("  • closing one of two lines sharing that connection left the other talking");

	await carol.close();
	await bobDir.close();
	bob.close();
	await carolRuntime.close();
	await bobRuntime.close();
	await room.close();
	await roomServe.catch(() => {});
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
