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
//   deno run --allow-ffi --allow-read --allow-net --allow-env apps/rooms/dm_reredeem_test.ts

import process from "node:process";
import { Host, listen } from "@pancake/stack";
import { recordingReplyDm } from "./lib/dm_reply.ts";
import { serveDirectory } from "./deno/server.ts";
import { dial, loopbackTcpDesignator } from "./deno/lib/locator.ts";
import { enterOrOpen } from "./deno/lib/enter_room.ts";
import { Directory, Room } from "./lib/room_client.ts";
import { waitUntil } from "./dm_handoff.ts";
import { DM } from "./lib/protocol.ts";

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
	const dmBehavior = recordingReplyDm(bobInbox, "bob", (text) => `got: ${text}`);

	const room = listen("127.0.0.1", 0);
	const roomLocator = loopbackTcpDesignator(await room.ready());
	const roomServe = serveDirectory(room);

	const bobHost = new Host();
	bobHost.publishGiftable("dm", dmBehavior);
	const bob = listen("127.0.0.1", 0, bobHost);
	const bobLocator = loopbackTcpDesignator(await bob.ready());
	let bobAccepts = 0;
	(async () => {
		for await (const session of bob) {
			bobAccepts += 1;
			session.serve().catch(() => {});
		}
	})();

	const bobDir = await Directory.connect(roomLocator, (l) => dial(l, bobHost));
	bobDir.session.publish("dm", dmBehavior);
	const bobRoomRef = await enterOrOpen(bobDir, ROOM);
	await Room.subscribe(bobDir.session, bobRoomRef, "bob");
	await bobDir.register("bob", bobLocator);

	// Carol never listens. She redeems an introduction to Bob twice.
	const carol = await Directory.connect(roomLocator, dial);
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
		replies.push(String(args[1]));
		return null;
	});
	await second.via.send(second.dm, DM, ["carol", "second", inbox]);
	await waitUntil(() => bobInbox.includes("second"), 10_000, "Bob to receive the re-redeemed DM");
	await waitUntil(
		() => replies.includes("got: second"),
		10_000,
		"Bob's reply over the reused exporter",
	);

	console.log("rooms-dm-reredeem test OK:");
	console.log("  • sendRedeeming resolves the direct exporter from the reply's route");
	console.log("  • a re-redeem to an already-dialed exporter resolves the same live session");
	console.log("  • no second dial ran (Bob accepted 1 connection), and the reply round-tripped");

	await carol.close();
	await bobDir.close();
	bob.close();
	await room.close();
	await roomServe.catch(() => {});
	process.exit(0);
}

main().catch((err) => fail(err instanceof Error ? (err.stack ?? err.message) : String(err)));
