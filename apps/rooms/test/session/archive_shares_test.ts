import { DURABLE_SWISS_ENTROPY_BYTES, parseLocator, type Ref, type Session } from "@pancake/runtime";
import { type ArchiveLine, archiveRecordRow, MAX_ARCHIVE_CONVERSATION_BYTES } from "../../lib/archive/protocol.ts";
import { formatRoomsSturdyref } from "../../lib/locator.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../../lib/limits.ts";
import { DurableRoomsArchiveShares } from "../../session/archive_shares.ts";
import type { DurableRoomsArchive } from "../../session/archive.ts";
import type { LiveDirectory } from "../../session/live.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

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
	shares.receive(
		directory(),
		session,
		"directory",
		"direct",
		"sender-conversation",
		capability,
		"bo",
		registrationId(1),
	);
	assertEquals(shares.list(), [{
		id: "archive-share:1",
		directory: "directory",
		conversationId: "direct-conversation",
		from: "bo",
		status: "offered",
		error: "",
		kind: "direct",
		scopeConversation: "sender-conversation",
		custody: "live",
		sturdyref: "",
	}]);
	const result = await shares.read("archive-share:1", 0);
	assertEquals((filters[0]?.[0] as unknown[] | undefined)?.[5], "sender-conversation");
	assertEquals(result.page.records.map((entry) => entry.record), [sharedLine]);
	assertEquals(result.view.conversationId, "direct-conversation");
	assertEquals(shares.list(), []);
	assertEquals(released, [capability]);
	assertEquals(changed.length, 3);
});

Deno.test("a session room archive share keeps the carrying DM identity separate from the facet scope", () => {
	const released: Ref[] = [];
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	const capability = {} as Ref;
	shares.receive(
		directory(),
		owner(sharedLine, released),
		"directory",
		"room",
		"lobby",
		capability,
		"bo",
		registrationId(1),
	);
	assertEquals(shares.list(), [{
		id: "archive-share:1",
		directory: "directory",
		conversationId: "direct-conversation",
		from: "bo",
		status: "offered",
		error: "",
		kind: "room",
		scopeConversation: "lobby",
		custody: "live",
		sturdyref: "",
	}]);
	shares.drop("archive-share:1");
	assertEquals(released, [capability]);
});

Deno.test("a session standing archive share may name a room or the whole directory", () => {
	const released: Ref[] = [];
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	shares.receive(
		directory(),
		owner(sharedLine, released),
		"directory",
		"standing",
		"lobby",
		{} as Ref,
		"bo",
		registrationId(1),
	);
	shares.receive(
		directory(),
		owner(sharedLine, released),
		"directory",
		"standing",
		null,
		{} as Ref,
		"bo",
		registrationId(1),
	);
	assertEquals(shares.list().map((share) => [share.kind, share.scopeConversation]), [
		["standing", "lobby"],
		["standing", null],
	]);
	shares.close();
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
			"direct",
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
			"direct",
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
			"direct",
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
			"direct",
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
	shares.receive(
		directory(),
		session,
		"directory",
		"direct",
		"sender-conversation",
		capability,
		"bo",
		registrationId(1),
	);
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
	shares.receive(
		directory(),
		session,
		"directory",
		"direct",
		"sender-conversation",
		capability,
		"bo",
		registrationId(1),
	);
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

function shareSturdyref(): string {
	return formatRoomsSturdyref(
		parseLocator("ocapn://127.0.0.1%3A9000.tcp"),
		new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a),
	);
}

Deno.test("a session durable archive offer survives closing the carrying DM", () => {
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	shares.receiveOffer(
		directory(),
		"directory",
		"room",
		"lobby",
		shareSturdyref(),
		"bo",
		registrationId(1),
	);
	assertEquals(shares.list()[0]?.custody, "durable");
	assertEquals(shares.list()[0]?.scopeConversation, "lobby");
	shares.releaseConversation("directory", "direct-conversation");
	assertEquals(shares.list().length, 1);
	shares.drop("archive-share:1");
	assertEquals(shares.list(), []);
});

Deno.test("a session durable archive offer refuses a malformed sturdyref", () => {
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	let refused = false;
	try {
		shares.receiveOffer(
			directory(),
			"directory",
			"direct",
			"sender-conversation",
			"ocapn://archive.test/s/share",
			"bo",
			registrationId(1),
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(shares.list(), []);
});

Deno.test("a failed durable archive offer revokes the share it just minted", async () => {
	const issued: string[] = [];
	const revoked: string[] = [];
	const archive = {
		issueShare: (id: string) => {
			issued.push(id);
			return Promise.resolve("ocapn://archive.id/s/share");
		},
		revokeShare: (id: string) => {
			revoked.push(id);
			return Promise.resolve(true);
		},
	} as unknown as DurableRoomsArchive;
	const held = {
		id: "directory",
		directs: new Map([["alice-bob", { line: { offerArchive: () => Promise.reject(new Error("peer gone")) } }]]),
	} as unknown as LiveDirectory;
	const shares = new DurableRoomsArchiveShares(archive, () => {});
	let why = "";
	try {
		await shares.offerDurable(new Map([["directory", held]]), [], "direct", "alice-bob");
	} catch (error) {
		why = error instanceof Error ? error.message : String(error);
	}
	assertEquals(why, "peer gone");
	assertEquals(issued.length, 1);
	assertEquals(revoked, issued);
});

Deno.test("a session room archive share realizes the carrying DM", async () => {
	const held = {
		id: "directory",
		directs: new Map<string, {
			line: {
				spawn: () => object;
				handArchive: () => Promise<void>;
				releaseCapability: () => void;
			};
		}>(),
	};
	const line = {
		spawn: () => ({}),
		handArchive: () => Promise.resolve(),
		releaseCapability: () => {},
	};
	const realized: string[] = [];
	const shares = new DurableRoomsArchiveShares({} as DurableRoomsArchive, () => {});
	await shares.offer(
		new Map([["directory", held as unknown as LiveDirectory]]),
		[
			{
				kind: "room",
				id: "room-1",
				directory: "directory",
				name: "lobby",
				held: true,
				standing: null,
				draft: "",
			},
			{
				kind: "direct",
				id: "dm-1",
				directory: "directory",
				peer: "bo",
				peerRegistrationId: registrationId(1),
				closed: false,
				draft: "",
			},
		],
		"room",
		"room-1",
		"bo",
		(conversationId) => {
			realized.push(conversationId);
			held.directs.set(conversationId, { line });
			return Promise.resolve();
		},
	);
	assertEquals(realized, ["dm-1"]);
});
