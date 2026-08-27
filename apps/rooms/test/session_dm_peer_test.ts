import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient } from "../lib/rooms_session.ts";
import {
	loopbackTcpDesignator,
	roomsAddress,
	roomsHost,
	roomsLocator,
	roomsSturdyrefForSession,
} from "../lib/locator.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";
import {
	assert,
	dial,
	freePort,
	readPort,
	roomsTest,
	ROOT,
	startStatefulServer,
	stopServer,
	within,
} from "./support/rooms_server.ts";
import { announcedSturdyref } from "./support/standalone_peer.ts";

const PEER = new URL("../session/main.ts", import.meta.url).pathname;

function startPeer(directory: string, port: number): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [
			"run",
			"--allow-ffi",
			"--unstable-ffi",
			`--allow-read=${ROOT},${directory}`,
			`--allow-write=${directory}`,
			"--allow-net=127.0.0.1",
			"--allow-env=PANCAKE_LIB_DIR",
			PEER,
			`--state=${directory}`,
			`--checkpoint=${directory}/checkpoint.json`,
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

roomsTest("two durable Rooms sessions restore and exchange one direct conversation", async () => {
	const serverState = await Deno.makeTempDir({ prefix: "pancake-rooms-session-dm-server-" });
	const aliceState = await Deno.makeTempDir({ prefix: "pancake-rooms-session-dm-alice-" });
	const bobState = await Deno.makeTempDir({ prefix: "pancake-rooms-session-dm-bob-" });
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
			const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
			return {
				session,
				client: new RoomsSessionClient(session, await session.enliven(roomsSturdyrefForSession(link, session))),
			};
		};
		const alice = await open(aliceLink);
		const bob = await open(bobLink);
		try {
			const received = Promise.withResolvers<string>();
			const edited = Promise.withResolvers<string>();
			const withdrawn = Promise.withResolvers<boolean>();
			await bob.client.watch(() => {}, (event) => {
				if (event.conversationId === "bob-alice") received.resolve(event.text);
				if (event.conversationId === "bob-alice" && event.change === "edited") edited.resolve(event.text);
				if (event.conversationId === "bob-alice" && event.change === "withdrawn") withdrawn.resolve(true);
			});
			const sent = Promise.withResolvers<import("../lib/rooms_session.ts").RoomsSessionLineEvent>();
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
			await bob.client.startDirect("bob-open-alice", bobSnapshot.revision, {
				kind: "direct",
				id: "bob-alice",
				directory,
				peer: aliceRegistration.name,
				peerRegistrationId: aliceRegistration.registrationId,
				closed: false,
				draft: "",
			});
			await alice.client.say("durable-dm-send", revision, "alice-bob", "hello from the shared session");
			assert(
				await within(received.promise, "the durable direct message") === "hello from the shared session",
				"the durable direct message changed",
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
