import type { Ref, Session } from "@pancake/runtime";
import { type ArchiveLine, archiveRecordRow, MAX_ARCHIVE_CONVERSATION_BYTES } from "../lib/archive.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../lib/limits.ts";
import { DurableRoomsArchiveShares } from "../session/archive_shares.ts";
import type { DurableRoomsArchive } from "../session/archive.ts";
import type { LiveDirectory } from "../session/live.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

function directory(): LiveDirectory {
	return {
		id: "directory",
		nick: "ada",
		directConversationByRegistration: new Map([[registrationId(1), "direct-conversation"]]),
	} as unknown as LiveDirectory;
}

function owner(record: ArchiveLine, released: Ref[], filters: unknown[][] = []): Session {
	return {
		release: (ref: Ref) => released.push(ref),
		onClose: () => () => {},
		send: (_target: Ref, _verb: string, args: unknown[]) => {
			filters.push(args);
			return Promise.resolve([1n, false, [[1n, ...archiveRecordRow(record)]]]);
		},
	} as unknown as Session;
}

const sharedLine: ArchiveLine = {
	kind: "line",
	source: "sender-archive",
	generation: "sender-generation",
	id: "sender-line",
	conversationKind: "direct",
	directory: "directory",
	conversation: "sender-conversation",
	from: "bo",
	text: "earlier from bo",
	mine: true,
	at: 1,
	state: "present",
	attachments: [],
};

Deno.test("a scoped archive share projects metadata, reads once, and releases its capability", async () => {
	const released: Ref[] = [];
	const filters: unknown[][] = [];
	const session = owner(sharedLine, released, filters);
	const archive = {} as DurableRoomsArchive;
	const changed: number[] = [];
	const shares = new DurableRoomsArchiveShares(archive, () => changed.push(1));
	const capability = {} as Ref;
	shares.receive(directory(), session, "directory", "sender-conversation", capability, "bo", registrationId(1));
	assertEquals(shares.list(), [{
		id: "archive-share:1",
		directory: "directory",
		conversationId: "direct-conversation",
		from: "bo",
		status: "offered",
		error: "",
	}]);
	const result = await shares.read("archive-share:1", 0);
	assertEquals((filters[0]?.[0] as unknown[] | undefined)?.[5], "sender-conversation");
	assertEquals(result.page.records.map((entry) => entry.record), [sharedLine]);
	assertEquals(result.view.conversationId, "direct-conversation");
	assertEquals(shares.list(), []);
	assertEquals(released, [capability]);
	assertEquals(changed.length, 3);
});

Deno.test("mis-scoped and over-limit archive shares are refused and released", () => {
	const released: Ref[] = [];
	const session = owner(sharedLine, released);
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	const wrong = {} as Ref;
	let refused = false;
	try {
		shares.receive(
			directory(),
			session,
			"other-directory",
			"sender-conversation",
			wrong,
			"bo",
			registrationId(1),
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [wrong]);
	const malformed = {} as Ref;
	refused = false;
	try {
		shares.receive(
			directory(),
			session,
			"directory",
			"x".repeat(MAX_ARCHIVE_CONVERSATION_BYTES + 1),
			malformed,
			"bo",
			registrationId(1),
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.at(-1), malformed);
	for (let at = 0; at < MAX_PENDING_ARCHIVE_SHARES; at += 1) {
		shares.receive(
			directory(),
			session,
			"directory",
			"sender-conversation",
			{} as Ref,
			"bo",
			registrationId(1),
		);
	}
	const extra = {} as Ref;
	refused = false;
	try {
		shares.receive(
			directory(),
			session,
			"directory",
			"sender-conversation",
			extra,
			"bo",
			registrationId(1),
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.at(-1), extra);
	shares.close();
	assertEquals(released.length, MAX_PENDING_ARCHIVE_SHARES + 3);
});

Deno.test("an archive share remains retryable after an unexpected release refusal", () => {
	let refuseRelease = true;
	const released: Ref[] = [];
	const session = {
		...owner(sharedLine, released),
		release: (ref: Ref) => {
			if (refuseRelease) throw new Error("release refused");
			released.push(ref);
		},
	} as unknown as Session;
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	const capability = {} as Ref;
	shares.receive(directory(), session, "directory", "sender-conversation", capability, "bo", registrationId(1));
	shares.drop("archive-share:1");
	assertEquals(shares.list()[0]?.status, "unavailable");
	assertEquals(shares.list()[0]?.error, "declined archive share: release refused");

	refuseRelease = false;
	shares.drop("archive-share:1");
	assertEquals(shares.list(), []);
	assertEquals(released, [capability]);
});

Deno.test("archive share disposal survives close-listener cleanup refusal", () => {
	const released: Ref[] = [];
	const session = {
		...owner(sharedLine, released),
		onClose: () => () => {
			throw new Error("close listener refused");
		},
	} as unknown as Session;
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	const capability = {} as Ref;
	shares.receive(directory(), session, "directory", "sender-conversation", capability, "bo", registrationId(1));
	const originalError = console.error;
	const errors: string[] = [];
	console.error = (message) => errors.push(String(message));
	try {
		shares.drop("archive-share:1");
	} finally {
		console.error = originalError;
	}
	assertEquals(shares.list(), []);
	assertEquals(released, [capability]);
	assertEquals(errors.some((message) => message.includes("close listener refused")), true);
});
