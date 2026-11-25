// The recovery gesture requests exactly the admitted room and the held operator, and
// refuses on its own when the room cannot be recovered or has changed.
import "../support/match_media.ts";
import { ManagedReads } from "../../web/ui/session/managed/reads.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot } from "../support/managed_viewer.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomIntent, WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import { LocalRefusal, refusalText } from "../../lib/text/failure.ts";
import { actionSession, fakeHandle, oneLink } from "../support/managed_link.ts";
import type { ManagedEffects } from "../../web/ui/session/managed/effects.ts";
import type { ManagedOpenings } from "../../web/ui/session/managed/openings.ts";
import type { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import type { ManagedDrafts } from "../../web/ui/session/managed/drafts.ts";
import { ManagedActions } from "../../web/ui/session/managed/actions.ts";
import type { ManagedOperation } from "../../web/ui/session/managed/operation.ts";

const { RoomsPage } = await import("../../web/ui/page.ts");
const { managedOperations } = await import("../../web/ui/session/managed/operations.ts");
const { ManagedProjection } = await import("../../web/ui/session/managed/projection.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const store = await import("../../web/ui/store.ts");

type Fence = (snapshot: WorkspaceSnapshot) => void;
interface Requested {
	name: string;
	args: string[];
	fence?: Fence;
}
function fixture(room: Partial<RoomIntent> = {}, operator = true) {
	const current = snapshot();
	if (operator) current.intent.operators = ["operator-key"];
	current.intent.directories.push({
		id: "directory",
		access: "directory-access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	current.intent.conversations.push({
		kind: "room",
		id: "garden",
		directory: "directory",
		name: "garden",
		source: "source",
		access: "entrance",
		seat: "seat",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
		...room,
	});
	const requests: Requested[] = [];
	let completed = 0;
	const page = new RoomsPage();
	const session = fakeHandle<ManagedRoomsSession>({
		onRelink: () => () => {},
		reads: new ManagedReads(),
		current,
		effects: fakeHandle<ManagedEffects>({
			standingVersion: "",
			roomStandingPending: () => false,
			cancelledConversations: [],
			standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
		}),
		access: { status: "active" },
		pending: [],
		pendingOperations: [],
		recoverable: [],
		openings: fakeHandle<ManagedOpenings>({ destination: null }),
		navigation: fakeHandle<ManagedNavigation>({}),
		drafts: fakeHandle<ManagedDrafts>({ value: (_id: string, text: string) => text }),
		// The real actions, over the owner entry the pieces below stand in for.
		actions: new ManagedActions(
			actionSession({}, {
				current,
				command: (name: string, args: string[] = [], _id?: string, fence?: Fence) => {
					requests.push({ name, args, fence });
					return Promise.resolve(fakeHandle<ManagedOperation>({}));
				},
				completeResult: () => {
					completed++;
					return Promise.resolve();
				},
			}),
			oneLink({}),
		),
	});
	const files = presentationFiles(page.projection, () => null);
	new ManagedProjection(page, session, files, () => {}, () => {}).apply();
	const row = store.convByPersistId(page.projection, "garden");
	assert(row != null, "the room is shown");
	const operations = managedOperations(page, session);
	return { current, requests, completed: () => completed, operations, row, files };
}

Deno.test("recovery requests the held operator and the admitted room, never an identity", async () => {
	const held = fixture();
	try {
		assertEquals(await held.operations.recoverRoomManager(held.row.key), "");
		assertEquals(held.requests.length, 1);
		const [request] = held.requests;
		assertEquals(request.name, "recoverRoomManager");
		assertEquals(request.args.length, 2);
		assertEquals(JSON.parse(request.args[0]), "operator-key");
		assertEquals(JSON.parse(request.args[1]), {
			id: "garden",
			directory: "directory",
			source: "source",
			seat: "seat",
			access: "entrance",
		});
		assertEquals(held.completed(), 1, "the issued manager is taken into its room once");
	} finally {
		held.files.close();
	}
});

for (
	const [label, row, operator, expected] of [
		["a room the session has no seat in", { seat: undefined }, true, "manager-recovery-needs-membership"],
		["a room that already has a manager", { control: "manager" }, true, "selected-access-changed"],
		["a workspace with no operator", {}, false, "operations-access-missing"],
	] as const
) {
	Deno.test(`recovery refuses ${label} before asking for anything`, async () => {
		const held = fixture(row, operator);
		try {
			const refusal = await held.operations.recoverRoomManager(held.row.key);
			const cause = expected === "operations-access-missing" ? { cause: "operator" } : undefined;
			assertEquals(refusal, refusalText(new LocalRefusal(expected, cause)));
			assertEquals(held.requests.length, 0, "a request was made");
			assertEquals(held.completed(), 0);
		} finally {
			held.files.close();
		}
	});
}

Deno.test("re-preparation keeps an unrelated change and refuses a change to the admitted room", async () => {
	const held = fixture();
	try {
		await held.operations.recoverRoomManager(held.row.key);
		const fence = held.requests[0].fence;
		assert(fence != null, "the request is fenced");
		const changed = (edit: (room: RoomIntent) => void): WorkspaceSnapshot => {
			const next = structuredClone(held.current);
			const room = next.intent.conversations[0];
			assert(room?.kind === "room", "the room is held");
			edit(room);
			return next;
		};
		fence(changed((room) => room.draft = "typing while the manager is requested"));
		fence(changed((room) => room.name = "renamed"));
		for (
			const edit of [
				(room: RoomIntent) => room.seat = "another-seat",
				(room: RoomIntent) => room.access = "another-entrance",
				(room: RoomIntent) => room.directory = "elsewhere",
				(room: RoomIntent) => room.control = "manager",
			]
		) {
			let refused = false;
			try {
				fence(changed(edit));
			} catch {
				refused = true;
			}
			assert(refused, "a change to the admitted room passed the fence");
		}
	} finally {
		held.files.close();
	}
});
