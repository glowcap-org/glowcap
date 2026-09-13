// Two durable Rooms sessions restore and exchange one direct conversation across real peers.
import { parseSturdyRef } from "@glowcap/runtime";
import { RoomsSessionClient } from "../../lib/session/client.ts";
import { loopbackTcpDesignator, roomsAddress, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { roomsPeerAuthority } from "../../lib/routes.ts";
import { stopOwned } from "../support/children.ts";
import {
	assert,
	dial,
	freePort,
	readPort,
	roomsTest,
	startStatefulServer,
	stopServer,
	within,
} from "../support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "../support/standalone_peer.ts";

function startPeer(directory: string, port: number): Deno.ChildProcess {
	return startRoomsSessionPeer(directory, port, `${directory}/checkpoint.json`);
}

roomsTest("two durable Rooms sessions restore and exchange one direct conversation", async () => {
	const serverState = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-dm-server-" });
	const aliceState = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-dm-alice-" });
	const bobState = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-dm-bob-" });
	const roomPort = freePort();
	const alicePort = freePort();
	const bobPort = freePort();
	const server = startStatefulServer(roomPort, serverState);
	let alicePeer: Deno.ChildProcess | null = null;
	let bobPeer: Deno.ChildProcess | null = null;
	try {
		await readPort(server);
		const locator = loopbackTcpDesignator(roomPort);
		const directory = roomsPeerAuthority(roomsLocator(locator));
		const checkpoint = (nick: string) => ({
			...emptyRoomsSessionState(),
			directories: [{ id: directory, locator, home: true, nick, standing: null }],
		});
		await Deno.writeTextFile(
			`${aliceState}/checkpoint.json`,
			JSON.stringify(checkpoint("alice")),
		);
		await Deno.writeTextFile(
			`${bobState}/checkpoint.json`,
			JSON.stringify(checkpoint("bob")),
		);
		bobPeer = startPeer(bobState, bobPort);
		const bobLink = await announcedSturdyref(bobPeer, "ROOMS-SESSION-LISTENING", "Bob session peer");
		alicePeer = startPeer(aliceState, alicePort);
		const aliceLink = await announcedSturdyref(alicePeer, "ROOMS-SESSION-LISTENING", "Alice session peer");
		const open = async (link: string) => {
			const parsed = parseSturdyRef(link, "v1_0");
			const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
			return {
				session,
				client: new RoomsSessionClient(session, await session.enliven(link)),
			};
		};
		const alice = await open(aliceLink);
		const bob = await open(bobLink);
		try {
			const received = Promise.withResolvers<import("../../lib/session/client.ts").RoomsSessionLineEvent>();
			const edited = Promise.withResolvers<string>();
			const withdrawn = Promise.withResolvers<boolean>();
			await bob.client.watch(() => {}, (event) => {
				if (event.text === "hello from the shared session") received.resolve(event);
				if (event.change === "edited" && event.text === "edited direct text") edited.resolve(event.text);
				if (event.change === "withdrawn") withdrawn.resolve(true);
			});
			const sent = Promise.withResolvers<import("../../lib/session/client.ts").RoomsSessionLineEvent>();
			await alice.client.watch(() => {}, (event) => {
				if (event.conversationId === "alice-bob" && event.text === "hello from the shared session") {
					sent.resolve(event);
				}
			});
			let aliceSnapshot = await alice.client.snapshot();
			let bobSnapshot = await bob.client.snapshot();
			for (let attempt = 0; attempt < 40; attempt += 1) {
				const aliceSeesBob = aliceSnapshot.directoryViews.flatMap((view) => view.peers)
					.find((peer) => peer.name === "bob");
				const bobSeesAlice = bobSnapshot.directoryViews.flatMap((view) => view.peers)
					.find((peer) => peer.name === "alice");
				if (aliceSeesBob != null && bobSeesAlice != null) break;
				await new Promise((resolve) => setTimeout(resolve, 50));
				aliceSnapshot = await alice.client.snapshot();
				bobSnapshot = await bob.client.snapshot();
			}
			const bobRegistration = aliceSnapshot.directoryViews.flatMap((view) => view.peers)
				.find((peer) => peer.name === "bob");
			const aliceRegistration = bobSnapshot.directoryViews.flatMap((view) => view.peers)
				.find((peer) => peer.name === "alice");
			assert(
				bobRegistration != null && aliceRegistration != null,
				"the sessions did not discover each other's claims",
			);
			const revision = await alice.client.startDirect("alice-open-bob", aliceSnapshot.revision, {
				kind: "direct",
				id: "alice-bob",
				directory,
				peer: bobRegistration.name,
				peerRegistrationId: bobRegistration.registrationId,
				closed: false,
				draft: "",
			});
			await alice.client.say("durable-dm-send", revision, "alice-bob", "hello from the shared session");
			const incoming = await within(received.promise, "the durable direct message");
			assert(
				incoming.text === "hello from the shared session",
				"the durable direct message changed",
			);
			bobSnapshot = await bob.client.snapshot();
			const accepted = bobSnapshot.checkpoint.conversations.find((conversation) =>
				conversation.id === incoming.conversationId
			);
			assert(
				accepted?.kind === "direct" && accepted.peerRegistrationId === aliceRegistration.registrationId,
				"the incoming exact registration did not become Bob's durable direct conversation",
			);
			const owned = await within(sent.promise, "the sender's shared direct line");
			assert(
				owned.lineId != null && owned.editable && owned.history?.id === String(owned.lineId),
				"the durable direct send lost its line or archive identity",
			);
			await alice.client.editLine(
				"durable-dm-edit",
				revision,
				"alice-bob",
				owned.lineId,
				"edited direct text",
			);
			assert(
				await within(edited.promise, "the durable direct edit") === "edited direct text",
				"the DM edit moved",
			);
			await alice.client.withdrawLine("durable-dm-withdraw", revision, "alice-bob", owned.lineId);
			assert(
				await within(withdrawn.promise, "the durable direct withdrawal"),
				"the DM withdrawal did not arrive",
			);

			aliceSnapshot = await alice.client.snapshot();
			const joinedRevision = await alice.client.joinRoom(
				"durable-room-to-offer",
				aliceSnapshot.revision,
				{
					locator,
					nick: "alice",
					conversation: {
						kind: "room",
						id: "alice-room",
						directory,
						name: "durable-handoff",
						held: false,
						standing: null,
						draft: "",
					},
				},
			);
			for (let attempt = 0; attempt < 40; attempt += 1) {
				aliceSnapshot = await alice.client.snapshot();
				if (aliceSnapshot.roomViews.some((view) => view.conversationId === "alice-room")) break;
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
			assert(
				aliceSnapshot.roomViews.some((view) => view.conversationId === "alice-room"),
				"the room to hand over never became live",
			);
			await alice.client.offerRoom("durable-room-handoff", joinedRevision, "alice-room", "alice-bob");
			for (let attempt = 0; attempt < 40; attempt += 1) {
				bobSnapshot = await bob.client.snapshot();
				if (bobSnapshot.handedRooms.length !== 0) break;
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
			const handed = bobSnapshot.handedRooms.find((room) => room.from === "alice");
			assert(handed?.label === "durable-handoff", "the receiving durable session saw no live room handoff");
			const acceptanceBase = bobSnapshot.revision;
			const acceptanceRevision = await bob.client.acceptInvitation(
				"accept-durable-room-handoff",
				acceptanceBase,
				handed.id,
				"bob-handed-room",
			);
			bobSnapshot = await bob.client.snapshot();
			const acceptedRoom = bobSnapshot.checkpoint.conversations.find((entry) => entry.id === "bob-handed-room");
			assert(
				acceptedRoom?.kind === "room" && acceptedRoom.link != null,
				"accepting a live handoff did not retain its source-owned durable entry",
			);
			assert(
				await bob.client.acceptInvitation(
					"accept-durable-room-handoff",
					acceptanceBase,
					handed.id,
					"bob-handed-room",
				) === acceptanceRevision,
				"an exact acceptance retry did not return the committed revision",
			);
			await alice.client.offerRoom("durable-room-to-dismiss", joinedRevision, "alice-room", "alice-bob");
			for (let attempt = 0; attempt < 40; attempt += 1) {
				bobSnapshot = await bob.client.snapshot();
				if (bobSnapshot.handedRooms.length !== 0) break;
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
			const declined = bobSnapshot.handedRooms.find((room) => room.from === "alice");
			assert(declined != null, "the second room offer never arrived");
			await bob.client.command("dismiss-live-offer", bobSnapshot.revision, "dismissInvitation", [declined.id]);
			const dismissed = await bob.client.snapshot();
			assert(
				!dismissed.handedRooms.some((room) => room.id === declined.id),
				"a dismissed live offer remained visible",
			);
			assert(
				dismissed.revision === bobSnapshot.revision,
				"dismissing transient authority changed the checkpoint",
			);
		} finally {
			await alice.session.close();
			await bob.session.close();
		}
	} finally {
		if (alicePeer != null) await stopOwned(alicePeer);
		if (bobPeer != null) await stopOwned(bobPeer);
		await stopServer(server);
		await Deno.remove(serverState, { recursive: true });
		await Deno.remove(aliceState, { recursive: true });
		await Deno.remove(bobState, { recursive: true });
	}
});
