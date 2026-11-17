// The recovery gesture requests exactly the admitted room and the held operator, and
// refuses on its own when the room cannot be recovered or has changed.
import "../support/match_media.ts";
import { ManagedReads } from "../../web/ui/session/managed/reads.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot } from "../support/managed_viewer.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { RoomsPageContext } from "../../web/ui/page.ts";
import { LocalRefusal, refusalText } from "../../lib/text/failure.ts";

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
function fixture(room: Record<string, unknown> = {}, operator = true) {
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
	} as never);
	const requests: Requested[] = [];
	let completed = 0;
	const page = new RoomsPage();
	const session = {
		reads: new ManagedReads(),
		current,
		effects: {
			standingVersion: "",
			roomStandingPending: () => false,
			cancelledConversations: [],
			standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
		},
		access: { status: "active" },
		pending: [],
		pendingOperations: [],
		recoverable: [],
		openings: { destination: null },
		navigation: {},
		drafts: { value: (_id: string, text: string) => text },
		actions: { pending: [], recoverable: [], cancelledConversations: [] },
		command: (name: string, args: string[], _id: string, fence?: Fence) => {
			requests.push({ name, args, fence });
			return Promise.resolve({});
		},
		completeResult: () => {
			completed++;
			return Promise.resolve();
		},
	} as unknown as ManagedRoomsSession;
	const files = presentationFiles(page.projection, () => null);
	new ManagedProjection(page, session, files, () => {}, () => {}).apply();
	const row = store.convByPersistId(page.projection, "garden")!;
	const operations = managedOperations(page as RoomsPageContext, session);
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
		const fence = held.requests[0].fence!;
		const changed = (edit: (room: Record<string, unknown>) => void): WorkspaceSnapshot => {
			const next = structuredClone(held.current);
			const room = next.intent.conversations[0] as unknown as Record<string, unknown>;
			edit(room);
			return next;
		};
		fence(changed((room) => room.draft = "typing while the manager is requested"));
		fence(changed((room) => room.name = "renamed"));
		for (
			const edit of [
				(room: Record<string, unknown>) => room.seat = "another-seat",
				(room: Record<string, unknown>) => room.access = "another-entrance",
				(room: Record<string, unknown>) => room.directory = "elsewhere",
				(room: Record<string, unknown>) => room.control = "manager",
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
