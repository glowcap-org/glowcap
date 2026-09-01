// Process-level proof for the deployable archive peer. The same TCP locator,
// Host seed, publication entropy, and state directory must reproduce one
// sturdyref, and a v1/Syrup client must redeem it after the process restarts.

import { parseSturdyRef } from "@pancake/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveLine,
	putArchive,
	putArchiveWithAttachments,
	readArchive,
	readArchiveAttachment,
} from "../../lib/archive/protocol.ts";
import { issueArchiveShare, listArchiveShares, revokeArchiveShare } from "../../lib/archive/client.ts";
import { fetchBlob } from "../../lib/attachment.ts";
import { roomsAddress, roomsHost } from "../../lib/locator.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { assert, dial, freePort, roomsTest, ROOT } from "../support/rooms_server.ts";
import { announcedSturdyref } from "../support/standalone_peer.ts";

const PEER = new URL("../../archive/main.ts", import.meta.url).pathname;

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

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
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

function record(): ArchiveLine {
	return {
		kind: "line",
		source: "restart-source",
		generation: "restart-generation",
		id: "restart-line",
		conversationKind: "direct",
		directory: "ocapn://directory.example",
		conversation: "alice",
		from: "alice",
		text: "survives the peer",
		mine: false,
		at: 1,
		state: "present",
		attachments: [],
	};
}

roomsTest("archive sturdyref and records survive the standalone peer restarting", async () => {
	const directory = await Deno.makeTempDir();
	const port = freePort();
	let peer = startPeer(directory, port);
	try {
		const firstLink = await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "archive peer");
		const parsed = parseSturdyRef(firstLink, "v1_0");
		let session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const archive = await session.enliven(firstLink);
			assert(await putArchive(session, archive, record()) === 1, "peer did not commit its first record");
			const bytes = new TextEncoder().encode("survives as bytes");
			const fileRecord: ArchiveLine = {
				...record(),
				id: "restart-file",
				attachments: [{
					name: "restart.txt",
					mime: "text/plain",
					size: bytes.length,
					width: 0,
					height: 0,
					blob: null,
				}],
			};
			assert(
				await putArchiveWithAttachments(session, archive, fileRecord, [{
					name: "restart.txt",
					mime: "text/plain",
					bytes,
				}]) === 2,
				"peer did not commit its blob record",
			);
		} finally {
			await session.close();
		}

		await stopOwned(peer);
		peer = startPeer(directory, port);
		const secondLink = await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "archive peer");
		assert(secondLink === firstLink, "restart changed the archive sturdyref");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const archive = await session.enliven(secondLink);
			const page = await readArchive(session, archive, ALL_ARCHIVE_RECORDS);
			assert(page.next === 2, "restart changed the archive cursor");
			assert(page.records[0]?.record.id === "restart-line", "restart lost the archived record");
			const fileRecord = page.records.find((entry) => entry.record.id === "restart-file")?.record;
			assert(fileRecord?.kind === "line", "restart lost the archived file record");
			const attachment = await readArchiveAttachment(session, archive, fileRecord, 0);
			assert(attachment !== null, "restart lost the archived blob capability");
			assert(
				new TextDecoder().decode(await fetchBlob(session, attachment)) === "survives as bytes",
				"restart changed the archived blob bytes",
			);
			session.release(attachment.blob);
			assert(session.profile.captpVersion === "v1_0", "archive peer did not serve the interop floor");
			assert(session.profile.codec === "syrup", "archive peer did not serve Syrup");
		} finally {
			await session.close();
		}
	} finally {
		await stopOwned(peer);
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("an archive-peer share redeems after restart and stays revoked", async () => {
	const directory = await Deno.makeTempDir();
	const port = freePort();
	const shareId = "00000000-0000-4000-8000-00000000000a";
	let peer = startPeer(directory, port);
	let session: Awaited<ReturnType<typeof dial>> | null = null;
	try {
		const root = await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "archive peer");
		const parsed = parseSturdyRef(root, "v1_0");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		const archive = await session.enliven(root);
		assert(await putArchive(session, archive, record()) === 1, "peer did not commit the shared record");
		const filter = {
			...ALL_ARCHIVE_RECORDS,
			kind: "line" as const,
			conversationKind: "direct" as const,
			directory: record().directory,
			conversation: record().conversation,
		};
		const shareLink = await issueArchiveShare(session, archive, shareId, "Direct alice", filter);
		assert(
			(await listArchiveShares(session, archive))[0]?.sturdyref === shareLink,
			"the issued share was absent from the whole archive",
		);
		const shared = await session.enliven(shareLink);
		const page = await readArchive(session, shared, ALL_ARCHIVE_RECORDS);
		assert(page.records[0]?.record.id === "restart-line", "the durable share did not answer its scoped records");
		await session.close();
		session = null;

		await stopOwned(peer);
		peer = startPeer(directory, port);
		await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "restored archive peer");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		const restoredShare = await session.enliven(shareLink);
		assert(
			(await readArchive(session, restoredShare)).records[0]?.record.id === "restart-line",
			"restart lost the durable archive share",
		);
		const restoredRoot = await session.enliven(root);
		assert(await revokeArchiveShare(session, restoredRoot, shareId) === true, "revokeShare did not tombstone");
		const liveShare = session;
		assert(
			await refused(() => readArchive(liveShare, restoredShare)),
			"a live durable share still answered after revocation",
		);
		await session.close();
		session = null;

		await stopOwned(peer);
		peer = startPeer(directory, port);
		await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "twice-restored archive peer");
		session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		assert(
			await refused(() => session!.enliven(shareLink)),
			"restart republished a revoked archive share",
		);
	} finally {
		await session?.close().catch(() => {});
		await stopOwned(peer);
		await Deno.remove(directory, { recursive: true });
	}
});
