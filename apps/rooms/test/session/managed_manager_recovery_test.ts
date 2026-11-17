// A recovered manager lands in exactly the room its request was admitted for, or the result stays held.
import { failureView } from "../../lib/text/failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

type Conversation = ReturnType<typeof snapshot>["intent"]["conversations"][number];

function room(id: string, extra: Record<string, unknown> = {}): Conversation {
	return {
		kind: "room",
		id,
		directory: "directory",
		name: "garden",
		source: "source",
		access: "entrance",
		seat: `${id}-seat`,
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
		...extra,
	} as Conversation;
}
/** The request a recovery was admitted with: the operator and the room it names. */
function recovery(witness: Record<string, unknown>, acquisition: (intent: string) => void) {
	return new ManagedOperation("manager", {
		result: () => Promise.resolve({ control: "returned-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["manager", 1, "recoverRoomManager", ["operator-key", JSON.stringify(witness)]],
		prepareResultAcquisition: (_revision: string, _mappings: string, _releases: string, intent: string) => {
			acquisition(intent);
			return Promise.resolve({ submit: () => Promise.resolve({ status: "committed" }), free() {} });
		},
		free() {},
	} as unknown as RoomsManagedCommand);
}
const witness = (id: string) => ({
	id,
	directory: "directory",
	source: "source",
	seat: `${id}-seat`,
	access: "entrance",
});
type Intent = ReturnType<typeof snapshot>["intent"];

Deno.test("a recovered manager lands in its admitted room after the seat was lost", async () => {
	const current = snapshot();
	current.intent.conversations.push(room("room", { seat: undefined }));
	let candidate: Intent | undefined;
	const operation = recovery(witness("room"), (intent) => candidate = JSON.parse(intent));
	const session = viewer({
		snapshot: () => Promise.resolve(current),
	});
	try {
		await completeResult(session, operation);
		const row = candidate?.conversations.find((row) => row.id === "room");
		assert(row?.kind === "room" && row.control != null, "the admitted room took the manager");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a recovered manager lands in its admitted room, never in another room of the same name", async () => {
	const current = snapshot();
	current.intent.conversations.push(room("first", { access: "other-entrance" }), room("second"));
	let candidate: Intent | undefined;
	const operation = recovery(witness("second"), (intent) => candidate = JSON.parse(intent));
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		await completeResult(session, operation);
		const controls = candidate?.conversations.map((row) => row.kind === "room" && row.control != null);
		assertEquals(controls, [false, true]);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a recovered manager is held after its room leaves", async () => {
	const current = snapshot();
	const operation = recovery(witness("room"), () => {
		throw new Error("a result that matched no admitted room prepared an acquisition");
	});
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the result cannot land");
		assert(outcome.reason instanceof ResultAcquisitionError, "the result remains held for recovery");
		assertEquals(failureView(outcome.reason).code, "local-target-gone-held");
	} finally {
		await operation.close();
		await session.close();
	}
});

const bare = (id: string) => {
	const { access: _access, ...rest } = witness(id);
	return rest;
};
async function landing(witnessed: Record<string, unknown>, row: Record<string, unknown>) {
	const current = snapshot();
	current.intent.conversations.push(room("room", row));
	let candidate: Intent | undefined;
	const operation = recovery(witnessed, (intent) => candidate = JSON.parse(intent));
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		return {
			outcome,
			landed: candidate !== undefined,
			view: outcome.status === "rejected" ? failureView(outcome.reason) : null,
		};
	} finally {
		await operation.close();
		await session.close();
	}
}

Deno.test("a no-entrance recovery is held with its own advice when the seat is lost or replaced", async () => {
	for (const row of [{ access: undefined, seat: undefined }, { access: undefined, seat: "another-seat" }]) {
		const { outcome, landed, view } = await landing(bare("room"), row);
		assert(outcome.status === "rejected" && outcome.reason instanceof ResultAcquisitionError, "the result is held");
		assertEquals(landed, false);
		assertEquals(view?.code, "local-recovery-seat-lost");
		assertEquals(view?.retry, "never");
		assert(
			/Let go/.test(view?.summary ?? "") && /rejoin/.test(view?.summary ?? ""),
			"advice names the next action",
		);
		assert(/doesn't revoke/.test(view?.summary ?? ""), "advice does not claim revocation");
	}
});

Deno.test("a no-entrance recovery lands while its seat stands", async () => {
	const { outcome, landed } = await landing(bare("room"), { access: undefined });
	assertEquals(outcome.status, "fulfilled");
	assertEquals(landed, true);
});

Deno.test("an entrance-backed recovery still lands after its seat is lost, leaving the runtime the authority", async () => {
	const { landed } = await landing(witness("room"), { seat: undefined });
	assertEquals(landed, true);
});

Deno.test("a seat-lost recovery stays releasable", async () => {
	const current = snapshot();
	current.intent.conversations.push(room("room", { access: undefined, seat: undefined }));
	const released: string[] = [];
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		recoverEffect: (id: string) =>
			Promise.resolve({
				status: () => Promise.resolve("committed"),
				resume: () => Promise.resolve("committed"),
				release: () => {
					released.push(id);
					return Promise.resolve();
				},
				free() {},
			}),
	});
	const request = oldRecovery([]);
	request.originalIntent = () => ["manager", 1, "recoverRoomManager", ["operator-key", JSON.stringify(bare("room"))]];
	request.prepareResultAcquisition = () => {
		throw new Error("a seat-lost result prepared an acquisition");
	};
	let status = "failed";
	Object.assign(request, {
		status: () => Promise.resolve(status),
		submit: () => Promise.resolve({ status: "unknown" }),
	});
	await Promise.allSettled([session.perform("manager", () => Promise.resolve(request))]);
	assertEquals(session.recoverable, ["manager"]);
	status = "committed";
	const [outcome] = await Promise.allSettled([session.completeOperation("manager")]);
	assertEquals(outcome.status === "rejected" && failureView(outcome.reason).code, "local-recovery-seat-lost");
	assertEquals(session.recoverable, ["manager"]);
	await session.releaseOperation("manager");
	assertEquals(released, ["manager"]);
	assertEquals(session.recoverable, []);
	await session.close();
});

/** A receipt an older Rooms wrote: the generic operator request that carried the manager identity. */
function oldRecovery(acquisitions: string[]) {
	return {
		result: () => Promise.resolve({ control: "returned-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["old", 1, "operator", ["operator-key", "giveManager", "manager-identity"]],
		prepareResultAcquisition: (_revision: string, _mappings: string, _releases: string, intent: string) => {
			acquisitions.push(intent);
			return Promise.resolve({ submit: () => Promise.resolve({ status: "committed" }), free() {} });
		},
		free() {},
	} as unknown as RoomsManagedCommand;
}

Deno.test("an old operator recovery result is refused, never acquired or taken as success", async () => {
	const current = snapshot();
	current.intent.conversations.push(room("room"));
	const acquisitions: string[] = [];
	const operation = new ManagedOperation("old", oldRecovery(acquisitions));
	const session = viewer({ snapshot: () => Promise.resolve(current) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "an old recovery reported success");
		assert(outcome.reason instanceof ResultAcquisitionError, "the result remains held");
		assertEquals(failureView(outcome.reason).code, "local-old-manager-recovery");
		assertEquals(acquisitions, []);
		assertEquals(operation.acquiring, false);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("other operator results still complete without acquiring anything", async () => {
	const acquisitions: string[] = [];
	const request = oldRecovery(acquisitions);
	request.originalIntent = () => ["other", 1, "operator", ["operator-key", "somethingElse", "x"]];
	const operation = new ManagedOperation("other", request);
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	try {
		assertEquals(await completeResult(session, operation), { control: "returned-control" });
		assertEquals(acquisitions, []);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("resuming an old held recovery stays held and can be released", async () => {
	const current = snapshot();
	current.intent.conversations.push(room("room"));
	const acquisitions: string[] = [];
	const released: string[] = [];
	let status = "failed";
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		recoverEffect: (id: string) =>
			Promise.resolve({
				status: () => Promise.resolve("committed"),
				resume: () => Promise.resolve("committed"),
				release: () => {
					released.push(id);
					return Promise.resolve();
				},
				free() {},
			}),
	});
	const request = oldRecovery(acquisitions);
	Object.assign(request, {
		status: () => Promise.resolve(status),
		submit: () => Promise.resolve({ status: "unknown" }),
	});
	await Promise.allSettled([session.perform("old", () => Promise.resolve(request))]);
	assertEquals(session.recoverable, ["old"]);
	status = "committed";
	const [outcome] = await Promise.allSettled([session.completeOperation("old")]);
	assert(outcome.status === "rejected", "resuming an old recovery reported success");
	assertEquals(failureView(outcome.reason).code, "local-old-manager-recovery");
	assertEquals(acquisitions, []);
	assertEquals(session.recoverable, ["old"], "the held result was forgotten");
	await session.releaseOperation("old");
	assertEquals(released, ["old"]);
	assertEquals(session.recoverable, []);
	assertEquals(current.intent.conversations.some((row) => row.kind === "room" && row.control != null), false);
	await session.close();
});
