// What each access is shown of a session, including the one that carries
// nothing.
//
// These were written by comparing against "observe", which reads as "the least
// anyone can have" only while it is. Adding a rung below it — a suspended link
// — silently promoted that rung above an observer in three places at once: its
// lines came back editable and its rooms came back with moderation on them.
// This is the shape that catches it, so a fourth rung cannot do it again.

import { assertEquals } from "../assert.ts";
import { type FacetViewOwner, roomViewsVisibleTo, snapshotForFacet } from "../../session/facet_view.ts";
import { mayInteract, parseRoomsSessionSnapshot, type RoomsSessionAccess } from "../../lib/session/client.ts";
import type { RoomsSessionRoomView } from "../../lib/session/client.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import type { Session } from "@pancake/runtime";

const ROOM: RoomsSessionRoomView = {
	conversationId: "room-1",
	membershipKind: "participant",
	policy: { visibility: "listed", entry: "open", speaking: "open" },
	members: [],
	topic: null,
	lineBytes: null,
	canSetTopic: true,
	canModerate: true,
};

Deno.test("only an access that may act is shown what it may act on", () => {
	// Every access there is, so a new one has to be answered for here.
	const each: RoomsSessionAccess[] = ["none", "observe", "interact", "admin"];
	const acting = each.filter(mayInteract);
	assertEquals(acting, ["interact", "admin"]);

	for (const access of each) {
		const [view] = roomViewsVisibleTo(access, [ROOM]);
		const offered = view.canSetTopic || view.canModerate;
		assertEquals(
			offered,
			mayInteract(access),
			`${access} was ${offered ? "offered" : "denied"} moderation it should not have been`,
		);
	}
});

/** A session holding a workspace it has never been asked to give up: rooms in
 * it, and its one-time adoption still open. Only what `snapshotForFacet` reads,
 * because that is the whole of what it decides from. */
function sessionHolding(): FacetViewOwner {
	const checkpoint = {
		...emptyRoomsSessionState(),
		standing: "shared through a capability",
		directories: [{
			id: "ocapn://d.example",
			locator: "ocapn://d.example",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "room" as const,
			id: "room-1",
			directory: "ocapn://d.example",
			name: "design",
			held: false,
			standing: null,
			draft: "",
		}],
	};
	return {
		state: {
			snapshot: () => ({ revision: 7, checkpoint }),
			workspaceAdoption: "available",
			pendingEffectIds: () => [],
			pendingEffectDetails: () => [],
		},
		runtime: {
			issues: () => [],
			connectedDirectories: () => ["ocapn://d.example"],
			memberLocator: () => "ocapn://d.example/m/ada",
			roomViews: () => [ROOM],
			archiveShares: () => [],
			directoryViews: () => [],
			handedRooms: { list: () => [] },
		},
		grants: { list: () => [] },
	} as unknown as FacetViewOwner;
}

// A suspended link is answered with no session, and the adoption answer is part
// of that. A browser attaching hands its own workspace over the moment it is
// told the session will take one, and that hand-over is refused at this access:
// answered with the session's real state, attaching with a paused link fails
// outright instead of landing on a workspace that says why it is empty. Neither
// the peer proof nor the browser one can reach this, because both make a state
// command before pausing and the first command closes adoption.
Deno.test("a suspended link is answered with no session and no offer to take its workspace", () => {
	const owner = sessionHolding();
	const paused = parseRoomsSessionSnapshot(
		snapshotForFacet("none", null as unknown as Session, "Back on Monday", [], owner),
	);
	assertEquals(paused.checkpoint.conversations, [], "a suspended link was handed the rooms");
	assertEquals(paused.checkpoint.directories, [], "a suspended link was handed the directories");
	assertEquals(paused.checkpoint.standing, "", "a suspended link was handed the session's standing");
	assertEquals(paused.roomViews, [], "a suspended link was handed live room views");
	assertEquals(paused.connectedDirectories, [], "a suspended link was told which directories are reachable");
	assertEquals(paused.memberLocator, null, "a suspended link was handed the member locator");
	assertEquals(paused.workspaceAdoption, "closed", "a suspended link was offered the session's open adoption");
	assertEquals(paused.access, "none");
	assertEquals(paused.suspendedNote, "Back on Monday", "a suspended link was not told why it has nothing");

	// And the same session answers an observer with what it holds, so the
	// emptiness above is this access rather than this fixture.
	const observing = parseRoomsSessionSnapshot(
		snapshotForFacet("observe", null as unknown as Session, "", [], owner),
	);
	assertEquals(observing.checkpoint.conversations.length, 1, "an observer was not handed the rooms");
	assertEquals(observing.workspaceAdoption, "available", "an observer was not told adoption is open");
});
