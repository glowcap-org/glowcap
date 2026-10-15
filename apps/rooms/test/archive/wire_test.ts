// The member-owned archive is ordinary baseline OCapN application protocol,
// not a Rust-codec-only browser shortcut. A floor-only client fetches the
// live object, writes through it, and reads the same source/generation back.

import {
	ALL_ARCHIVE_RECORDS,
	ARCHIVE_READ,
	archiveBehavior,
	type ArchiveLine,
	archiveRecordRow,
	MAX_ARCHIVE_FACETS_PER_SESSION,
	MAX_ARCHIVE_READ,
	MemoryArchiveBackend,
	narrowArchive,
	putArchive,
	putArchiveWithAttachments,
	readAllArchiveRecords,
	readArchive,
	readArchiveAttachment,
	readArchiveBlob,
	spawnArchive,
} from "../../lib/archive/protocol.ts";
import { fetchBlob } from "../../lib/attachment.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { assert, dial, roomsTest } from "../support/rooms_server.ts";

roomsTest("the archive contract crosses the Goblins-compatible v1/Syrup floor", async () => {
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const session of server) {
			session.publish("archive", archiveBehavior(new MemoryArchiveBackend()));
			session.publish("endlessArchive", (verb, args) => {
				if (verb !== ARCHIVE_READ || typeof args[1] !== "bigint") throw new Error("endless archive read only");
				const after = Number(args[1]);
				const records = Array.from({ length: MAX_ARCHIVE_READ }, (_, offset) => {
					const revision = after + offset + 1;
					const record: ArchiveLine = {
						kind: "line",
						source: "filler-source",
						generation: "filler-generation",
						id: `filler-${revision}`,
						conversationKind: "direct",
						directory: "filler-directory",
						conversation: "filler-conversation",
						from: "filler",
						text: "still promising more",
						mine: false,
						at: revision,
						order: revision,
						state: "present",
						previewUrls: [],
						attachments: [],
					};
					return [BigInt(revision), ...archiveRecordRow(record)];
				});
				return [BigInt(after + records.length), true, records];
			});
			session.publish("revisingArchive", (verb, args) => {
				if (verb !== ARCHIVE_READ || typeof args[1] !== "bigint") throw new Error("revising archive read only");
				const after = Number(args[1]);
				const row = (revision: number, id: string, text: string) => {
					const record: ArchiveLine = {
						kind: "line",
						source: "revising-source",
						generation: "revising-generation",
						id,
						conversationKind: "direct",
						directory: "revising-directory",
						conversation: "revising-conversation",
						from: "reviser",
						text,
						mine: false,
						at: revision,
						order: revision,
						state: revision === 1 ? "present" : "edited",
						previewUrls: [],
						attachments: [],
					};
					return [BigInt(revision), ...archiveRecordRow(record)];
				};
				if (after === 0) {
					const records = Array.from(
						{ length: MAX_ARCHIVE_READ },
						(_, offset) => row(offset + 1, offset === 0 ? "revised" : `other-${offset}`, "old"),
					);
					return [BigInt(MAX_ARCHIVE_READ), true, records];
				}
				return [BigInt(MAX_ARCHIVE_READ + 1), false, [
					row(MAX_ARCHIVE_READ + 1, "revised", "new"),
				]];
			});
			void session.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port), roomsHost(undefined, "interop"));
	try {
		assert(session.profile.captpVersion === "v1_0", "archive session did not settle the interop floor");
		assert(session.profile.codec === "syrup", "archive session did not settle Syrup");
		// A browser-owned archive is hosted on the same concrete session its
		// application calls. There is no inbound remote turn in that case, so the
		// spawned root must carry the session on which its returned facet belongs.
		const ownedArchive = spawnArchive(session, new MemoryArchiveBackend());
		const ownedFacet = await narrowArchive(session, ownedArchive, ALL_ARCHIVE_RECORDS);
		session.release(ownedFacet);
		session.release(ownedArchive);
		const archive = await session.fetch("archive");
		const record: ArchiveLine = {
			kind: "line",
			source: "floor-recorder",
			generation: "floor-conversation",
			id: "floor-line",
			conversationKind: "direct",
			directory: loopbackTcpDesignator(server.port),
			conversation: "alice",
			from: "alice",
			text: "kept over the floor",
			mine: false,
			at: 1,
			order: 1,
			state: "present",
			previewUrls: [],
			attachments: [],
		};
		assert(await putArchive(session, archive, record) === 1, "archive put did not allocate its first revision");
		const page = await readArchive(session, archive, {
			...ALL_ARCHIVE_RECORDS,
			source: record.source,
			generation: record.generation,
		});
		assert(page.records.length === 1, "archive read did not return its floor-written line");
		const returned = page.records[0]?.record;
		assert(returned?.source === record.source, "archive read changed the recorder source");
		assert(returned?.generation === record.generation, "archive read changed the conversation generation");

		const bytes = new TextEncoder().encode("kept blob bytes");
		const fileRecord: ArchiveLine = {
			...record,
			id: "floor-file",
			text: "file",
			attachments: [{
				name: "floor.txt",
				mime: "text/plain",
				size: bytes.length,
				width: 0,
				height: 0,
				blob: null,
			}],
		};
		await putArchiveWithAttachments(session, archive, fileRecord, [{
			name: "floor.txt",
			mime: "text/plain",
			bytes,
		}]);
		const filePage = await readArchive(session, archive, {
			...ALL_ARCHIVE_RECORDS,
			source: fileRecord.source,
			generation: fileRecord.generation,
		});
		const storedFile = filePage.records.find((entry) => entry.record.id === fileRecord.id)?.record;
		assert(storedFile?.kind === "line", "archive blob line did not return");
		const archivedFile = await readArchiveAttachment(session, archive, storedFile, 0);
		assert(archivedFile !== null, "archive did not return its retained blob capability");
		assert(
			new TextDecoder().decode(await fetchBlob(session, archivedFile)) === "kept blob bytes",
			"archive blob bytes changed over the floor",
		);
		session.release(archivedFile.blob);
		const originalFile = await readArchiveAttachment(session, archive, storedFile, 0);
		assert(originalFile !== null, "archive did not mint a reader for the original file revision");

		const elsewhere = { ...record, id: "elsewhere", directory: "ocapn://elsewhere.example" };
		await putArchive(session, archive, elsewhere);
		const elsewhereBytes = new TextEncoder().encode("foreign blob bytes");
		const elsewhereFile = {
			...fileRecord,
			id: "elsewhere-file",
			directory: "ocapn://elsewhere.example",
			attachments: [{
				name: "floor.txt",
				mime: "text/plain",
				size: elsewhereBytes.length,
				width: 0,
				height: 0,
				blob: null,
			}],
		};
		await putArchiveWithAttachments(session, archive, elsewhereFile, [{
			name: "floor.txt",
			mime: "text/plain",
			bytes: elsewhereBytes,
		}]);
		const localRead = await narrowArchive(session, archive, {
			...ALL_ARCHIVE_RECORDS,
			directory: record.directory,
		}, "read");
		const localPage = await readArchive(session, localRead);
		assert(localPage.records.length === 2, "a directory facet disclosed another directory");
		assert(
			localPage.records.some((entry) => entry.record.id === record.id) &&
				localPage.records.some((entry) => entry.record.id === fileRecord.id),
			"a directory facet lost one of its permitted lines",
		);
		const all = await readArchive(session, archive);
		const storedElsewhere = all.records.find((entry) => entry.record.id === elsewhereFile.id)?.record;
		assert(storedElsewhere?.kind === "line", "archive lost the foreign scoped file line");
		let blobRefusal = "";
		try {
			await readArchiveAttachment(session, localRead, storedElsewhere, 0);
		} catch (error) {
			blobRefusal = error instanceof Error ? error.message : String(error);
		}
		assert(blobRefusal.includes("does not permit"), "a scoped archive facet disclosed another directory's blob");
		const localDigest = storedFile.kind === "line" ? storedFile.attachments[0]?.blob : null;
		assert(typeof localDigest === "string", "the scoped file line lost its digest");
		const hashed = await readArchiveBlob(session, localRead, localDigest);
		assert(
			new TextDecoder().decode(
				await fetchBlob(session, {
					name: "floor.txt",
					mime: "text/plain",
					size: bytes.length,
					width: 0,
					height: 0,
					blob: hashed,
				}),
			) === "kept blob bytes",
			"blob(digest) did not return the scoped facet's bytes",
		);
		session.release(hashed);
		await putArchiveWithAttachments(session, archive, {
			...fileRecord,
			state: "edited",
			attachments: [{ ...fileRecord.attachments[0], name: "renamed.txt" }],
		}, [{ name: "renamed.txt", mime: "text/plain", bytes }]);
		assert(
			new TextDecoder().decode(await fetchBlob(session, originalFile)) === "kept blob bytes",
			"a metadata-only revision revoked unchanged content bytes",
		);

		// A file capability is content authority, not a live coordinate lookup.
		// Replacing the line's file must make an already-minted reader refuse;
		// serving the replacement bytes under the original digest would retarget
		// a capability the holder already received.
		const replacementBytes = new Uint8Array(bytes.length).fill(0x78);
		await putArchiveWithAttachments(session, archive, { ...fileRecord, state: "edited" }, [{
			name: "floor.txt",
			mime: "text/plain",
			bytes: replacementBytes,
		}]);
		let replacedRead = "";
		try {
			await fetchBlob(session, originalFile);
		} catch (error) {
			replacedRead = error instanceof Error ? error.message : String(error);
		} finally {
			session.release(originalFile.blob);
		}
		assert(
			replacedRead.includes("unavailable through this facet"),
			"an archived-file capability retargeted to replacement bytes",
		);

		const foreignDigest = storedElsewhere.attachments[0]?.blob;
		assert(typeof foreignDigest === "string", "the foreign file line lost its digest");
		blobRefusal = "";
		try {
			await readArchiveBlob(session, localRead, foreignDigest);
		} catch (error) {
			blobRefusal = error instanceof Error ? error.message : String(error);
		}
		assert(
			blobRefusal.includes("unavailable through this facet"),
			"blob(digest) looked up a digest outside the held facet",
		);
		let refused = "";
		try {
			await putArchive(session, localRead, { ...record, id: "read-only-write" });
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("read-only"), "a read-only archive facet accepted a write");

		const localWriter = await narrowArchive(session, archive, {
			...ALL_ARCHIVE_RECORDS,
			directory: record.directory,
		}, "read-write");
		await putArchive(session, localWriter, { ...record, id: "local-write", text: "written through a facet" });
		refused = "";
		try {
			await putArchive(session, localWriter, { ...elsewhere, id: "escaped-write" });
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("does not permit"), "a scoped writer escaped its directory");

		const conversationRead = await narrowArchive(session, localWriter, {
			...ALL_ARCHIVE_RECORDS,
			conversation: record.conversation,
		}, "read");
		refused = "";
		try {
			await narrowArchive(session, conversationRead, ALL_ARCHIVE_RECORDS, "read-write");
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("cannot be widened"), "a nested read facet widened back to write authority");

		const endless = await session.fetch("endlessArchive");
		refused = "";
		try {
			await readAllArchiveRecords(session, endless);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("record ceiling"), "a peer could make a whole-archive walk allocate without limit");
		const revising = await session.fetch("revisingArchive");
		const revised = await readAllArchiveRecords(session, revising);
		assert(revised.length === MAX_ARCHIVE_READ, "a revision repeated its logical archive record");
		const updated = revised.find((record) => record.id === "revised");
		assert(
			updated?.kind === "line" && updated.text === "new",
			"a later archive revision did not replace the earlier page's record",
		);

		const quotaSession = await dial(loopbackTcpDesignator(server.port), roomsHost(undefined, "interop"));
		try {
			const quotaArchive = await quotaSession.fetch("archive");
			for (let minted = 0; minted < MAX_ARCHIVE_FACETS_PER_SESSION; minted += 1) {
				const facet = await narrowArchive(quotaSession, quotaArchive, ALL_ARCHIVE_RECORDS);
				quotaSession.release(facet);
			}
			refused = "";
			try {
				await narrowArchive(quotaSession, quotaArchive, ALL_ARCHIVE_RECORDS);
			} catch (error) {
				refused = error instanceof Error ? error.message : String(error);
			}
			assert(refused.includes("mint ceiling"), "facet churn escaped its per-session mint ceiling");
		} finally {
			await quotaSession.close().catch(() => {});
		}
	} finally {
		await session.close().catch(() => {});
		(server as unknown as { close?: () => void }).close?.();
		await Promise.allSettled([serving]);
	}
});
