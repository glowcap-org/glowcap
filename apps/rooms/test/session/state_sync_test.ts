import {
	reconcileRuntimeState,
	runtimeStateImpact,
	type RuntimeStateReconciliation,
} from "../../session/state_sync.ts";
import { RuntimeStateSync } from "../../session/runtime_state_sync.ts";
import { assertEquals } from "../assert.ts";
import { workspaceFixture } from "../support/workspace.ts";
import { openSessionState } from "../support/session_disk.ts";

function checkpointFixture() {
	const checkpoint = workspaceFixture().session;
	const directory = "ocapn://127.0.0.1%3A1.tcp";
	return {
		...checkpoint,
		directories: [{
			id: directory,
			locator: "127.0.0.1:1",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "room" as const,
			id: "room-id",
			directory,
			name: "general",
			held: false,
			link: `${directory}/s/cm9vbS1saW5r`,
			manager: `${directory}/s/bWFuYWdlcg`,
			steward: `${directory}/s/bW9kZXJhdG9y`,
			standing: null,
			draft: "",
		}],
		invitations: [],
		active: "room-id",
		capabilities: { operations: [], archivePeer: null },
	};
}

const roomRetired = (token: string): RuntimeStateReconciliation => ({
	type: "room-authority",
	conversationId: "room-id",
	kind: "room",
	token,
	claimable: false,
});

Deno.test("runtime facts conditionally reconcile through the durable checkpoint owner", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-state-sync-" });
	try {
		const state = await openSessionState(directory);
		const checkpoint = checkpointFixture();
		await state.replace("fixture", 0, checkpoint);
		const impacts: string[] = [];
		state.onCheckpointChange((_revision, _checkpoint, impact) => impacts.push(impact));

		const wrong = roomRetired("later-room-link");
		assertEquals(
			await state.reconcile({
				impact: runtimeStateImpact(wrong),
				change: (current) => reconcileRuntimeState(current, wrong),
			}),
			null,
		);
		assertEquals(state.snapshot().revision, 1);
		const manager = {
			type: "room-authority",
			conversationId: "room-id",
			kind: "manager",
			token: "manager",
			claimable: false,
		} as const;
		assertEquals(
			await state.reconcile({
				impact: runtimeStateImpact(manager),
				change: (current) => reconcileRuntimeState(current, manager),
			}),
			1,
		);
		const afterManager = state.snapshot().checkpoint.conversations[0];
		assertEquals(afterManager.kind === "room" ? afterManager.manager : null, undefined);
		assertEquals(
			afterManager.kind === "room" ? afterManager.link : null,
			"ocapn://127.0.0.1%3A1.tcp/s/cm9vbS1saW5r",
		);
		const publication = {
			type: "room-publication",
			conversationId: "room-id",
			expectedPublicationId: null,
			publicationId: "bridge-generation",
		} as const;
		await state.reconcile({
			impact: runtimeStateImpact(publication),
			change: (current) => reconcileRuntimeState(current, publication),
		});
		const afterPublication = state.snapshot().checkpoint.conversations[0];
		assertEquals(afterPublication.kind === "room" ? afterPublication.publicationId : null, "bridge-generation");
		const replacement = {
			...publication,
			expectedPublicationId: "bridge-generation",
			publicationId: "bridge-generation-2",
		};
		await state.reconcile({
			impact: runtimeStateImpact(replacement),
			change: (current) => reconcileRuntimeState(current, replacement),
		});
		const afterReplacement = state.snapshot().checkpoint.conversations[0];
		assertEquals(afterReplacement.kind === "room" ? afterReplacement.publicationId : null, "bridge-generation-2");

		const steward = {
			type: "room-authority",
			conversationId: "room-id",
			kind: "steward",
			token: "moderator",
			claimable: true,
		} as const;
		assertEquals(
			await state.reconcile({
				impact: runtimeStateImpact(steward),
				change: (current) => reconcileRuntimeState(current, steward),
			}),
			1,
		);
		const afterSteward = state.snapshot().checkpoint.conversations[0];
		assertEquals(
			afterSteward.kind === "room" ? afterSteward.link : null,
			"ocapn://127.0.0.1%3A1.tcp/s/cm9vbS1saW5r",
		);
		assertEquals(afterSteward.kind === "room" ? afterSteward.steward : null, undefined);
		const retiredRoom = roomRetired("room-link");
		assertEquals(
			await state.reconcile({
				impact: runtimeStateImpact(retiredRoom),
				change: (current) => reconcileRuntimeState(current, retiredRoom),
			}),
			1,
		);
		const afterRoom = state.snapshot().checkpoint.conversations[0];
		assertEquals(afterRoom.kind === "room" ? afterRoom.link : null, undefined);
		assertEquals(afterRoom.kind === "room" ? afterRoom.reconnect : null, "manual");

		const reached = {
			type: "directory-reached",
			directoryId: "ocapn://127.0.0.1%3A1.tcp",
			locator: "127.0.0.1:1",
		} as const;
		assertEquals(
			await state.reconcile({
				impact: runtimeStateImpact(reached),
				change: (current) => reconcileRuntimeState(current, reached),
			}),
			1,
		);
		assertEquals(state.snapshot().revision, 1);
		assertEquals(state.snapshot().checkpoint.directories[0].reached, true);
		assertEquals(impacts, [
			"realization",
			"realization",
			"realization",
			"realization",
			"realization",
			"presentation",
		]);

		const restored = await openSessionState(directory);
		assertEquals(restored.snapshot().checkpoint.directories[0].reached, true);
		const restoredRoom = restored.snapshot().checkpoint.conversations[0];
		assertEquals(restoredRoom.kind === "room" ? restoredRoom.steward : null, undefined);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a delayed authority notice cannot erase a reissued bearer", () => {
	const checkpoint = checkpointFixture();
	const reissued = {
		...checkpoint,
		conversations: checkpoint.conversations.map((conversation) =>
			conversation.kind === "room"
				? { ...conversation, link: "ocapn://127.0.0.1%3A1.tcp/s/Y3VycmVudC1yb29tLWxpbms" }
				: conversation
		),
	};
	assertEquals(reconcileRuntimeState(reissued, roomRetired("room-link")), null);
});

Deno.test("an incoming exact peer registration becomes one durable direct conversation", () => {
	const checkpoint = checkpointFixture();
	const accepted = {
		type: "direct-accepted",
		conversationId: "incoming-direct",
		directoryId: checkpoint.directories[0].id,
		peer: "bob",
		peerRegistrationId: "00000000-0000-4000-8000-000000000001",
	} as const;
	const next = reconcileRuntimeState(checkpoint, accepted);
	const direct = next?.conversations.find((conversation) => conversation.id === accepted.conversationId);
	assertEquals(runtimeStateImpact(accepted), "realization");
	assertEquals(direct?.kind, "direct");
	assertEquals(direct?.kind === "direct" ? direct.peerRegistrationId : null, accepted.peerRegistrationId);
	assertEquals(
		next == null ? "missing" : reconcileRuntimeState(next, { ...accepted, conversationId: "duplicate" }),
		null,
	);
});

Deno.test("state synchronization retains a failed fact ahead of later facts", async () => {
	const applied: string[] = [];
	const issues: string[] = [];
	let fail = true;
	const sync = new RuntimeStateSync(
		(change) => {
			if (fail) {
				fail = false;
				throw new Error("storage unavailable");
			}
			applied.push(change.type);
			return Promise.resolve();
		},
		(_subject, error) => issues.push(error == null ? "clear" : String(error)),
	);
	await sync.submit(roomRetired("room-link")).catch(() => {});
	const reached = sync.submit({ type: "directory-reached", directoryId: "directory", locator: "locator" });
	await reached;
	await sync.close();
	assertEquals(applied, ["room-authority", "directory-reached"]);
	assertEquals(issues.some((issue) => issue.includes("storage unavailable")), true);
});
