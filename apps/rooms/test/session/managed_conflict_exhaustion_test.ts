// Exhausted optimistic retries reach the actionable refusal on each room path.
import { LOCAL_REFUSALS } from "../../lib/text/local_refusals.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { fixture } from "../support/managed_controller.ts";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";
import { failureView, LocalRefusal } from "../../lib/text/failure.ts";
import { MAX_CONFLICT_REPREPARATIONS } from "../../web/ui/session/managed/acquisition.ts";
import { managedRoomActions } from "../../web/ui/session/managed/rooms.ts";
import * as store from "../../web/ui/store.ts";

for (const operation of ["create", "join"]) {
	Deno.test(`exhausted ${operation} conflicts give the catalog refusal and retire every candidate`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "entry",
			source: "source",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		let attempts = 0;
		let freed = 0;
		const prepare = () => {
			attempts++;
			return Promise.resolve({
				submit: () => Promise.resolve({ status: "conflict" }),
				free: () => freed++,
			});
		};
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: prepare,
			preparePublicRoom: prepare,
		});
		try {
			const [outcome] = await Promise.allSettled([
				operation === "create"
					? session.actions.createRoom("directory", "garden", OPEN_ROOM_POLICY)
					: session.actions.publicRoom("directory", "garden", "publication"),
			]);
			assert(outcome.status === "rejected", "exhaustion must refuse");
			assert(outcome.reason instanceof LocalRefusal, "exhaustion must be actionable");
			assertEquals(failureView(outcome.reason).summary, LOCAL_REFUSALS["conflict"].summary);
			assertEquals(failureView(outcome.reason).retry, "after-state-change");
			assertEquals(attempts, MAX_CONFLICT_REPREPARATIONS);
			assertEquals(freed, attempts, "all definitively refused candidates are retired");
			assertEquals(session.actions.pending, []);
		} finally {
			await session.close();
		}
	});
}

Deno.test("exhausted moderator conflicts show the catalog sentence", async () => {
	const f = fixture();
	const selected = {
		kind: "room" as const,
		id: "selected",
		directory: f.id,
		name: "garden",
		source: "source",
		access: "entry",
		control: "manager",
		reconnect: "manual" as const,
		standing: null,
		draft: "",
	};
	f.current.intent.conversations.push(selected);
	const room = store.ensureRoom(f.page.projection, f.id, "garden", { persistId: selected.id });
	let attempts = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(f.current),
		prepareCommand: () => {
			attempts++;
			return Promise.resolve({ submit: () => Promise.resolve({ status: "conflict" }), free() {} });
		},
	});
	await session.refresh();
	try {
		const result = await managedRoomActions(f.page, session).stewardRoom(room.key);
		assertEquals(result, LOCAL_REFUSALS["conflict"].summary);
		assertEquals(attempts, MAX_CONFLICT_REPREPARATIONS);
	} finally {
		await session.close();
		f.close();
	}
});
