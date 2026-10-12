// The Rooms member-owned archive contract (ADR-0129), exercised without a
// database or network. The behavior is the wire edge, so these calls prove the
// same validation and passable rows a tab export or standalone peer serves.
// MemoryArchiveBackend proves the storage/revision contract behind both.

import type { Argument, Behavior } from "@glowcap/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	ARCHIVE_PUT,
	ARCHIVE_READ,
	ARCHIVE_SHARE,
	archiveBehavior,
	type ArchiveFilter,
	archiveFilterRow,
	ArchiveIndex,
	type ArchiveLine,
	archiveRecordRow,
	MAX_ARCHIVE_READ,
	MemoryArchiveBackend,
	parseArchiveRecord,
} from "../../lib/archive/protocol.ts";
import { MAX_LINE } from "../../lib/limits.ts";
import { lineAttachmentAddress } from "../../lib/archive/blobs.ts";
import { assertEquals } from "../assert.ts";

function line(fields: Partial<ArchiveLine> = {}): ArchiveLine {
	return {
		kind: "line",
		source: "source-a",
		generation: "generation-a",
		id: "line-a",
		conversationKind: "direct",
		directory: "ocapn://directory.example",
		conversation: "alice",
		from: "alice",
		text: "hello",
		mine: false,
		at: 100,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [],
		...fields,
	};
}

async function call(behavior: Behavior, verb: string, args: Argument[]): Promise<unknown> {
	return await behavior(verb, args);
}

async function refused(action: () => Promise<unknown>): Promise<string> {
	try {
		await action();
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

function pageOf(raw: unknown): { next: number; more: boolean; records: ArchiveLine[] } {
	if (!Array.isArray(raw) || typeof raw[0] !== "bigint" || typeof raw[1] !== "boolean" || !Array.isArray(raw[2])) {
		throw new Error("archive test received a malformed page");
	}
	return {
		next: Number(raw[0]),
		more: raw[1],
		records: raw[2].map((entry) => {
			if (!Array.isArray(entry) || typeof entry[0] !== "bigint") throw new Error("malformed revised record");
			const record = parseArchiveRecord(entry.slice(1));
			if (record.kind !== "line") throw new Error("expected an archive line");
			return record;
		}),
	};
}

Deno.test("archive put replaces one key and a resumed read sees the greater revision", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	assertEquals(String(await call(behavior, ARCHIVE_PUT, [archiveRecordRow(line())])), "1");
	const first = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 0n, 10n]),
	);
	assertEquals(first.next, 1);
	assertEquals(first.records.map((record) => record.text), ["hello"]);

	assertEquals(
		String(
			await call(behavior, ARCHIVE_PUT, [
				archiveRecordRow(line({ text: "corrected", state: "edited", at: 200, order: 200 })),
			]),
		),
		"2",
	);
	const resumed = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 1n, 10n]),
	);
	assertEquals(resumed.records.map((record) => [record.id, record.text, record.state]), [
		["line-a", "corrected", "edited"],
	]);
	const whole = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 0n, 10n]),
	);
	assertEquals(whole.records.length, 1, "replacement retained one current record");
	assertEquals(whole.records[0]?.at, 100, "editing moved the line through archive history");
	assertEquals(whole.records[0]?.order, 1, "editing changed the line's conversation order");
});

Deno.test("withdrawal erases archived plaintext rather than appending a tombstone beside it", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	await call(behavior, ARCHIVE_PUT, [archiveRecordRow(line({ text: "take this back" }))]);
	await call(behavior, ARCHIVE_PUT, [archiveRecordRow(line({ text: "", state: "withdrawn" }))]);
	const page = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 0n, 10n]),
	);
	assertEquals(page.records.map((record) => [record.text, record.state]), [["", "withdrawn"]]);
	const why = await refused(() =>
		call(
			behavior,
			ARCHIVE_PUT,
			[archiveRecordRow(line({ text: "still retained", state: "withdrawn" }))],
		)
	);
	assertEquals(why, "a withdrawn archive line must erase its text");
	const metadataWhy = await refused(() =>
		call(
			behavior,
			ARCHIVE_PUT,
			[archiveRecordRow(line({
				text: "",
				state: "withdrawn",
				attachments: [{ name: "gone.png", mime: "image/png", size: 10, width: 4, height: 2, blob: null }],
			}))],
		)
	);
	assertEquals(metadataWhy, "a withdrawn archive line must erase its attachment metadata");
});

Deno.test("archive lines retain bounded file metadata without claiming blob custody", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	const attachments = [{ name: "diagram.png", mime: "image/png", size: 80, width: 4, height: 2, blob: null }];
	await call(behavior, ARCHIVE_PUT, [archiveRecordRow(line({ text: "diagram", attachments }))]);
	const page = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 0n, 10n]),
	);
	assertEquals(page.records[0]?.attachments, attachments);
	const malformed = archiveRecordRow(line());
	malformed[13] = Array.from({ length: 9 }, () => ["x", "text/plain", 1n, 0n, 0n, null]);
	assertEquals(
		await refused(() => call(behavior, ARCHIVE_PUT, [malformed])),
		"an archive line may carry at most 8 attachment records",
	);
	malformed[13] = Array.from({ length: 5 }, (_, at) => [
		`file-${at}`,
		"application/octet-stream",
		16n * 1024n * 1024n,
		0n,
		0n,
		null,
	]);
	assertEquals(
		await refused(() => call(behavior, ARCHIVE_PUT, [malformed])),
		"archive line attachments may total at most 67108864 bytes",
	);
});

Deno.test("memory archive blob custody survives edits and leaves with withdrawal", async () => {
	const backend = new MemoryArchiveBackend();
	const bytes = new TextEncoder().encode("archive bytes");
	const metadata = {
		name: "notes.txt",
		mime: "text/plain",
		size: bytes.length,
		width: 0,
		height: 0,
		blob: null,
	};
	const record = line({ attachments: [metadata] });
	await backend.putWithAttachments(record, [{
		...metadata,
		read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
	}]);
	const stored = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
	if (stored?.kind !== "line") throw new Error("blob test did not retain its line");
	assertEquals(stored.attachments[0].blob?.length, 64);
	let attachment = await backend.readAttachment(lineAttachmentAddress(stored, 0));
	assertEquals(new TextDecoder().decode(await attachment!.attachment.read(0, bytes.length)), "archive bytes");
	await backend.put({ ...record, text: "edited", state: "edited" });
	const edited = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
	assertEquals(edited?.kind === "line" ? edited.attachments[0].blob : null, stored.attachments[0].blob);
	await backend.put({ ...record, text: "", state: "withdrawn", attachments: [] });
	attachment = await backend.readAttachment(lineAttachmentAddress(stored, 0));
	assertEquals(attachment, null);
});

Deno.test("source, generation, and conversation kind remain independent filter dimensions", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	for (
		const record of [
			line(),
			line({ id: "line-b", source: "source-b" }),
			line({ id: "line-c", generation: "generation-b" }),
			line({ id: "line-d", conversationKind: "room" }),
		]
	) {
		await call(behavior, ARCHIVE_PUT, [archiveRecordRow(record)]);
	}
	const filter: ArchiveFilter = {
		...ALL_ARCHIVE_RECORDS,
		source: "source-a",
		generation: "generation-a",
		kind: "line",
		conversationKind: "direct",
	};
	const page = pageOf(await call(behavior, ARCHIVE_READ, [archiveFilterRow(filter), 0n, 10n]));
	assertEquals(page.records.map((record) => record.id), ["line-a"]);
});

Deno.test("archive reads page at the protocol ceiling and resume without overlap", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	for (let at = 0; at < MAX_ARCHIVE_READ + 2; at += 1) {
		await call(behavior, ARCHIVE_PUT, [archiveRecordRow(line({ id: `line-${at}`, at }))]);
	}
	const first = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), 0n, 100_000n]),
	);
	assertEquals(first.records.length, MAX_ARCHIVE_READ);
	assertEquals(first.more, true);
	const second = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), BigInt(first.next), 100_000n]),
	);
	assertEquals(second.records.length, 2);
	assertEquals(second.more, false);
	assertEquals(second.records[0].id === first.records.at(-1)?.id, false, "resumed page repeated its cursor row");
});

Deno.test("archive capacity evicts the least recently revised record", async () => {
	const backend = new MemoryArchiveBackend(2);
	await backend.put(line({ id: "old" }));
	await backend.put(line({ id: "kept" }));
	await backend.put(line({ id: "new" }));
	const page = await backend.read(ALL_ARCHIVE_RECORDS, 0, 10);
	assertEquals(page.records.map((entry) => entry.record.id), ["kept", "new"]);
});

Deno.test("the archive index retains a validated record by owned transfer", () => {
	const index = new ArchiveIndex();
	const record = line({ id: "transferred" });
	index.apply(1, record);
	assertEquals(index.snapshot()[0].record === record, true, "the policy index copied a wire-path record");
});

Deno.test("clearing content does not strand a reader behind a rewound cursor", async () => {
	const backend = new MemoryArchiveBackend();
	assertEquals(await backend.put(line({ id: "before" })), 1);
	backend.clear();
	assertEquals(await backend.put(line({ id: "after" })), 2);
	const page = await backend.read(ALL_ARCHIVE_RECORDS, 1, 10);
	assertEquals(page.records.map((entry) => entry.record.id), ["after"]);
});

Deno.test("archive behavior refuses malformed and oversized peer input before storage", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	assertEquals(
		await refused(() => call(behavior, ARCHIVE_PUT, [["line"]])),
		"an archive line row has the wrong shape",
	);
	assertEquals(
		await refused(() => call(behavior, ARCHIVE_PUT, [archiveRecordRow(line({ text: "x".repeat(MAX_LINE + 1) }))])),
		"archive line is too long",
	);
	assertEquals(
		await refused(() => call(behavior, ARCHIVE_READ, [archiveFilterRow(ALL_ARCHIVE_RECORDS), -1n, 1n])),
		"archive read revision must be a non-negative safe integer",
	);
});

Deno.test("digest is an exact filter dimension and does not match standings", async () => {
	const backend = new MemoryArchiveBackend();
	const bytesA = new TextEncoder().encode("a");
	const bytesB = new TextEncoder().encode("b");
	const metaA = { name: "a.txt", mime: "text/plain", size: bytesA.length, width: 0, height: 0, blob: null };
	const metaB = { name: "b.txt", mime: "text/plain", size: bytesB.length, width: 0, height: 0, blob: null };
	await backend.putWithAttachments(line({ attachments: [metaA] }), [{
		...metaA,
		read: (offset, length) => Promise.resolve(bytesA.subarray(offset, offset + length)),
	}]);
	await backend.putWithAttachments(line({ id: "other", attachments: [metaB] }), [{
		...metaB,
		read: (offset, length) => Promise.resolve(bytesB.subarray(offset, offset + length)),
	}]);
	const stored = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records;
	const first = stored.find((entry) => entry.record.kind === "line" && entry.record.id === "line-a")?.record;
	if (first?.kind !== "line") throw new Error("digest test did not retain its line");
	const hash = first.attachments[0]?.blob;
	if (hash == null) throw new Error("digest test did not mint a content digest");
	const behavior = archiveBehavior(backend);
	const page = pageOf(
		await call(behavior, ARCHIVE_READ, [archiveFilterRow({ ...ALL_ARCHIVE_RECORDS, digest: hash }), 0n, 10n]),
	);
	assertEquals(page.records.map((record) => record.id), ["line-a"]);
	const empty = pageOf(
		await call(
			behavior,
			ARCHIVE_READ,
			[archiveFilterRow({ ...ALL_ARCHIVE_RECORDS, kind: "standing", digest: hash }), 0n, 10n],
		),
	);
	assertEquals(empty.records, []);
});

Deno.test("a tab archive cannot mint a durable share", async () => {
	const behavior = archiveBehavior(new MemoryArchiveBackend());
	assertEquals(
		await refused(() =>
			call(behavior, ARCHIVE_SHARE, [
				"00000000-0000-4000-8000-000000000001",
				"Room log",
				archiveFilterRow(ALL_ARCHIVE_RECORDS),
			])
		),
		"this archive cannot mint a durable share",
	);
});
