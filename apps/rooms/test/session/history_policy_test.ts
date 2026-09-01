import { directEmitter } from "../../session/directory_directs.ts";
import { makeRoomCallbacks } from "../../session/room_reconcile.ts";
import { DurableRoomsArchive } from "../../session/archive.ts";
import { DurableRoomsRuntime } from "../../session/runtime.ts";
import { RoomsRuntimeIssues } from "../../session/issues.ts";
import type { LiveDirectory } from "../../session/live.ts";
import type { Message } from "../../lib/room/client.ts";
import { ALL_ARCHIVE_RECORDS, type ErasableArchiveBackend, MemoryArchiveBackend } from "../../lib/archive/protocol.ts";
import type { Runtime } from "@pancake/runtime";
import { assertEquals } from "../assert.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";

Deno.test("runtime issues remain committed when one observer fails", () => {
	const issues = new RoomsRuntimeIssues();
	let observed = 0;
	issues.onChange(() => {
		throw new Error("observer refused");
	});
	issues.onChange(() => observed += 1);
	const originalError = console.error;
	const errors: string[] = [];
	console.error = (value) => errors.push(String(value));
	try {
		assertEquals(issues.set("runtime", "reconciliation refused"), true);
	} finally {
		console.error = originalError;
	}
	assertEquals(issues.list(), [{ subject: "runtime", reason: "reconciliation refused" }]);
	assertEquals(observed, 1);
	assertEquals(errors[0]?.includes("observer refused"), true);
});

Deno.test("room and direct recording read the current shared history policy", () => {
	const kept: boolean[] = [];
	const archive = {
		recordMessage: (input: { keep: boolean }) => {
			kept.push(input.keep);
			return null;
		},
	} as unknown as DurableRoomsArchive;
	const held = { id: "directory", nick: "ada", directs: new Map() } as unknown as LiveDirectory;
	const message: Message = { from: "bo", text: "line", system: false, attachments: [] };
	let keep = false;
	const emitDirect = directEmitter(archive, new Set(), () => keep);
	const callbacks = makeRoomCallbacks({
		held,
		archive,
		keepHistory: () => keep,
		receivers: new Set(),
		release: () => {},
		retry: () => {},
		notifyView: () => {},
		setIssue: () => false,
		cleanup: async (work) => {
			await work;
		},
		reconcileAuthority: async () => {},
		reconcileAcquisition: async () => {},
		reconcileReconnect: async () => {},
		bridgeSecrets: () => null,
		current: () => true,
	});
	callbacks.message("room", message, false, [], "generation");
	emitDirect(held, "direct", "generation", message, false);
	keep = true;
	callbacks.message("room", message, false, [], "generation");
	emitDirect(held, "direct", "generation", message, false);
	assertEquals(kept, [false, false, true, true]);
});

Deno.test("a file-only room line records durable bytes without retaining its live capability", async () => {
	const backend = new MemoryArchiveBackend();
	const archive = new DurableRoomsArchive({} as Runtime, "session-source", () => {}, backend);
	const bytes = new TextEncoder().encode("diagram bytes");
	archive.recordMessage({
		keep: true,
		generation: "room-generation",
		kind: "room",
		directory: "directory",
		conversation: "room",
		nick: "ada",
		message: {
			from: "ada",
			text: "",
			system: false,
			lineId: 1,
			change: "said",
			attachments: [{
				name: "diagram.png",
				mime: "image/png",
				size: 80,
				blob: {} as import("@pancake/runtime").Ref,
				width: 4,
				height: 2,
			}],
		},
		files: [{
			name: "diagram.png",
			mime: "image/png",
			size: bytes.length,
			width: 4,
			height: 2,
			read: (offset, length) => Promise.resolve(bytes.subarray(offset, offset + length)),
		}],
	});
	const record = (await archive.read("room", "directory", "room"))[0];
	assertEquals(record?.kind === "line" ? record.attachments : [], [
		{
			name: "diagram.png",
			mime: "image/png",
			size: bytes.length,
			width: 4,
			height: 2,
			blob: record?.kind === "line" ? record.attachments[0].blob : null,
		},
	]);
	await archive.close();
});

Deno.test("an archive write owns the file materialization admitted with its line", async () => {
	const backend = new MemoryArchiveBackend();
	const archive = new DurableRoomsArchive({} as Runtime, "session-source", () => {}, backend);
	const bytes = new TextEncoder().encode("retained after live custody");
	const admitted = Promise.withResolvers<Uint8Array>();
	archive.recordMessage({
		keep: true,
		generation: "direct-generation",
		kind: "direct",
		directory: "directory",
		conversation: "direct",
		nick: "ada",
		message: { from: "bo", text: "file", system: false, lineId: 1, change: "said", attachments: [] },
		files: [{
			name: "proof.txt",
			mime: "text/plain",
			size: bytes.length,
			width: 0,
			height: 0,
			materialize: () => admitted.promise,
			read: () => Promise.reject(new Error("live custody was already retired")),
		}],
	});
	admitted.resolve(bytes);
	const record = (await archive.read("direct", "directory", "direct"))[0];
	if (record?.kind !== "line") throw new Error("the admitted direct file was not archived");
	const attachment = await archive.attachment(record, 0);
	if (attachment == null) throw new Error("the archive did not retain the admitted file bytes");
	assertEquals(await attachment.read(0, bytes.length), bytes);
	attachment.release();
	await archive.close();
});

Deno.test("a durable session can erase its owned archive without rewinding its cursor", async () => {
	const backend = new MemoryArchiveBackend();
	const archive = new DurableRoomsArchive({} as Runtime, "session-source", () => {}, backend);
	archive.record({
		kind: "line",
		generation: "generation",
		conversationKind: "room",
		directory: "directory",
		conversation: "room",
		from: "ada",
		text: "retained",
		mine: true,
		at: 1,
		state: "present",
		attachments: [],
	});
	const clearing = archive.clearLocal();
	archive.record({
		kind: "line",
		generation: "generation",
		conversationKind: "room",
		directory: "directory",
		conversation: "room",
		from: "ada",
		text: "after clear",
		mine: true,
		at: 2,
		state: "present",
		attachments: [],
	});
	await clearing;
	await archive.read("room", "directory", "room");
	const cleared = await backend.read(ALL_ARCHIVE_RECORDS, 0, 10);
	assertEquals(cleared.records.map((entry) => entry.record.kind === "line" ? entry.record.text : ""), [
		"after clear",
	]);
	assertEquals(cleared.next, 2);
});

Deno.test("a refused session-owned archive erase remains required until reconciliation retries it", async () => {
	const memory = new MemoryArchiveBackend();
	let attempts = 0;
	const backend: ErasableArchiveBackend = {
		put: (record) => memory.put(record),
		read: (filter, after, limit) => memory.read(filter, after, limit),
		clear: () => {
			attempts += 1;
			if (attempts === 1) throw new Error("storage refused clear");
			memory.clear();
		},
	};
	const archive = new DurableRoomsArchive({} as Runtime, "session-source", () => {}, backend);
	archive.record({
		kind: "line",
		generation: "generation",
		conversationKind: "room",
		directory: "directory",
		conversation: "room",
		from: "ada",
		text: "retained",
		mine: true,
		at: 1,
		state: "present",
		attachments: [],
	});
	await archive.clearLocal().catch(() => {});
	await archive.settleLocalErase();
	assertEquals(attempts, 2);
	assertEquals((await memory.read(ALL_ARCHIVE_RECORDS, 0, 10)).records, []);
});

Deno.test("runtime reconciliation exposes failure and clears it after a successful retry", async () => {
	const memory = new MemoryArchiveBackend();
	let refused = true;
	const backend: ErasableArchiveBackend = {
		put: (record) => memory.put(record),
		read: (filter, after, limit) => memory.read(filter, after, limit),
		clear: () => {
			if (refused) throw new Error("storage refused reconciliation");
			return memory.clear();
		},
	};
	const runtime = new DurableRoomsRuntime(
		{ close: () => Promise.resolve() } as Runtime,
		"session-source",
		async () => {},
		backend,
	);
	try {
		const checkpoint = { ...emptyRoomsSessionState(), keepHistory: false };
		let failed = false;
		try {
			await runtime.reconcile(checkpoint, "presentation");
		} catch {
			failed = true;
		}
		assertEquals(failed, true);
		await runtime.settled();
		assertEquals(
			runtime.issues().find((issue) => issue.subject === "runtime")?.reason,
			"storage refused reconciliation",
		);

		refused = false;
		await runtime.reconcile(checkpoint, "realization");
		await runtime.settled();
		assertEquals(runtime.issues().some((issue) => issue.subject === "runtime"), false);
	} finally {
		await runtime.close();
	}
});
