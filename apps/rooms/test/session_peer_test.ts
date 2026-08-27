// Process proof for durable Rooms session facets, watches, and restart identity.

import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient, type RoomsSessionLineEvent } from "../lib/rooms_session.ts";
import { Directory, Room } from "../lib/room_client.ts";
import {
	loopbackTcpDesignator,
	roomsAddress,
	roomsHost,
	roomsLocator,
	roomsSturdyrefForSession,
} from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { stopOwned } from "./support/children.ts";
import {
	assert,
	dial,
	freePort,
	nextMessage,
	readPort,
	roomsTest,
	startStatefulServer,
	stopServer,
	within,
} from "./support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "./support/standalone_peer.ts";
import { sessionAdminPath } from "../session/readiness.ts";

async function sessionAdminMirror(path: string): Promise<string> {
	return (await Deno.readTextFile(path)).trim();
}

async function assertSessionAdminMirrorGone(path: string): Promise<void> {
	try {
		await Deno.stat(path);
		throw new Error("the stopped Rooms session left a ready administrator mirror behind");
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
	}
}

async function refused(action: () => Promise<unknown>): Promise<boolean> {
	try {
		await action();
		return false;
	} catch {
		return true;
	}
}

roomsTest("a durable Rooms session retries a directory that was unavailable at startup", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-retry-" });
	const roomDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-retry-room-" });
	const peerPort = freePort();
	const roomPort = freePort();
	const roomLocator = loopbackTcpDesignator(roomPort);
	const roomDirectoryId = roomsPeerAuthority(roomsLocator(roomLocator));
	const checkpointPath = `${directory}/checkpoint.json`;
	await Deno.writeTextFile(
		checkpointPath,
		JSON.stringify({
			...emptyRoomsSessionState(),
			directories: [{
				id: roomDirectoryId,
				locator: roomLocator,
				home: true,
				nick: "retrying-member",
				standing: null,
			}],
		}),
	);
	const peer = startRoomsSessionPeer(directory, peerPort, checkpointPath);
	let roomServer: Deno.ChildProcess | null = null;
	try {
		const link = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "retrying Rooms session peer");
		const parsed = parseSturdyRef(link, "v1_0");
		const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		try {
			const client = new RoomsSessionClient(
				session,
				await session.enliven(roomsSturdyrefForSession(link, session)),
			);
			assert(
				(await client.snapshot()).workspaceAdoption === "closed",
				"a supplied checkpoint left workspace adoption available",
			);
			assert(
				!(await client.snapshot()).connectedDirectories.includes(roomDirectoryId),
				"the unavailable directory was reported connected",
			);
			roomServer = startStatefulServer(roomPort, roomDirectory);
			await readPort(roomServer);
			let connected = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if ((await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					connected = true;
					break;
				}
			}
			assert(connected, "the durable session did not retry its unavailable directory");
			await stopServer(roomServer);
			roomServer = null;
			let disconnected = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if (!(await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					disconnected = true;
					break;
				}
			}
			assert(disconnected, "the durable session kept reporting a stopped directory as connected");
			roomServer = startStatefulServer(roomPort, roomDirectory);
			await readPort(roomServer);
			connected = false;
			for (let attempt = 0; attempt < 40; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if ((await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					connected = true;
					break;
				}
			}
			assert(connected, "the durable session did not reconnect after the directory restarted");
		} finally {
			await session.close();
		}
	} finally {
		await stopOwned(peer);
		if (roomServer != null) await stopServer(roomServer);
		await Deno.remove(directory, { recursive: true });
		await Deno.remove(roomDirectory, { recursive: true });
	}
});

roomsTest("a durable Rooms session shares revisioned state through attenuated facets and restart", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-peer-" });
	const readinessDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-ready-" });
	const readinessFile = sessionAdminPath(readinessDirectory);
	const roomDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-room-" });
	const port = freePort();
	const roomPort = freePort();
	const roomServer = startStatefulServer(roomPort, roomDirectory);
	let peer = startRoomsSessionPeer(directory, port, undefined, readinessFile);
	try {
		await readPort(roomServer);
		const roomLocator = loopbackTcpDesignator(roomPort);
		const roomDirectoryId = roomsPeerAuthority(roomsLocator(roomLocator));
		const firstLink = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "Rooms session peer");
		assert(
			await sessionAdminMirror(readinessFile) === firstLink,
			"the readiness mirror changed the administrator link",
		);
		const parsed = parseSturdyRef(firstLink, "v1_0");
		let session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		const viewSession = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		try {
			const admin = new RoomsSessionClient(
				session,
				await session.enliven(roomsSturdyrefForSession(firstLink, session)),
			);
			const viewAdmin = new RoomsSessionClient(
				viewSession,
				await viewSession.enliven(roomsSturdyrefForSession(firstLink, viewSession)),
			);
			const grant = await viewAdmin.facet("observe");
			const observer = grant.session;
			const interactionGrant = await admin.facet("interact");
			const interaction = interactionGrant.session;
			const changed = Promise.withResolvers<number>();
			const lineEvent = Promise.withResolvers<string>();
			const observedLineEvent = Promise.withResolvers<RoomsSessionLineEvent>();
			const interactiveLineEvent = Promise.withResolvers<RoomsSessionLineEvent>();
			const attachedFileEvent = Promise.withResolvers<RoomsSessionLineEvent>();
			let changeCalls = 0;
			const baseline = await observer.watch(
				(snapshot) => {
					changeCalls += 1;
					changed.resolve(snapshot.revision);
				},
				(event) => {
					if (event.text === "line through the durable session") lineEvent.resolve(event.conversationId);
					if (event.text === "sent by an attached controller") {
						observedLineEvent.resolve(event);
					}
					if (event.text === "durable file") attachedFileEvent.resolve(event);
				},
			);
			await interaction.watch(
				() => {},
				(event) => {
					if (event.text === "sent by an attached controller") interactiveLineEvent.resolve(event);
				},
			);
			assert(baseline.revision === 0, "fresh session did not start at revision zero");
			assert(
				baseline.workspaceAdoption === "available",
				"a new session did not expose its one-time workspace adoption state",
			);
			const checkpoint = {
				...emptyRoomsSessionState(),
				standing: "shared through a capability",
				directories: [{
					id: roomDirectoryId,
					locator: roomLocator,
					home: true,
					nick: "durable-member",
					standing: null,
				}],
				conversations: [{
					kind: "room" as const,
					id: "durable-room-record",
					directory: roomDirectoryId,
					name: "durable-room",
					held: false,
					standing: null,
					draft: "",
				}],
				active: "durable-room-record",
			};
			assert(
				await refused(() => observer.adoptWorkspace("observe-adoption", 0, checkpoint)),
				"an observe facet adopted the initial workspace",
			);
			assert(
				await refused(() => interaction.adoptWorkspace("interact-adoption", 0, checkpoint)),
				"an interaction facet adopted the initial workspace",
			);
			assert(
				await admin.adoptWorkspace("process-adoption", 0, checkpoint) === 1,
				"admin did not adopt the initial workspace",
			);
			assert(
				(await admin.snapshot()).workspaceAdoption === "closed",
				"the accepted workspace left adoption available",
			);
			assert(
				await within(changed.promise, "session observer change") === 1,
				"observer received the wrong revision",
			);
			assert(
				await interaction.setDraft("draft-operation", 1, "durable-room-record", "shared draft") === 2,
				"interaction did not commit the shared draft",
			);
			let operationReused = true;
			try {
				await interaction.select("draft-operation", 2, "durable-room-record");
			} catch {
				operationReused = false;
			}
			assert(!operationReused, "an operation id was reused for a different session command");
			assert(
				await refused(() => interaction.replaceOperationsCapabilities("interaction-operations", 2, [])),
				"an interaction facet replaced retained operations authority it could not inspect",
			);
			assert(
				await refused(() => interaction.selectArchive("interaction-archive", 2, null)),
				"an interaction facet replaced retained archive authority it could not inspect",
			);
			let observeMutated = true;
			try {
				await observer.setStanding("forbidden", 2, "not allowed");
			} catch {
				observeMutated = false;
			}
			assert(!observeMutated, "an observe facet replaced session state");
			const witnessDirectory = await Directory.connect(roomLocator, (address) => dial(address));
			const witness = await Room.subscribe(
				witnessDirectory.session,
				await witnessDirectory.enter("durable-room"),
				"witness",
			);
			await nextMessage(witness, (message) => message.text.includes("durable-member"));
			let rosterReady = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				const live = (await admin.snapshot()).roomViews.find((view) =>
					view.conversationId === "durable-room-record"
				);
				if (live?.members.some(([name]) => name === "witness")) {
					rosterReady = true;
					break;
				}
				await new Promise((resolve) => setTimeout(resolve, 10));
			}
			assert(rosterReady, "the session snapshot did not reflect the drained room roster");
			await witness.say("line through the durable session");
			assert(
				await within(lineEvent.promise, "durable session line event") === "durable-room-record",
				"an attached observer did not receive the room line under its stable conversation id",
			);
			assert(
				await interaction.say("say-operation", 2, "durable-room-record", "sent by an attached controller") ===
					2,
				"the attached controller's send did not commit",
			);
			await nextMessage(witness, (message) => message.text === "sent by an attached controller");
			const observedLine = await within(observedLineEvent.promise, "observed controller line event");
			assert(!observedLine.editable, "an observe facet received retained line authority");
			const ownedLine = await within(interactiveLineEvent.promise, "interactive controller line event");
			assert(
				ownedLine.conversationId === "durable-room-record" && ownedLine.lineId != null && ownedLine.editable &&
					ownedLine.history?.id === String(ownedLine.lineId),
				"the controller's own line did not return with its retained authority",
			);
			const edited = nextMessage(
				witness,
				(message) => message.lineId === ownedLine.lineId && message.change === "edited",
			);
			assert(
				await interaction.editLine(
					"edit-operation",
					2,
					"durable-room-record",
					ownedLine.lineId,
					"edited by an attached controller",
				) === 2,
				"the attached edit changed the checkpoint revision",
			);
			await within(edited, "the attached line edit");
			const withdrawn = nextMessage(
				witness,
				(message) => message.lineId === ownedLine.lineId && message.change === "withdrawn",
			);
			assert(
				await interaction.withdrawLine("withdraw-operation", 2, "durable-room-record", ownedLine.lineId) === 2,
				"the attached withdrawal changed the checkpoint revision",
			);
			await within(withdrawn, "the attached line withdrawal");
			const fileLine = nextMessage(
				witness,
				(message) => message.text === "durable file" && message.attachments.length === 1,
			);
			assert(
				await interaction.sendFiles("file-operation", 2, "durable-room-record", "durable file", [{
					name: "proof.txt",
					mime: "text/plain",
					bytes: new TextEncoder().encode("owned by the durable session"),
				}]) === 2,
				"the attached controller's file send changed the checkpoint revision",
			);
			const postedFile = await within(fileLine, "durable session file line");
			const fileBytes = await witness.fetch(postedFile.attachments[0]);
			assert(
				new TextDecoder().decode(fileBytes) === "owned by the durable session",
				"the durable session file bytes changed",
			);
			const projectedFile = await within(attachedFileEvent.promise, "attached session file event");
			assert(projectedFile.attachments.length === 1, "the shared view event dropped the file capability");
			const projectedBytes = await observer.fetchAttachment(projectedFile.attachments[0]);
			observer.releaseAttachment(projectedFile.attachments[0]);
			assert(
				new TextDecoder().decode(projectedBytes) === "owned by the durable session",
				"the attached view's proxied file bytes changed",
			);
			assert(
				await interaction.say("say-operation", 2, "durable-room-record", "sent by an attached controller") ===
					2,
				"retrying a committed send did not return its committed revision",
			);
			let unavailable = false;
			try {
				await interaction.say("unresolved-send", 2, "missing-room", "cannot be delivered");
			} catch (error) {
				unavailable = error instanceof Error && error.message.includes("no longer part of this Rooms session");
			}
			assert(unavailable, "a send to an absent conversation was not refused before admission");
			assert(
				!(await admin.snapshot()).pendingEffects.includes("unresolved-send"),
				"a send that ran no external effect was retained as unresolved",
			);
			await interactionGrant.revoke();
			let revokedInteracted = true;
			try {
				await interaction.setStanding("revoked-interaction", 2, "not allowed");
			} catch {
				revokedInteracted = false;
			}
			assert(!revokedInteracted, "an already-live revoked interaction facet still mutated the session");
			await grant.revoke();
			let revokedObserved = true;
			try {
				await observer.snapshot();
			} catch {
				revokedObserved = false;
			}
			assert(!revokedObserved, "an already-live revoked observe facet still read the session");
			const callsBeforeRevokeProof = changeCalls;
			assert(
				await admin.setStanding("after-observer-revoke", 2, "after observer revoke") === 3,
				"admin could not mutate after revoking an observer",
			);
			await new Promise((resolve) => setTimeout(resolve, 50));
			assert(changeCalls === callsBeforeRevokeProof, "a revoked observe facet kept receiving checkpoint changes");
			assert((await admin.snapshot()).revision === 3, "revoking one facet changed the durable session");
			await witness.leave();
			await witnessDirectory.close();
		} finally {
			await viewSession.close();
			await session.close();
		}

		await stopOwned(peer);
		await assertSessionAdminMirrorGone(readinessFile);
		peer = startRoomsSessionPeer(directory, port, undefined, readinessFile);
		const secondLink = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "Rooms session peer");
		assert(secondLink === firstLink, "restart changed the durable Rooms session sturdyref");
		assert(
			await sessionAdminMirror(readinessFile) === secondLink,
			"restart published a stale administrator mirror",
		);
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		try {
			const restored = new RoomsSessionClient(
				session,
				await session.enliven(roomsSturdyrefForSession(secondLink, session)),
			);
			const snapshot = await restored.snapshot();
			assert(snapshot.revision === 3, "restart lost the session revision");
			assert(snapshot.pendingEffects.length === 0, "a committed send remained unresolved after restart");
			assert(snapshot.checkpoint.standing === "after observer revoke", "restart lost shared session state");
			assert(
				snapshot.checkpoint.conversations[0].draft === "shared draft",
				"restart lost the shared draft mutation",
			);
			const history = await restored.readHistory("room", roomDirectoryId, "durable-room-record");
			assert(
				history.some((record) => record.kind === "line" && record.text === "line through the durable session"),
				"restart lost the durable session's default room archive",
			);
		} finally {
			await session.close();
		}
	} finally {
		await stopOwned(peer);
		await stopServer(roomServer);
		await Deno.remove(directory, { recursive: true });
		await Deno.remove(readinessDirectory, { recursive: true });
		await Deno.remove(roomDirectory, { recursive: true });
	}
});
