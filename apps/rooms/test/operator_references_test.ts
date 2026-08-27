import { type Ref, type Session } from "@pancake/runtime";
import { parseOperatorPageAnswer } from "../lib/operator.ts";
import { allocateUpload } from "../server/files.ts";
import { operatorReferencePage, releaseOperatorReference } from "../server/operator/references.ts";
import {
	type Introduction,
	introductions,
	introductionsById,
	type PendingUpload,
	rooms,
	type RoomState,
} from "../server/registry.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

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
		private: false,
		members: [{ nick: "ada", inbox, session, lines: [line], away: "", topic }],
		creator: session,
		files: [],
		fileBytes: 0,
		uploads: new Map(),
		nextLine: 1,
		topic: "",
		stewardIssuedHere: false,
	} as unknown as RoomState;
	const bytes = allocateUpload(3);
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
		expires: null,
	};
	room.uploads.set(session, new Set([upload]));
	rooms.set(room.key, room);
	try {
		const first = operatorReferencePage(0, 32).rows;
		const second = operatorReferencePage(0, 32).rows;
		assertEquals(first.map((row) => row.id), second.map((row) => row.id));
		const lineRow = first.find((row) => row.kind === "line");
		const uploadRow = first.find((row) => row.kind === "upload");
		const membershipRow = first.find((row) => row.kind === "membership");
		if (lineRow == null || uploadRow == null || membershipRow == null) {
			throw new Error("reference inventory omitted a room-owned occurrence");
		}
		releaseOperatorReference(lineRow.id);
		assertEquals(room.members[0]!.lines, []);
		assertEquals(released.includes(line), true);
		releaseOperatorReference(uploadRow.id);
		assertEquals(room.uploads.get(session)?.size ?? 0, 0);
		assertEquals(released.includes(uploadRef), true);
		releaseOperatorReference(membershipRow.id);
		assertEquals(room.members, []);
		assertEquals(rooms.has(room.key), false);
		assertEquals(released.includes(inbox), true);
		assertEquals(released.includes(topic), true);
	} finally {
		rooms.delete(room.key);
	}
});

Deno.test("reference paging is bounded", () => {
	const page = operatorReferencePage(0, 1);
	assertEquals(page.rows.length <= 1, true);
	assertEquals(page.more, false);
});

// A page is a page; a count over a directory holding more than one page has to
// be the directory's own number or every number on the operator page is wrong.
// The search is what makes that count reachable: it runs here rather than in
// the browser, which holds one page of any size of inventory.
Deno.test("a reference search counts every match and sends one page of them", () => {
	const released: Ref[] = [];
	const session = fakeSession(released);
	const made: RoomState[] = [];
	for (let at = 0; at < 5; at += 1) {
		const room: RoomState = {
			entryId: `search-room-${at}`,
			name: at < 3 ? `plans-${at}` : `notes-${at}`,
			key: at < 3 ? `plans-${at}` : `notes-${at}`,
			private: false,
			members: [{ nick: `ada-${at}`, inbox: {} as Ref, session, lines: [], away: "", topic: {} as Ref }],
			creator: session,
			uploads: new Map(),
		} as unknown as RoomState;
		rooms.set(room.key, room);
		made.push(room);
	}
	try {
		const all = operatorReferencePage(0, 32);
		assertEquals(all.total >= 5, true);
		const plans = operatorReferencePage(0, 2, "plans");
		assertEquals(plans.total, 3);
		assertEquals(plans.rows.length, 2);
		assertEquals(plans.more, true);
		assertEquals(plans.rows.every((row) => row.room.includes("plans")), true);
		// Two words narrow to the row carrying both, in whichever field each sits.
		const one = operatorReferencePage(0, 32, "plans ada-1");
		assertEquals(one.total, 1);
		assertEquals(one.rows[0]?.member, "ada-1");
		assertEquals(operatorReferencePage(0, 32, "nothing-holds-this").total, 0);
	} finally {
		for (const room of made) rooms.delete(room.key);
	}
});

Deno.test("offered inbox references name the registration rather than displaying its ID as a peer", () => {
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
	introductions.set("ada", owner);
	introductions.set("bo", target);
	introductionsById.set(owner.registrationId, owner);
	introductionsById.set(target.registrationId, target);
	try {
		const row = operatorReferencePage(0, 32).rows.find((candidate) => candidate.kind === "offered-inbox");
		assertEquals(row?.detail, `inbox offered to bo (${targetId})`);
		if (row == null) throw new Error("reference inventory omitted the offered inbox");
		releaseOperatorReference(row.id);
		assertEquals(owner.inboxes.size, 0);
		assertEquals(released.includes(offered), true);
	} finally {
		introductions.delete("ada");
		introductions.delete("bo");
		introductionsById.delete(owner.registrationId);
		introductionsById.delete(target.registrationId);
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
