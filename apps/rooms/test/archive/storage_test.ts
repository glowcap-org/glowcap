// Durable archive storage: restart, crash-tail recovery, corruption refusal,
// and the resource ceilings that make a held archive capability safe to serve.

import { ALL_ARCHIVE_RECORDS, type ArchiveLine } from "../../lib/archive/protocol.ts";
import { FileArchiveBackend } from "../../archive/storage.ts";
import { ArchivePeerState } from "../../archive/state.ts";
import { ArchiveDirectoryCustody } from "../../archive/file_io.ts";
import { assertEquals } from "../assert.ts";
import { lineAttachmentAddress } from "../../lib/archive/blobs.ts";

function line(id: string, text = id): ArchiveLine {
	return {
		kind: "line",
		source: "storage-source",
		generation: "storage-generation",
		id,
		conversationKind: "direct",
		directory: "ocapn://directory.example",
		conversation: "alice",
		from: "alice",
		text,
		mine: false,
		at: 1,
		state: "present",
		attachments: [],
	};
}

async function withState(run: (directory: string) => Promise<void>): Promise<void> {
	const directory = await Deno.makeTempDir();
	try {
		await run(directory);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
}

async function refused(run: () => Promise<unknown>): Promise<string> {
	try {
		await run();
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

Deno.test("file archive preserves records and its monotonic cursor across restart", () =>
	withState(async (directory) => {
		let backend = await FileArchiveBackend.open(directory, { capacity: 3, compactDelta: 2 });
		assertEquals(await backend.put(line("one")), 1);
		assertEquals(await backend.put(line("two")), 2);

		backend = await FileArchiveBackend.open(directory, { capacity: 3, compactDelta: 2 });
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records.map((entry) => entry.record.id), [
			"one",
			"two",
		]);
		assertEquals(await backend.put(line("one", "revised")), 3);

		backend = await FileArchiveBackend.open(directory, { capacity: 3, compactDelta: 2 });
		const resumed = await backend.read(ALL_ARCHIVE_RECORDS, 2, 10);
		assertEquals(resumed.next, 3);
		assertEquals(resumed.records.map((entry) => [entry.record.id, (entry.record as ArchiveLine).text]), [
			["one", "revised"],
		]);
	}));

Deno.test("file archive preserves attachment metadata without inventing blob bytes", () =>
	withState(async (directory) => {
		let backend = await FileArchiveBackend.open(directory);
		await backend.put({
			...line("file-line", "diagram"),
			attachments: [{ name: "diagram.png", mime: "image/png", size: 80, width: 4, height: 2, blob: null }],
		});
		backend = await FileArchiveBackend.open(directory);
		const record = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
		assertEquals(record?.kind === "line" ? record.attachments : [], [
			{ name: "diagram.png", mime: "image/png", size: 80, width: 4, height: 2, blob: null },
		]);
	}));

Deno.test("file archive streams blob bytes across restart and erases them with withdrawal", () =>
	withState(async (directory) => {
		const bytes = new TextEncoder().encode("durable archive bytes");
		const metadata = {
			name: "durable.txt",
			mime: "text/plain",
			size: bytes.length,
			width: 0,
			height: 0,
			blob: null,
		};
		const record = { ...line("durable-file"), attachments: [metadata] };
		let backend = await FileArchiveBackend.open(directory);
		await backend.putWithAttachments(record, [{
			...metadata,
			read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
		}]);
		backend = await FileArchiveBackend.open(directory);
		const stored = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
		if (stored?.kind !== "line") throw new Error("file blob test did not retain its line");
		const attachment = await backend.readAttachment(lineAttachmentAddress(stored, 0));
		assertEquals(
			new TextDecoder().decode(await attachment!.attachment.read(0, bytes.length)),
			"durable archive bytes",
		);
		await backend.put({ ...record, text: "", state: "withdrawn", attachments: [] });
		backend = await FileArchiveBackend.open(directory);
		assertEquals(await backend.readAttachment(lineAttachmentAddress(stored, 0)), null);
	}));

Deno.test("file archive refuses blob growth before committing the line that would name it", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory, { maxBlobBytes: 4 });
		const bytes = new TextEncoder().encode("12345");
		const metadata = {
			name: "large.txt",
			mime: "text/plain",
			size: bytes.length,
			width: 0,
			height: 0,
			blob: null,
		};
		assertEquals(
			await refused(() =>
				backend.putWithAttachments({ ...line("large"), attachments: [metadata] }, [{
					...metadata,
					read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
				}])
			),
			"archive blobs exceed their 4-byte ceiling",
		);
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records, []);
	}));

Deno.test("file archive blob custody applies bounded-record eviction in the same commit", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory, { capacity: 1, maxBlobBytes: 4 });
		const put = async (id: string, text: string) => {
			const bytes = new TextEncoder().encode(text);
			const metadata = {
				name: `${id}.txt`,
				mime: "text/plain",
				size: bytes.length,
				width: 0,
				height: 0,
				blob: null,
			};
			await backend.putWithAttachments({ ...line(id), attachments: [metadata] }, [{
				...metadata,
				read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
			}]);
		};
		await put("old", "old!");
		await put("new", "new!");
		const records = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records;
		assertEquals(records.map((entry) => entry.record.id), ["new"]);
		const retained = records[0]?.record;
		if (retained?.kind !== "line" || retained.attachments[0].blob == null) {
			throw new Error("eviction test did not retain the replacement blob");
		}
		const files: string[] = [];
		for await (const entry of Deno.readDir(`${directory}/blobs`)) {
			if (entry.isFile) files.push(entry.name);
		}
		assertEquals(files, [retained.attachments[0].blob]);
	}));

Deno.test("file archive refuses same-size blob corruption before serving bytes", () =>
	withState(async (directory) => {
		const bytes = new TextEncoder().encode("original");
		const metadata = {
			name: "integrity.txt",
			mime: "text/plain",
			size: bytes.length,
			width: 0,
			height: 0,
			blob: null,
		};
		let backend = await FileArchiveBackend.open(directory);
		await backend.putWithAttachments({ ...line("integrity"), attachments: [metadata] }, [{
			...metadata,
			read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
		}]);
		const stored = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
		if (stored?.kind !== "line" || stored.attachments[0].blob == null) {
			throw new Error("integrity test did not retain its blob digest");
		}
		await Deno.writeTextFile(`${directory}/blobs/${stored.attachments[0].blob}`, "tampered");
		backend = await FileArchiveBackend.open(directory);
		assertEquals(
			await refused(() => backend.readAttachment(lineAttachmentAddress(stored, 0))),
			"archive blob content does not match its digest",
		);
		await backend.putWithAttachments({ ...line("integrity"), attachments: [metadata] }, [{
			...metadata,
			read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
		}]);
		const repaired = (await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records[0]?.record;
		if (repaired?.kind !== "line") throw new Error("integrity repair lost its line");
		const attachment = await backend.readAttachment(lineAttachmentAddress(repaired, 0));
		assertEquals(new TextDecoder().decode(await attachment!.attachment.read(0, bytes.length)), "original");
	}));

Deno.test("file archive erasure preserves its monotonic cursor across restart", () =>
	withState(async (directory) => {
		let backend = await FileArchiveBackend.open(directory);
		await backend.put(line("before-clear"));
		await backend.clear();
		const cleared = await backend.read(ALL_ARCHIVE_RECORDS, 0, 10);
		assertEquals(cleared.records, []);
		assertEquals(cleared.next, 1);

		backend = await FileArchiveBackend.open(directory);
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).next, 1);
		assertEquals(await backend.put(line("after-clear")), 2);
	}));

Deno.test("file archive discards and compacts one torn final append", () =>
	withState(async (directory) => {
		let backend = await FileArchiveBackend.open(directory);
		await backend.put(line("whole"));
		await Deno.writeTextFile(`${directory}/archive.jsonl`, '{"revision":2,"record":', { append: true });

		backend = await FileArchiveBackend.open(directory);
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records.map((entry) => entry.record.id), [
			"whole",
		]);
		assertEquals(await backend.put(line("after-crash")), 2);
		assertEquals((await Deno.readTextFile(`${directory}/archive.jsonl`)).includes('"revision":2'), true);
	}));

Deno.test("file archive refuses corruption before its final crash boundary", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory);
		await backend.put(line("whole"));
		await Deno.writeTextFile(`${directory}/archive.jsonl`, "not-json\n", { append: true });
		assertEquals(
			await refused(() => FileArchiveBackend.open(directory)),
			"archive file has invalid JSON in record row",
		);
	}));

Deno.test("file archive refuses an obsolete header without rewriting it, naming both schemas", () =>
	withState(async (directory) => {
		await FileArchiveBackend.open(directory);
		const path = `${directory}/archive.jsonl`;
		const rows = (await Deno.readTextFile(path)).split("\n");
		const header = JSON.parse(rows[0]);
		const stamp = (archive: string, version: number) => {
			rows[0] = JSON.stringify({ ...header, archive, version });
			return rows.join("\n");
		};

		const newerVersion = stamp(header.archive, 2);
		await Deno.writeTextFile(path, newerVersion);
		const versionRefusal = await refused(() => FileArchiveBackend.open(directory));
		assertEquals(versionRefusal.includes(`written as ${header.archive} version 2`), true);
		assertEquals(versionRefusal.includes(`this build reads ${header.archive} version 1`), true);
		assertEquals(versionRefusal.includes("remove its state directory"), true);
		assertEquals(await Deno.readTextFile(path), newerVersion);

		const renamedFormat = stamp("renamed-rooms-member-archive", 1);
		await Deno.writeTextFile(path, renamedFormat);
		const formatRefusal = await refused(() => FileArchiveBackend.open(directory));
		assertEquals(formatRefusal.includes("written as renamed-rooms-member-archive version 1"), true);
		assertEquals(await Deno.readTextFile(path), renamedFormat);

		rows[0] = JSON.stringify({ ...header, revision: -1 });
		const malformed = rows.join("\n");
		await Deno.writeTextFile(path, malformed);
		assertEquals((await refused(() => FileArchiveBackend.open(directory))).includes("invalid header"), true);
		assertEquals(await Deno.readTextFile(path), malformed);
	}));

Deno.test("file archive bounds both resident records and uncompacted revision rows", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory, { capacity: 2, compactDelta: 2 });
		for (let at = 0; at < 12; at += 1) await backend.put(line(`line-${at}`));
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).records.map((entry) => entry.record.id), [
			"line-10",
			"line-11",
		]);
		const rows = (await Deno.readTextFile(`${directory}/archive.jsonl`)).trimEnd().split("\n");
		assertEquals(rows.length <= 1 + 2 + 2, true, "archive delta tail exceeded its compaction bound");
	}));

Deno.test("file archive refuses a record that cannot fit its configured disk ceiling", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory, { maxFileBytes: 256 });
		assertEquals(
			await refused(() => backend.put(line("too-large", "x".repeat(200)))),
			"archive file ceiling cannot hold the next record",
		);
		assertEquals((await backend.read(ALL_ARCHIVE_RECORDS, 0, 10)).next, 0);
	}));

Deno.test("file ceiling commits a fitting replacement without retaining its obsolete event", () =>
	withState(async (directory) => {
		const backend = await FileArchiveBackend.open(directory, { capacity: 1, maxFileBytes: 700 });
		await backend.put(line("same", "a".repeat(180)));
		assertEquals(await backend.put(line("same", "b".repeat(180))), 2);
		const page = await backend.read(ALL_ARCHIVE_RECORDS, 0, 10);
		assertEquals(page.records.map((entry) => (entry.record as ArchiveLine).text), ["b".repeat(180)]);
		assertEquals((await Deno.stat(`${directory}/archive.jsonl`)).size <= 700, true);
	}));

Deno.test("archive peer identity and publication entropy survive together and corrupt state refuses", () =>
	withState(async (directory) => {
		const first = await ArchivePeerState.open(directory);
		const second = await ArchivePeerState.open(directory);
		assertEquals([...second.identitySeed], [...first.identitySeed]);
		assertEquals([...second.archiveEntropy], [...first.archiveEntropy]);
		const exposedSeed = second.identitySeed;
		exposedSeed[0] ^= 0xff;
		assertEquals(exposedSeed[0] === second.identitySeed[0], false);
		const exposedEntropy = second.archiveEntropy;
		exposedEntropy[0] ^= 0xff;
		assertEquals(exposedEntropy[0] === second.archiveEntropy[0], false);
		await Deno.writeTextFile(`${directory}/peer.json`, "{}\n");
		assertEquals(
			await refused(() => ArchivePeerState.open(directory)),
			"archive peer state version undefined is not supported",
		);
	}));

Deno.test("archive state directory grants one live writer and releases on close", () =>
	withState(async (directory) => {
		const first = await ArchiveDirectoryCustody.acquire(directory);
		try {
			assertEquals(
				await refused(() => ArchiveDirectoryCustody.acquire(directory)),
				"archive state directory is already in use by another peer",
			);
		} finally {
			first.close();
		}
		const restarted = await ArchiveDirectoryCustody.acquire(directory);
		restarted.close();
	}));
