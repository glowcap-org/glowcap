// What the rail's questions answer, row by row.
//
// The browser proof watches the control hide and show real rooms, which is the
// thing a reader does. This holds the answers underneath it, where every state
// a row can be in is one value away. Two of them never turn up together in a
// live rail: a conversation with its rule still standing lasts about a second
// and a half after a reader arrives, and a rail that is holding an invitation
// is a rail somebody has to have been offered a room in. A question that
// answered either one wrongly would be found by nobody.

import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";
import {
	type DirId,
	dirId,
	type DirView,
	type DmConv,
	type Invitation,
	type RoomConv,
	type Unread,
} from "../web/ui/types.ts";
import {
	askedNothing,
	dirRow,
	dmRow,
	inviteRow,
	offKey,
	railCriteria,
	roomRow,
	rowShows,
	toggleChoice,
} from "../web/ui/sidebar/filter.ts";

const home: DirId = dirId("127.0.0.1:1");

/** The questions a tab with one directory is asked. The directory question
 * offers nothing here, and a question with nothing to choose from hides
 * nothing, so what the rows below are answering is the unread one. */
const criteria = railCriteria(new Map<DirId, DirView>(), home);

/** The rail with the rows already read turned off, and with the rows waiting
 * to be read turned off. Both, because a question with one populated answer
 * cannot be told from a question that hides at random. */
const onlyWaiting = toggleChoice(askedNothing, offKey("unread", "caught-up"));
const onlyRead = toggleChoice(askedNothing, offKey("unread", "unread"));

function room(id: string, unread: Unread): RoomConv {
	return {
		type: "room",
		id,
		persistId: "room-" + id,
		key: home + "/" + id,
		dir: home,
		history: [],
		membership: "joined",
		earlierHistory: "unasked",
		unread,
		members: new Map(),
		typers: new Set(),
		grants: new Set(),
		stewardClaimable: false,
		standing: null,
		ircIssue: "",
		held: false,
	};
}

function line(id: string, unread: Unread): DmConv {
	return {
		type: "dm",
		id,
		persistId: "dm-" + id,
		key: "dm:" + id,
		dir: home,
		peerRegistrationId: registrationId(id === "alice" ? 1 : 2),
		history: [],
		unread,
		line: "live",
		typers: new Set(),
	};
}

Deno.test("a room with lines nobody has read answers the unread question", () => {
	const waiting = roomRow(room("council", { kind: "unread", count: 2, from: 7 }));
	assertEquals(rowShows(criteria, onlyWaiting, waiting), true);
	assertEquals(rowShows(criteria, onlyRead, waiting), false);
});

Deno.test("a room the reader has caught up with is not waiting on them", () => {
	const read = roomRow(room("lobby", { kind: "caught-up" }));
	assertEquals(rowShows(criteria, onlyWaiting, read), false);
	assertEquals(rowShows(criteria, onlyRead, read), true);
});

Deno.test("a rule still standing is a room already read", () => {
	// The rule marks where the reader came in and retires a moment later. It is
	// left behind by reading rather than by anything arriving, so a reader
	// asking the rail where something is waiting for them is not asking for
	// this room.
	const ruled = roomRow(room("orchard", { kind: "rule-only", from: 7 }));
	assertEquals(rowShows(criteria, onlyWaiting, ruled), false);
	assertEquals(rowShows(criteria, onlyRead, ruled), true);
});

Deno.test("a direct line answers the question the same way a room does", () => {
	const waiting = dmRow(line("alice", { kind: "unread", count: 1, from: 3 }));
	const read = dmRow(line("bob", { kind: "caught-up" }));
	assertEquals(rowShows(criteria, onlyWaiting, waiting), true);
	assertEquals(rowShows(criteria, onlyWaiting, read), false);
	assertEquals(rowShows(criteria, onlyRead, waiting), false);
	assertEquals(rowShows(criteria, onlyRead, read), true);
});

Deno.test("a row with no conversation behind it stays in view either way", () => {
	const invite: Invitation = { id: "1", dir: home, way: "handed", label: "orchard", from: "alice", link: "" };
	const bare: DirView = {
		id: home,
		locator: home,
		liveRooms: new Map(),
		dmablePeers: new Map(),
		requestedNick: "alice",
		nick: "alice",
		slot: 0,
		reached: true,
		session: "connected",
		statusText: "",
		dmUnreachable: "",
		standing: null,
	};
	for (const answers of [askedNothing, onlyWaiting, onlyRead]) {
		assertEquals(rowShows(criteria, answers, inviteRow(invite)), true);
		assertEquals(rowShows(criteria, answers, dirRow(bare, home)), true);
	}
});
