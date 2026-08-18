// A member replies to a non-listening sender across a redeemed introduction —
// the bidirectional completion of the three-party handoff, over loopback TCP.
//
// This is the native, headless-Chromium-free sibling of `web_dm_test.ts`: it
// drives the same `room_client.ts` `DirectMessage` the browser page uses, so it
// proves the sender half (`Session.sendRedeeming` surfacing the direct exporter
// session, ADR-0088) without a browser. Carol never listens, exactly like a
// browser peer.
//
//   Room   (rendezvous)  serves the directory (TCP).
//   Bob    (member)      publishes a giftable `dm` that answers over the
//                        arriving session (`currentSession()`), listens, and
//                        registers his dialable locator.
//   Carol  (sender)      never listens. She opens a `DirectMessage`, which
//                        redeems the introduction, hosts a reply inbox on the
//                        redeemed direct session, and sends one DM. Bob's
//                        reply lands on that inbox, over the same session.
//
// Run by `zig build demo-rooms-dm-back`.
//   deno run --allow-ffi --allow-read --allow-net --allow-env apps/rooms/demos/dm_back_demo.ts

import process from "node:process";
import { formatPeerUri, TRANSPORT_KEYED_RELAY } from "@pancake/runtime";
import { recordingReplyDm } from "../lib/dm_reply.ts";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { serveDirectory } from "../server/main.ts";
import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { DirectMessage, Directory, Room } from "../lib/room_client.ts";
import { waitUntil } from "./dm_handoff.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";

const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, from a non-listening sender";
const REPLY_TEXT = `got your DM: ${DM_TEXT}`;

function fail(message: string): never {
	console.error(`rooms-dm-back demo FAILED: ${message}`);
	process.exit(1);
}

async function main(): Promise<void> {
	// Bob's giftable answers over the session the DM arrived on, to the reply
	// capability the sender handed it. `recordingReplyDm` carries the
	// eventual-send that answer rides (the reply lands on the next turn).
	const bobInbox: string[] = [];
	const dmFor = (_peer: string) => recordingReplyDm(bobInbox, (text) => `got your DM: ${text}`);

	// The room.
	const room = await roomsListen("127.0.0.1", 0);
	const roomLocator = loopbackTcpDesignator(room.port);
	const roomServe = serveDirectory(room.host, room);

	// Bob: one Host that listens (the redeem target) and dials the room (so
	// `register` can fetch his `dm` on the room session).
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
	// Bob mints an inbox for each peer the directory asks him for; that inbox is
	// what `introduce` hands on.
	const bobOfferer = inboxPublisher(bobHost).offerer({
		dir: () => bobDir,
		behaviorFor: dmFor,
	});
	await bobDir.register("bob", bobLocator, bobOfferer.offer);

	// Carol never listens. She registers to claim the name Bob's inbox is minted
	// for — her keyed identity, not a dial address — then opens a direct line,
	// which redeems the introduction and hosts a reply inbox on that session.
	const carolReplies: string[] = [];
	const carolHost = roomsHost();
	const carolRuntime = await openRoomsRuntime({ host: carolHost });
	const carol = await Directory.connect(roomLocator, (locator) => dial(locator, carolRuntime));
	await carol.register("carol", formatPeerUri(TRANSPORT_KEYED_RELAY, carolHost.designator()));
	const line = await DirectMessage.open(carol, "bob", (text) => {
		carolReplies.push(`bob: ${text}`);
		return null;
	});
	await line.say(DM_TEXT);

	await waitUntil(() => bobInbox.includes(DM_TEXT), 10_000, "Bob to receive Carol's DM");
	await waitUntil(
		() => carolReplies.includes(`bob: ${REPLY_TEXT}`),
		10_000,
		"Bob's reply to reach the non-listening sender over the redeemed session",
	);

	// Bob accepted exactly one inbound session: Carol's redeem dial. His reply
	// rode that session back, never a dial to Carol (who has no listener).
	if (bobAccepts !== 1) {
		fail(`expected Bob to accept exactly 1 session (no dial-back), saw ${bobAccepts}`);
	}

	console.log("rooms-dm-back demo OK:");
	console.log(
		"  • the room introduced Carol to Bob (a desc:handoff-give, redeemed transparently)",
	);
	console.log("  • Carol hosted a reply inbox on the redeemed direct session (sendRedeeming)");
	console.log("  • Bob answered over that same session to Carol, who never listened");

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
