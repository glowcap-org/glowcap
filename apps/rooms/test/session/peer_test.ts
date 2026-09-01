// Process proof for durable Rooms session facets, watches, and restart identity.

import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient, type RoomsSessionLineEvent } from "../../lib/session/client.ts";
import { Directory, Room } from "../../lib/room/client.ts";
import { loopbackTcpDesignator, roomsAddress, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { roomsPeerAuthority } from "../../lib/routes.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { stopOwned } from "../support/children.ts";
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
} from "../support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "../support/standalone_peer.ts";
import { sessionAdminPath } from "../../session/readiness.ts";
import { revokeRoomLink, takeRoomsOperator } from "../../lib/operator.ts";
import { roomAuthorityToken } from "../../lib/room/authority.ts";

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

roomsTest("online room authority rotation reconciles the shared checkpoint without a browser", async () => {
	const sessionDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-authority-" });
	const roomDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-authority-room-" });
	const sessionPort = freePort();
	const roomPort = freePort();
	const roomLocator = loopbackTcpDesignator(roomPort);
	const roomDirectoryId = roomsPeerAuthority(roomsLocator(roomLocator));
	const checkpointPath = `${sessionDirectory}/checkpoint.json`;
	await Deno.writeTextFile(
		checkpointPath,
		JSON.stringify({
			...emptyRoomsSessionState(),
			directories: [{
				id: roomDirectoryId,
				locator: roomLocator,
				home: true,
				nick: "shared-owner",
				standing: null,
			}],
			conversations: [{
				kind: "room",
				id: "shared-room",
				directory: roomDirectoryId,
				name: "authority-sync",
				held: false,
				standing: null,
				draft: "",
			}],
			active: "shared-room",
		}),
	);
	const roomServer = startStatefulServer(roomPort, roomDirectory, ["--operator"]);
	let peer: Deno.ChildProcess | null = null;
	let session: Awaited<ReturnType<typeof dial>> | null = null;
	let operatorSession: Awaited<ReturnType<typeof dial>> | null = null;
	let typingDirectory: Directory | null = null;
	let typingRoom: Room | null = null;
	try {
		await readPort(roomServer);
		const operatorSwiss = (await Deno.readTextFile(`${roomDirectory}/operator`)).trim();
		const checkpoint = JSON.parse(await Deno.readTextFile(checkpointPath));
		checkpoint.capabilities.operations = [{
			capability: "operator",
			scope: roomDirectoryId,
			swiss: operatorSwiss,
		}];
		await Deno.writeTextFile(checkpointPath, JSON.stringify(checkpoint));
		peer = startRoomsSessionPeer(sessionDirectory, sessionPort, checkpointPath);
		const root = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "authority Rooms session peer");
		const parsed = parseSturdyRef(root, "v1_0");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		const client = new RoomsSessionClient(session, await session.enliven(root));
		let snapshot = await client.snapshot();
		for (
			let attempt = 0;
			attempt < 50 &&
			(!snapshot.roomViews.some((view) => view.conversationId === "shared-room") ||
				snapshot.checkpoint.conversations[0]?.kind !== "room" ||
				snapshot.checkpoint.conversations[0].manager == null);
			attempt += 1
		) {
			await new Promise((resolve) => setTimeout(resolve, 100));
			snapshot = await client.snapshot();
		}
		assert(
			snapshot.roomViews.some((view) => view.conversationId === "shared-room"),
			"the shared room never realized",
		);
		snapshot = await client.snapshot();
		const created = snapshot.checkpoint.conversations[0];
		assert(
			created.kind === "room" && created.link != null && created.manager != null,
			"shared room creation did not retain room and manager authority",
		);
		await client.takeRoomModerator("moderate-room", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		const issued = snapshot.checkpoint.conversations[0];
		if (issued.kind !== "room" || issued.link == null || issued.steward == null) {
			throw new Error("the shared session did not retain its room authorities");
		}
		if (created.kind !== "room" || created.manager == null) {
			throw new Error("the shared session had no manager to discard");
		}
		await client.command(
			"discard-room-manager",
			snapshot.revision,
			"dropRoomManager",
			["shared-room", roomAuthorityToken(created.manager)],
		);
		snapshot = await client.snapshot();
		assert(
			snapshot.checkpoint.conversations[0]?.kind === "room" &&
				snapshot.checkpoint.conversations[0].manager == null,
			"the shared session did not discard its manager occurrence",
		);
		await client.command(
			"recover-room-manager",
			snapshot.revision,
			"recoverRoomManager",
			["shared-room"],
		);
		snapshot = await client.snapshot();
		assert(
			snapshot.checkpoint.conversations[0]?.kind === "room" &&
				snapshot.checkpoint.conversations[0].manager === created.manager,
			"the shared session's directory operator did not recover room management",
		);
		const firstLink = issued.link;
		await client.command(
			"managed-revoke-room",
			snapshot.revision,
			"revokeManagedRoomAuthority",
			["shared-room", "room", roomAuthorityToken(firstLink)],
		);
		for (let attempt = 0; attempt < 50; attempt += 1) {
			snapshot = await client.snapshot();
			const room = snapshot.checkpoint.conversations[0];
			if (room.kind === "room" && room.link == null && room.steward == null) break;
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		let managedRoom = snapshot.checkpoint.conversations[0];
		assert(
			managedRoom.kind === "room" && managedRoom.link == null && managedRoom.steward == null &&
				managedRoom.manager != null,
			"manager revocation did not retire the link while preserving room management",
		);
		await client.ensureRoomLink("managed-reissue-room", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		managedRoom = snapshot.checkpoint.conversations[0];
		assert(
			managedRoom.kind === "room" && managedRoom.link != null && managedRoom.link !== firstLink,
			"the held manager could not reissue a revoked room link",
		);
		const managedLink = managedRoom.link;
		await client.takeRoomModerator("managed-reissue-moderator", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		managedRoom = snapshot.checkpoint.conversations[0];
		assert(
			managedRoom.kind === "room" && managedRoom.steward != null,
			"the held manager could not reissue moderation after link revocation",
		);
		// Result commands advance realization generations without replacing an
		// unchanged membership. Its subscription callbacks must remain live across
		// those revisions rather than capturing the plan that first created it.
		const typingOn = Promise.withResolvers<RoomsSessionLineEvent>();
		const typingOff = Promise.withResolvers<RoomsSessionLineEvent>();
		await client.watch(() => {}, (event) => {
			if (event.conversationId !== "shared-room" || event.presence?.kind !== "typing") return;
			(event.presence.on ? typingOn : typingOff).resolve(event);
		});
		typingDirectory = await Directory.connect(roomLocator, (address) => dial(address));
		typingRoom = await Room.subscribe(
			typingDirectory.session,
			await typingDirectory.enter("authority-sync"),
			"typing-guest",
		);
		await typingRoom.setTyping(true);
		assert(
			(await within(typingOn.promise, "room typing reaching the shared view")).from === "typing-guest",
			"the shared session projected room typing from the wrong member",
		);
		await typingRoom.setTyping(false);
		await within(typingOff.promise, "stopped room typing reaching the shared view");

		operatorSession = await dial(roomLocator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		const currentAuthority = snapshot.checkpoint.conversations[0];
		if (currentAuthority.kind !== "room" || currentAuthority.steward == null) {
			throw new Error("the managed reissue did not leave current moderation to revoke");
		}
		await client.operator(
			"revoke-moderator-through-session",
			snapshot.revision,
			roomDirectoryId,
			"revokeRoomAuthority",
			["steward", roomAuthorityToken(currentAuthority.steward)],
		);
		for (let attempt = 0; attempt < 50; attempt += 1) {
			snapshot = await client.snapshot();
			const room = snapshot.checkpoint.conversations[0];
			if (room.kind === "room" && room.steward == null) break;
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		let room = snapshot.checkpoint.conversations[0];
		assert(room.kind === "room" && room.link === managedLink, "moderator rotation cleared the room link");
		assert(room.kind === "room" && room.steward == null, "moderator rotation remained in the shared checkpoint");

		await client.takeRoomModerator("moderate-room-again", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		room = snapshot.checkpoint.conversations[0];
		if (room.kind !== "room" || room.link == null) {
			throw new Error("the shared room lost its link before revocation");
		}
		await client.operator(
			"revoke-room-through-session",
			snapshot.revision,
			roomDirectoryId,
			"revokeRoomAuthority",
			["room", roomAuthorityToken(room.link)],
		);
		for (let attempt = 0; attempt < 50; attempt += 1) {
			snapshot = await client.snapshot();
			room = snapshot.checkpoint.conversations[0];
			if (room.kind === "room" && room.link == null && room.steward == null) break;
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		assert(room.kind === "room" && room.link == null, "room rotation remained in the shared checkpoint");
		assert(room.kind === "room" && room.steward == null, "room rotation left stale moderator authority");

		await client.ensureRoomLink("link-room-again", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		const reissued = snapshot.checkpoint.conversations[0];
		assert(reissued.kind === "room" && reissued.link !== firstLink, "room reissue reused retired authority");
		await client.takeRoomModerator("moderate-room-offline", snapshot.revision, "shared-room");
		snapshot = await client.snapshot();
		const offlineAuthority = snapshot.checkpoint.conversations[0];
		assert(
			offlineAuthority.kind === "room" && offlineAuthority.link != null && offlineAuthority.steward != null,
			"the offline reconciliation fixture did not retain both authorities",
		);

		await session.close();
		session = null;
		await stopOwned(peer);
		peer = null;
		await revokeRoomLink(operatorSession, operator.cap, "authority-sync");

		peer = startRoomsSessionPeer(sessionDirectory, sessionPort);
		const restartedRoot = await announcedSturdyref(
			peer,
			"ROOMS-SESSION-LISTENING",
			"restarted authority Rooms session peer",
		);
		assert(restartedRoot === root, "offline reconciliation restart changed the session authority");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		const restarted = new RoomsSessionClient(session, await session.enliven(restartedRoot));
		for (let attempt = 0; attempt < 50; attempt += 1) {
			snapshot = await restarted.snapshot();
			room = snapshot.checkpoint.conversations[0];
			if (room.kind === "room" && room.link == null && room.steward == null && room.reconnect === "manual") break;
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		assert(room.kind === "room" && room.link == null, "offline room retirement stayed in the checkpoint");
		assert(room.kind === "room" && room.steward == null, "offline moderator retirement stayed in the checkpoint");
		assert(
			room.kind === "room" && room.reconnect === "manual",
			"offline retirement silently rejoined by room name",
		);
		assert(
			!snapshot.roomViews.some((view) => view.conversationId === "shared-room"),
			"a retired link realized a room",
		);
		assert(
			!snapshot.issues.some((issue) => issue.reason.includes("unknown swissnum")),
			"offline reconciliation exposed a core publication detail as permanent session trouble",
		);
		if (room.kind !== "room") throw new Error("the reconciled conversation changed kind");
		await restarted.joinRoom("explicit-room-rejoin", snapshot.revision, {
			locator: roomLocator,
			nick: "shared-owner",
			conversation: room,
		});
		for (let attempt = 0; attempt < 50; attempt += 1) {
			snapshot = await restarted.snapshot();
			if (snapshot.roomViews.some((view) => view.conversationId === "shared-room")) break;
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		assert(
			snapshot.roomViews.some((view) => view.conversationId === "shared-room"),
			"explicit rejoin did not realize",
		);
		const recoveredRoom = snapshot.checkpoint.conversations.find((entry) => entry.id === "shared-room");
		assert(
			recoveredRoom?.kind === "room" && recoveredRoom.reconnect == null,
			"successful explicit rejoin kept its manual recovery marker",
		);
	} finally {
		if (typingRoom != null) await typingRoom.leave().catch(() => {});
		if (typingDirectory != null) await typingDirectory.close().catch(() => {});
		if (operatorSession != null) await operatorSession.close();
		if (session != null) await session.close();
		if (peer != null) await stopOwned(peer);
		await stopServer(roomServer);
		await Deno.remove(sessionDirectory, { recursive: true });
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
		let session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		const viewSession = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const admin = new RoomsSessionClient(
				session,
				await session.enliven(firstLink),
			);
			const viewAdmin = new RoomsSessionClient(
				viewSession,
				await viewSession.enliven(firstLink),
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
			const attachedTyping = Promise.withResolvers<RoomsSessionLineEvent>();
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
					if (event.presence?.kind === "typing" && event.presence.on) attachedTyping.resolve(event);
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
			await interaction.setTyping("durable-room-record", true);
			assert(
				(await within(attachedTyping.promise, "typing between attached session views")).from ===
					"Another attached view",
				"one attached view did not receive another's shared-member typing level",
			);
			await interaction.setTyping("durable-room-record", false);
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
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const restored = new RoomsSessionClient(
				session,
				await session.enliven(secondLink),
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
