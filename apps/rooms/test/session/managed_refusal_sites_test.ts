// Refusals are tested at the owner that selects them, not just in the catalog.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assert, assertEquals } from "@std/assert";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { failureView, LocalRefusal, refusalText } from "../../lib/text/failure.ts";
import { managedWorkspaceActions } from "../../web/ui/session/managed/workspace.ts";
import { managedOperations } from "../../web/ui/session/managed/operations.ts";
import { ManagedHistory } from "../../web/ui/session/managed/history.ts";
import { planJoinDestination } from "../../web/ui/joining.ts";
import { RoomsPage } from "../../web/ui/page.ts";
import * as store from "../../web/ui/store.ts";
import { dirId } from "../../web/ui/directory.ts";
import { initializeApplication } from "../support/application.ts";
await initializeApplication();

Deno.test("missing workspace, acquisition and operations authority select catalog refusals", async () => {
	const page = new RoomsPage();
	const session = viewer({});
	const workspace = managedWorkspaceActions(page, session, () => Promise.resolve());
	const ops = managedOperations(page, session);
	try {
		for (
			const [request, code] of [
				[() => workspace.exportRoomsState(), "local-workspace-unavailable"],
				[() => session.navigation.select("room"), "local-workspace-unavailable"],
				[() => session.actions.recoverAcquisition("absent"), "local-acquisition-gone"],
			] satisfies [() => Promise<unknown>, string][]
		) {
			const [result] = await Promise.allSettled([request()]);
			assert(result.status === "rejected");
			assertEquals(failureView(result.reason).code, code);
		}
		assertEquals(
			await ops.searchOperator(""),
			refusalText(new LocalRefusal("operations-access-missing", { cause: "operator" })),
		);
	} finally {
		await session.close();
	}
});

Deno.test("operations refuse an unsavable capability and changed room access", async () => {
	const page = new RoomsPage();
	const current = snapshot();
	current.intent.operations = [{ kind: "diagnostics", handle: { role: "diagnostics", key: "kept" } }];
	const session = viewer({ snapshot: () => Promise.resolve(current), custodyRecipe: () => Promise.resolve(null) });
	await session.refresh();
	const ops = managedOperations(page, session);
	try {
		const [result] = await Promise.allSettled([ops.readOpsBundle()]);
		assert(result.status === "rejected");
		assertEquals(failureView(result.reason).code, "local-capability-unsavable");
		const room = store.ensureRoom(page.projection, dirId("directory"), "room", { persistId: "lost" });
		assertEquals(
			await ops.publishPeeredRoom(room.key, "room"),
			refusalText(new LocalRefusal("room-access-changed")),
		);
	} finally {
		await session.close();
	}
});

Deno.test("an invalid room link asks for a room entry", () => {
	let refusal: unknown;
	try {
		planJoinDestination({ address: "ocapn://x.tcp/s/!", room: "room" });
	} catch (error) {
		refusal = error;
	}
	assertEquals(failureView(refusal).code, "local-not-room-entry");
});

for (const action of ["complete", "acquire", "retry"]) {
	Deno.test(`a retired receipt refuses ${action} through the catalog`, async () => {
		const session = viewer({
			snapshot: () => Promise.resolve(snapshot()),
			prepareCommand: () =>
				Promise.resolve({
					submit: () => Promise.resolve({ status: "committed" }),
					status: () => Promise.resolve("committed"),
					free() {},
				}),
		});
		const operation = await session.command("operations", [], "retired");
		session.finish(operation);
		let error: unknown;
		try {
			if (action === "complete") await operation.complete(() => Promise.resolve());
			else if (action === "acquire") await operation.acquire(snapshot(), []);
			else await operation.retryAcquisition();
		} catch (caught) {
			error = caught;
		}
		assertEquals(failureView(error).code, "local-receipt-retired");
		await session.close();
	});
}

Deno.test("an acquisition returning after receipt close frees its custody and refuses", async () => {
	const prepared = deferred<{ submit(): Promise<unknown>; free(): void }>();
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				prepareResultAcquisition: () => prepared.promise,
				free() {},
			}),
	});
	const operation = await session.command("operations", [], "closing");
	const acquired = operation.acquire(snapshot(), []);
	const closing = operation.close();
	let freed = 0;
	prepared.resolve({
		submit: () => {
			throw new Error("late acquisition must not submit");
		},
		free() {
			freed++;
		},
	});
	const [result] = await Promise.allSettled([acquired]);
	await closing;
	assert(result.status === "rejected");
	assertEquals(failureView(result.reason).code, "local-receipt-retired");
	assertEquals(freed, 1);
	await session.close();
});

Deno.test("Settings history retry delegates to the history owner and reports closure", async () => {
	const page = new RoomsPage();
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	const history = new ManagedHistory(page, session, () => {});
	await session.refresh();
	const workspace = managedWorkspaceActions(page, session, () => history.refresh());
	assertEquals(await workspace.retryHistory(), "");
	await history.close();
	assertEquals(await workspace.retryHistory(), refusalText(new LocalRefusal("session-closed")));
	await session.close();
});

Deno.test("publishing a held room without peering access selects its own refusal", async () => {
	const page = new RoomsPage();
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "held",
		directory: "directory",
		name: "room",
		access: "access",
		control: null,
		reconnect: "manual",
		standing: null,
		draft: "",
	});
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	await session.refresh();
	const room = store.ensureRoom(page.projection, dirId("directory"), "room", { persistId: "held" });
	try {
		assertEquals(
			await managedOperations(page, session).publishPeeredRoom(room.key, "room"),
			refusalText(new LocalRefusal("operations-access-missing")),
		);
	} finally {
		store.forgetConv(page.projection, room.key);
		await session.close();
	}
});

Deno.test("the join-link command returns the catalog refusal without a second sentence", async () => {
	const { managedCommandPowers } = await import("../../web/ui/session/managed/commands.ts");
	const { managedRoomActions } = await import("../../web/ui/session/managed/rooms.ts");
	const page = new RoomsPage();
	const session = viewer({});
	const powers = managedCommandPowers(
		page,
		{ setTheme() {}, showRoster() {}, aboutConversation() {} },
		session,
		managedRoomActions(page, session),
		() => Promise.resolve(),
		() => Promise.resolve(),
		() => Promise.resolve(""),
	);
	try {
		assertEquals(await powers.joinLink("not a room link", "room"), refusalText(new LocalRefusal("not-room-entry")));
	} finally {
		await session.close();
	}
});
