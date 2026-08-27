// Durable private-room creation, exact retry, and restart reconstruction.

import { parseSturdyRef } from "@pancake/runtime";
import { Directory, linkRoomReference, Room } from "../lib/room_client.ts";
import {
	loopbackTcpDesignator,
	roomsAddress,
	roomsHost,
	roomsLocator,
	roomsSturdyrefForSession,
} from "../lib/locator.ts";
import { newPrivateRoomKey } from "../lib/limits.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { RoomsSessionClient } from "../lib/rooms_session.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
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
} from "./support/rooms_server.ts";
import { announcedSturdyref } from "./support/standalone_peer.ts";

const PEER = new URL("../session/main.ts", import.meta.url).pathname;

async function stage<T>(name: string, work: Promise<T>): Promise<T> {
	try {
		return await work;
	} catch (error) {
		throw new Error(`${name}: ${error instanceof Error ? error.message : error}`, { cause: error });
	}
}

function startPeer(directory: string, port: number, checkpoint?: string): Deno.ChildProcess {
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
			...(checkpoint == null ? [] : [`--checkpoint=${checkpoint}`]),
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

roomsTest("a durable Rooms session creates one private room and reconstructs it from its link", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-private-" });
	const roomDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-private-server-" });
	const peerPort = freePort();
	const roomPort = freePort();
	let roomServer = startStatefulServer(roomPort, roomDirectory);
	let peer: Deno.ChildProcess | null = null;
	try {
		await readPort(roomServer);
		const locator = loopbackTcpDesignator(roomPort);
		const directoryId = roomsPeerAuthority(roomsLocator(locator));
		const checkpointPath = `${directory}/checkpoint.json`;
		await Deno.writeTextFile(
			checkpointPath,
			JSON.stringify({
				...emptyRoomsSessionState(),
				directories: [{ id: directoryId, locator, home: true, nick: "private-member", standing: null }],
			}),
		);
		peer = startPeer(directory, peerPort, checkpointPath);
		const sturdyref = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "private Rooms session peer");
		const parsed = parseSturdyRef(sturdyref, "v1_0");
		let session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		const recoveryKey = newPrivateRoomKey();
		const conversation = {
			kind: "room" as const,
			id: "private-conversation",
			directory: directoryId,
			name: "plans",
			held: true,
			standing: null,
			draft: "",
		};
		let link = "";
		let committedRevision = 0;
		try {
			const client = new RoomsSessionClient(
				session,
				await stage("enliven session root", session.enliven(roomsSturdyrefForSession(sturdyref, session))),
			);
			const baseRevision = (await client.snapshot()).revision;
			committedRevision = baseRevision + 1;
			assert(
				await stage(
					"create private room",
					client.openPrivateRoom("private-create", baseRevision, conversation, recoveryKey),
				) ===
					committedRevision,
				"private-room creation did not advance the checkpoint once",
			);
			const snapshot = await client.snapshot();
			const saved = snapshot.checkpoint.conversations.find((entry) => entry.id === conversation.id);
			assert(
				saved?.kind === "room" && saved.held && saved.link != null,
				"private-room authority was not retained",
			);
			link = saved.link;
			assert(
				roomsPeerAuthority(parseSturdyRef(link, "v1_0").locator) === directoryId,
				"private-room result named a different directory",
			);
			assert(snapshot.checkpoint.active === conversation.id, "private-room creation did not select its room");
			assert(
				await stage(
					"retry private room",
					client.openPrivateRoom("private-create", baseRevision, conversation, recoveryKey),
				) ===
					committedRevision,
				"retrying private-room creation did not return its original revision",
			);
			const witness = await Directory.connect(
				locator,
				(address) => dial(address, roomsHost(undefined, "v1-syrup")),
			);
			let enteredByLabel = true;
			try {
				await witness.enter("plans");
			} catch {
				enteredByLabel = false;
			}
			assert(!enteredByLabel, "the private room became reachable by its label");
			const recoveredRoom = await witness.openPrivate("plans", recoveryKey);
			const recoveredLink = await linkRoomReference(witness.session, recoveredRoom);
			witness.session.release(recoveredRoom);
			assert(
				[...parseSturdyRef(recoveredLink, "v1_0").swissnum].join(",") ===
					[...parseSturdyRef(link, "v1_0").swissnum].join(","),
				`recovering the private operation changed its swiss authority: ${link} != ${recoveredLink}`,
			);
			const joined = await Room.subscribe(
				witness.session,
				await stage(
					"enliven private room",
					witness.session.enliven(roomsSturdyrefForSession(link, witness.session)),
				),
				"witness",
			);
			await joined.leave();
			await witness.close();
		} finally {
			await session.close();
		}

		await stopOwned(peer);
		peer = startPeer(directory, peerPort);
		const restoredRef = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "restored private Rooms session");
		assert(restoredRef === sturdyref, "private-room restart changed the Rooms session sturdyref");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		try {
			const restored = new RoomsSessionClient(
				session,
				await stage(
					"enliven restored session root",
					session.enliven(roomsSturdyrefForSession(restoredRef, session)),
				),
			);
			const snapshot = await restored.snapshot();
			assert(snapshot.revision === committedRevision, "restart changed the private-room checkpoint revision");
			const saved = snapshot.checkpoint.conversations.find((entry) => entry.id === conversation.id);
			assert(saved?.kind === "room" && saved.link === link, "restart changed private-room authority");
			assert(snapshot.pendingEffects.length === 0, "restart left private-room creation unresolved");

			await stopServer(roomServer);
			let disconnected = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if (!(await restored.snapshot()).connectedDirectories.includes(directoryId)) {
					disconnected = true;
					break;
				}
			}
			assert(disconnected, "the session did not observe the stopped private-room directory");
			const pendingRoom = { ...conversation, id: "private-recovery", name: "recoverable" };
			let pendingRefused = false;
			try {
				await restored.openPrivateRoom(
					"private-resume",
					committedRevision,
					pendingRoom,
					newPrivateRoomKey(),
				);
			} catch {
				pendingRefused = true;
			}
			assert(pendingRefused, "private-room creation against a stopped directory claimed success");
			const unresolved = await restored.snapshot();
			assert(
				unresolved.pendingEffectDetails.some((effect) =>
					effect.id === "private-resume" && effect.subject.includes("recoverable") &&
					effect.phase === "prepared"
				),
				"the admin snapshot did not describe the recoverable private-room operation",
			);

			roomServer = startStatefulServer(roomPort, roomDirectory);
			await readPort(roomServer);
			let reconnected = false;
			for (let attempt = 0; attempt < 40; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if ((await restored.snapshot()).connectedDirectories.includes(directoryId)) {
					reconnected = true;
					break;
				}
			}
			assert(reconnected, "the session did not reconnect before private-room recovery");
			assert(
				await restored.resumeEffect("private-resume") === committedRevision + 1,
				"resuming private-room creation committed the wrong revision",
			);
			const recovered = await restored.snapshot();
			assert(recovered.pendingEffects.length === 0, "resuming private-room creation left its journal row");
			assert(
				recovered.checkpoint.conversations.some((entry) =>
					entry.kind === "room" && entry.id === pendingRoom.id && entry.link != null
				),
				"resuming private-room creation did not retain its returned authority",
			);
		} finally {
			await session.close();
		}
	} finally {
		if (peer != null) await stopOwned(peer);
		await stopServer(roomServer);
		await Deno.remove(directory, { recursive: true });
		await Deno.remove(roomDirectory, { recursive: true });
	}
});
