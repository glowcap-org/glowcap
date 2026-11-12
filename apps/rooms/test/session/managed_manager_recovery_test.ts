// Manager recovery attaches a returned control to exactly one saved room, or keeps the result held.
import { failureView } from "../../lib/text/failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

Deno.test("manager recovery reports a seat it could not read rather than a missing room", async () => {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		source: "source",
		access: null,
		seat: "held-seat",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	const lost = new Error("glowcap error -8: the route to the room closed");
	const operation = new ManagedOperation("manager", {
		result: () => Promise.resolve({ control: "returned-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["manager", 1, "operator", ["operator-key", "giveManager", "manager-identity"]],
		prepareResultAcquisition: () => {
			throw new Error("a recovery that matched no room prepared an acquisition");
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		roomManagementIdentity: () => Promise.reject(lost),
	});
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "a recovery that read no seat must not complete");
		assert(outcome.reason instanceof ResultAcquisitionError, "the committed receipt keeps acquisition recovery");
		assertEquals(outcome.reason.cause, lost);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("manager recovery refuses a room the session saved twice and keeps the result", async () => {
	const current = snapshot();
	for (const id of ["first", "second"]) {
		current.intent.conversations.push({
			kind: "room",
			id,
			directory: "directory",
			name: "garden",
			source: "source",
			access: null,
			seat: `${id}-seat`,
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
	}
	const operation = new ManagedOperation("manager", {
		result: () => Promise.resolve({ control: "returned-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["manager", 1, "operator", ["operator-key", "giveManager", "manager-identity"]],
		prepareResultAcquisition: () => {
			throw new Error("a recovery that matched two rooms prepared an acquisition");
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		roomManagementIdentity: () => Promise.resolve("manager-identity"),
	});
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "two saved copies cannot both take the manager result");
		assert(outcome.reason instanceof ResultAcquisitionError, "the result remains held for recovery");
		assertEquals(failureView(outcome.reason).code, "local-room-saved-twice");
		assert(
			current.intent.conversations.every((row) => row.kind !== "room" || row.control == null),
			"neither copy takes the control",
		);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a retained manager result survives its room leaving before recovery", async () => {
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareCommand: () =>
			Promise.resolve({
				submit: () => Promise.resolve({ status: "committed" }),
				status: () => Promise.resolve("committed"),
				result: () => Promise.resolve({ control: "retained-manager" }),
				adopted: () => Promise.resolve(false),
				originalIntent: () => ["manager", 1, "operator", ["operator", "giveManager", "room-identity"]],
				prepareResultAcquisition: () => {
					throw new Error("no missing room can acquire custody");
				},
				free() {},
			}),
	});
	const operation = await session.command("operator", ["operator", "giveManager", "room-identity"]);
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "a missing room cannot adopt the manager result");
		assert(outcome.reason instanceof ResultAcquisitionError, "the result remains held for recovery");
		assertEquals(failureView(outcome.reason.cause).code, "local-target-gone-held");
		assertEquals(failureView(outcome.reason).code, "local-target-gone-held");
	} finally {
		await operation.close();
		await session.close();
	}
});
