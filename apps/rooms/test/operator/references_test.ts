import { type Ref, type Session } from "@pancake/runtime";
import { parseOperatorPageAnswer } from "../../lib/operator.ts";
import { OperatorReferenceInventory, type OperatorReferenceRow } from "../../server/operator/references.ts";
import type { OperatorRowSource } from "../../server/operator/page.ts";
import { type Introduction, type PendingUpload, type RoomState } from "../../server/registry.ts";
import { RoomServer } from "../../server/room_server.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

function fakeSession(released: Ref[]): Session {
	return {
		sessionOpen: true,
		release(ref: Ref) {
			released.push(ref);
		},
		tell: () => Promise.resolve(null),
		onClose: () => () => {},
	} as unknown as Session;
}

Deno.test("retained reference IDs are stable and releases update their owners", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const released: Ref[] = [];
	const session = fakeSession(released);
	const inbox = {} as Ref;
	const topic = {} as Ref;
	const line = {} as Ref;
	const uploadRef = {} as Ref;
	const room = {
		entryId: "reference-room-entry",
		name: "references",
		key: "references",
		policy: { visibility: "listed", entry: "open", speaking: "open" },
		members: [{
			nick: "ada",
			inbox,
			session,
			lines: [{ ref: line, session }],
			away: "",
			topic,
			seat: null,
			kind: "participant",
		}],
		invitations: new Set(),
		lifetimeOwner: session,
		files: [],
		fileBytes: 0,
		uploads: new Map(),
		nextLine: 1,
		topic: "",
	} as unknown as RoomState;
	const member = room.members[0];
	const bytes = server.files.allocateUpload(3);
	if (bytes === null) throw new Error("test upload allocation was refused");
	const upload: PendingUpload = {
		size: 3,
		file: {
			room,
			name: "pending.txt",
			mime: "text/plain",
			size: 3,
			width: 0,
			height: 0,
			bytes,
			written: 0,
			failure: null,
			waiters: new Set(),
		},
		posted: false,
		spent: false,
		ref: uploadRef,
		member,
		session,
		expires: null,
	};
	room.uploads.set(member, new Set([upload]));
	server.live.rooms.set(room.key, room);
	try {
		const first = refs.page(0, 32).rows;
		const second = refs.page(0, 32).rows;
		assertEquals(first.map((row) => row.id), second.map((row) => row.id));
		const lineRow = first.find((row) => row.kind === "line");
		const uploadRow = first.find((row) => row.kind === "upload");
		const membershipRow = first.find((row) => row.kind === "membership");
		if (lineRow == null || uploadRow == null || membershipRow == null) {
			throw new Error("reference inventory omitted a room-owned occurrence");
		}
		refs.release(lineRow.id);
		assertEquals(room.members[0]!.lines, []);
		assertEquals(released.includes(line), true);
		refs.release(uploadRow.id);
		assertEquals(room.uploads.get(member)?.size ?? 0, 0);
		assertEquals(released.includes(uploadRef), true);
		refs.release(membershipRow.id);
		assertEquals(room.members, []);
		assertEquals(server.live.rooms.has(room.key), false);
		assertEquals(released.includes(inbox), true);
		assertEquals(released.includes(topic), true);
	} finally {
		server.live.rooms.delete(room.key);
	}
});

Deno.test("reference paging is bounded", () => {
	const server = new RoomServer();
	const page = new OperatorReferenceInventory(server).page(0, 1);
	assertEquals(page.rows.length <= 1, true);
	assertEquals(page.more, false);
});

Deno.test("a cascading reference retirement reports the live remaining count", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const session = fakeSession([]);
	const memberSessions = new Map([["ada", session], ["bo", fakeSession([])]]);
	const memberSession = (nick: string) => memberSessions.get(nick)!;
	const room = {
		entryId: "cascade-room-entry",
		name: "cascade-room",
		key: "cascade-room",
		policy: { visibility: "listed", entry: "open", speaking: "open" },
		members: ["ada", "bo"].map((nick) => ({
			nick,
			inbox: {} as Ref,
			session: memberSession(nick),
			lines: Array.from({ length: 2 }, () => ({ ref: {} as Ref, session: memberSession(nick) })),
			away: "",
			topic: {} as Ref,
			seat: null,
			kind: "participant",
		})),
		invitations: new Set(),
		lifetimeOwner: session,
		files: [],
		fileBytes: 0,
		uploads: new Map(),
		nextLine: 1,
		topic: "",
	} as unknown as RoomState;
	server.live.rooms.set(room.key, room);
	try {
		let batch = refs.retireMatching(session, "", null, 1);
		assertEquals(batch.remaining, refs.page(0, 32).total);
		for (let at = 0; at < 8 && batch.remaining > 0; at += 1) {
			batch = refs.retireMatching(session, "", null, 1);
			assertEquals(batch.remaining, refs.page(0, 32).total);
		}
		assertEquals(batch.remaining, 0);
	} finally {
		server.live.rooms.delete(room.key);
	}
});

// A page is a page; a count over a directory holding more than one page has to
// be the directory's own number or every number on the operator page is wrong.
// The search is what makes that count reachable: it runs here rather than in
// the browser, which holds one page of any size of inventory.
Deno.test("a reference search counts every match and sends one page of them", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const released: Ref[] = [];
	const session = fakeSession(released);
	const made: RoomState[] = [];
	for (let at = 0; at < 5; at += 1) {
		const room: RoomState = {
			entryId: `search-room-${at}`,
			name: at < 3 ? `plans-${at}` : `notes-${at}`,
			key: at < 3 ? `plans-${at}` : `notes-${at}`,
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [{
				nick: `ada-${at}`,
				inbox: {} as Ref,
				session,
				lines: [],
				away: "",
				topic: {} as Ref,
				seat: null,
				kind: "participant",
			}],
			invitations: new Set(),
			lifetimeOwner: session,
			files: [],
			fileBytes: 0,
			uploads: new Map(),
			nextLine: 1,
			topic: "",
		} as unknown as RoomState;
		server.live.rooms.set(room.key, room);
		made.push(room);
	}
	try {
		const all = refs.page(0, 32);
		assertEquals(all.total >= 5, true);
		const plans = refs.page(0, 2, "plans");
		assertEquals(plans.total, 3);
		assertEquals(plans.rows.length, 2);
		assertEquals(plans.more, true);
		assertEquals(plans.rows.every((row) => row.room.includes("plans")), true);
		// Two words narrow to the row carrying both, in whichever field each sits.
		const one = refs.page(0, 32, "plans ada-1");
		assertEquals(one.total, 1);
		assertEquals(one.rows[0]?.member, "ada-1");
		assertEquals(refs.page(0, 32, "nothing-holds-this").total, 0);
		const directLines = refs.page(0, 32, "", "line");
		assertEquals(directLines.rows.every((row) => row.kind === "line"), true);
		assertEquals(
			refs.page(0, 32, "line", "membership").rows.every((row) => row.kind === "membership"),
			true,
		);
	} finally {
		for (const room of made) server.live.rooms.delete(room.key);
	}
});

Deno.test("a hundred thousand retained references still answer one bounded page", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const session = fakeSession([]);
	const lines = Array.from({ length: 100_000 }, () => ({ ref: {} as Ref, session }));
	const room = {
		entryId: "large-reference-room-entry",
		name: "large-reference-room",
		key: "large-reference-room",
		policy: { visibility: "listed", entry: "open", speaking: "open" },
		members: [{
			nick: "ada",
			inbox: {} as Ref,
			session,
			lines,
			away: "",
			topic: {} as Ref,
			seat: null,
			kind: "participant",
		}],
		invitations: new Set(),
		lifetimeOwner: session,
		files: [],
		fileBytes: 0,
		uploads: new Map(),
		nextLine: 1,
		topic: "",
	} as unknown as RoomState;
	server.live.rooms.set(room.key, room);
	try {
		assertEquals(
			Array.isArray(refs.faces()),
			false,
			"a bounded page retained a process-sized reference index",
		);
		const page = refs.page(0, 32, "", "line");
		assertEquals(page.rows.length, 32);
		assertEquals(page.total, 100_000);
		assertEquals(page.more, true);
		let firstSource: OperatorRowSource<OperatorReferenceRow> | null = null;
		for (const source of refs.faces()) {
			if (source.kind !== "line") continue;
			firstSource = source;
			break;
		}
		if (firstSource == null) throw new Error("the large reference room exposed no line source");
		assertEquals(
			Object.hasOwn(firstSource, "retire"),
			false,
			"line rows retained per-reference release closures",
		);
		assertEquals(
			Object.hasOwn(firstSource, "active"),
			false,
			"line rows retained per-reference liveness closures",
		);
		const first = refs.retireMatching(session, "", "line", 256);
		assertEquals(first.retired, 256);
		assertEquals(first.remaining, 99_744);
		const second = refs.retireMatching(session, "", "line", 256);
		assertEquals(second.retired, 256);
		assertEquals(second.remaining, 99_488);
	} finally {
		server.live.rooms.delete(room.key);
	}
});

Deno.test("offered inbox references name the registration rather than displaying its ID as a peer", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const released: Ref[] = [];
	const session = fakeSession(released);
	const offered = {} as Ref;
	const targetId = registrationId(2);
	const target = {
		nick: "bo",
		registrationId: targetId,
		registrar: session,
		inbox: {} as Ref,
		inboxes: new Map(),
		directRequests: new Map(),
		signaling: null,
		vouchers: new Set(),
	} satisfies Introduction;
	const owner = {
		...target,
		nick: "ada",
		registrationId: registrationId(1),
		inbox: {} as Ref,
		inboxes: new Map([[targetId, offered]]),
	} satisfies Introduction;
	server.live.introductions.set("ada", owner);
	server.live.introductions.set("bo", target);
	server.live.introductionsById.set(owner.registrationId, owner);
	server.live.introductionsById.set(target.registrationId, target);
	try {
		const row = refs.page(0, 32).rows.find((candidate) => candidate.kind === "offered-inbox");
		assertEquals(row?.detail, `inbox offered to bo (${targetId})`);
		if (row == null) throw new Error("reference inventory omitted the offered inbox");
		refs.release(row.id);
		assertEquals(owner.inboxes.size, 0);
		assertEquals(released.includes(offered), true);
	} finally {
		server.live.introductions.delete("ada");
		server.live.introductions.delete("bo");
		server.live.introductionsById.delete(owner.registrationId);
		server.live.introductionsById.delete(target.registrationId);
	}
});

Deno.test("registration sweeps account for inboxes offered by later owners", () => {
	const server = new RoomServer();
	const refs = new OperatorReferenceInventory(server);
	const operator = fakeSession([]);
	const targetSession = fakeSession([]);
	const ownerSession = fakeSession([]);
	const targetId = registrationId(12);
	const target = {
		nick: "zephyr",
		registrationId: targetId,
		registrar: targetSession,
		inbox: {} as Ref,
		inboxes: new Map(),
		directRequests: new Map(),
		signaling: null,
		vouchers: new Set(),
	} satisfies Introduction;
	const owner = {
		nick: "ada",
		registrationId: registrationId(11),
		registrar: ownerSession,
		inbox: {} as Ref,
		inboxes: new Map([[targetId, {} as Ref]]),
		directRequests: new Map(),
		signaling: null,
		vouchers: new Set(),
	} satisfies Introduction;
	// Target first is the order that used to retire it before visiting the
	// offered inbox stored on the later owner.
	server.live.introductions.set("zephyr", target);
	server.live.introductions.set("ada", owner);
	server.live.introductionsById.set(target.registrationId, target);
	server.live.introductionsById.set(owner.registrationId, owner);
	server.live.introductionsBySession.set(targetSession, target);
	server.live.introductionsBySession.set(ownerSession, owner);
	try {
		let batch = refs.retireMatching(operator, "zephyr", null, 1);
		assertEquals(batch.remaining, refs.page(0, 32, "zephyr").total);
		batch = refs.retireMatching(operator, "zephyr", null, 1);
		assertEquals(batch.remaining, refs.page(0, 32, "zephyr").total);
		assertEquals(batch.remaining, 0);
	} finally {
		server.live.introductions.delete("zephyr");
		server.live.introductions.delete("ada");
		server.live.introductionsById.delete(target.registrationId);
		server.live.introductionsById.delete(owner.registrationId);
		server.live.introductionsBySession.delete(targetSession);
		server.live.introductionsBySession.delete(ownerSession);
	}
});

Deno.test("reference pages round-trip their bounded wire tuples", () => {
	const page = parseOperatorPageAnswer("references", [
		4n,
		null,
		[["ref-1", "line", "room line history", "plans", "ada", "recent editable line authority"]],
		1n,
	]);
	assertEquals(page.total, 1);
	assertEquals(page.rows, [{
		id: "ref-1",
		kind: "line",
		owner: "room line history",
		room: "plans",
		member: "ada",
		detail: "recent editable line authority",
	}]);
});
