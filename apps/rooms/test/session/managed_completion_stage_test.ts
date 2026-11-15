// A committed result that cannot be acquired names the call that failed.
import { failureView, LocalRefusal, renderFailure } from "../../lib/text/failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { AcquisitionConflict, MAX_CONFLICT_REPREPARATIONS } from "../../web/ui/session/managed/acquisition.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import { resumeEffect } from "../../web/ui/session/managed/recovery.ts";
import type { RoomsManagedCommand, RoomsManagedRecoveredEffect } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

const refusal = new Error("glowcap error -12: ApplicationRefused");

function withDirectory() {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "access",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	return current;
}

/** The failure carries its stage and its original cause, and a person reads
 * the stage in the rendered text. */
function assertNamed(failure: unknown, stage: string): void {
	assert(failure instanceof ResultAcquisitionError, `a committed result reports recovery at ${stage}`);
	assertEquals(failure.stage, stage);
	assert(failure.cause === refusal, "the original refusal stays the cause");
	const text = renderFailure(failureView(failure));
	assert(text.includes(`${stage}: ${refusal.message}`), `the page text names ${stage}: ${text}`);
}

const upload = {
	upload: "post",
	operation: "upload",
	base: 1,
	conversation: "room",
	caption: "caption",
	previews: "[]",
	keep: [],
	files: [{ name: "example.txt", mime: "text/plain", size: 4, width: 0, height: 0 }],
};
const line = { id: 7, line: "returned-line", history: null };

function lineSnapshot() {
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "room",
		directory: "directory",
		name: "garden",
		access: null,
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	return current;
}

Deno.test("an observed commit names the status call that failed", async () => {
	const operation = new ManagedOperation("known", {
		status: () => Promise.reject(refusal),
		free() {},
	} as unknown as RoomsManagedCommand, "committed");
	try {
		const [outcome] = await Promise.allSettled([operation.status()]);
		assert(outcome.status === "rejected", "the status read fails");
		assertNamed(outcome.reason, "effect-status");
	} finally {
		await operation.close();
	}
});

Deno.test("an observed commit names the result call that failed", async () => {
	const operation = new ManagedOperation("known", {
		result: () => Promise.reject(refusal),
		free() {},
	} as unknown as RoomsManagedCommand, "committed");
	try {
		const [outcome] = await Promise.allSettled([operation.result()]);
		assert(outcome.status === "rejected", "the result read fails");
		assertNamed(outcome.reason, "effect-result");
	} finally {
		await operation.close();
	}
});

Deno.test("a committed result names the adoption check that failed", async () => {
	const operation = new ManagedOperation("upload", {
		result: () => Promise.resolve(line),
		adopted: () => Promise.reject(refusal),
		originalIntent: () => upload,
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(lineSnapshot()) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the adoption check fails");
		assertNamed(outcome.reason, "effect-adopted");
	} finally {
		await operation.close();
		await session.close();
	}
});

for (const adopted of [true, false]) {
	Deno.test(`a committed result names the snapshot read that failed after adopted=${adopted}`, async () => {
		const operation = new ManagedOperation("upload", {
			result: () => Promise.resolve(line),
			adopted: () => Promise.resolve(adopted),
			originalIntent: () => upload,
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.reject(refusal) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			assert(outcome.status === "rejected", "the snapshot read fails");
			assertNamed(outcome.reason, "addressed-snapshot");
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

Deno.test("a committed result names the result acquisition that failed", async () => {
	const operation = new ManagedOperation("upload", {
		result: () => Promise.resolve(line),
		adopted: () => Promise.resolve(false),
		originalIntent: () => upload,
		prepareResultAcquisition: () => Promise.reject(refusal),
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(lineSnapshot()) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the acquisition fails");
		assertNamed(outcome.reason, "acquire-result-workspace");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a committed room names the created-room acquisition that failed", async () => {
	const operation = new ManagedOperation("creation", {
		result: () => Promise.resolve({ room: "original-room", control: "original-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["creation", 1, "openManagedRoom", ["directory", "garden"]],
		prepareCreatedRoomAcquisition: () => Promise.reject(refusal),
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(withDirectory()) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the acquisition fails");
		assertNamed(outcome.reason, "acquire-created-room");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("the stage advances with the call, so a later failure never names an earlier call", async () => {
	const calls: string[] = [];
	const operation = new ManagedOperation("upload", {
		result: () => Promise.resolve(line),
		adopted: () => {
			calls.push("adopted");
			return Promise.resolve(false);
		},
		originalIntent: () => upload,
		prepareResultAcquisition: () => {
			calls.push("prepare");
			return Promise.reject(refusal);
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({
		snapshot: () => {
			calls.push("snapshot");
			return Promise.resolve(lineSnapshot());
		},
	});
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the last call fails");
		assertEquals(calls, ["adopted", "snapshot", "prepare"], "earlier calls succeeded first");
		assertNamed(outcome.reason, "acquire-result-workspace");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a refusal the page raises on its own carries no stage and renders without a prefix", async () => {
	const operation = new ManagedOperation("creation", {
		result: () => Promise.resolve({}),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["creation", 1, "openManagedRoom", ["directory", "garden"]],
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(withDirectory()) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the receipt shape is refused");
		assert(outcome.reason instanceof ResultAcquisitionError, "the commit stays recoverable");
		assertEquals(outcome.reason.stage, null);
		assert(outcome.reason.cause instanceof LocalRefusal, "the page's own refusal stays the cause");
		const bare = failureView(new ResultAcquisitionError(undefined, new Error("self-explaining"), null));
		assertEquals(bare.detail, "self-explaining", "a null stage adds no prefix");
		assertEquals(renderFailure(failureView(outcome.reason)).includes("null"), false);
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("an exhausted acquisition conflict still carries the acquire stage", async () => {
	let attempts = 0;
	const operation = new ManagedOperation("upload", {
		result: () => Promise.resolve(line),
		adopted: () => Promise.resolve(false),
		originalIntent: () => upload,
		prepareResultAcquisition: () => {
			attempts++;
			return Promise.resolve({ submit: () => Promise.resolve({ status: "conflict" }), free() {} });
		},
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({ snapshot: () => Promise.resolve(lineSnapshot()) });
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the conflicts exhaust the retries");
		assertEquals(attempts, MAX_CONFLICT_REPREPARATIONS);
		assert(outcome.reason instanceof ResultAcquisitionError, "the commit stays recoverable");
		assertEquals(outcome.reason.stage, "acquire-result-workspace");
		assert(outcome.reason.cause instanceof AcquisitionConflict, "the conflict stays the cause");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a refresh failing after a successful acquisition names the snapshot read", async () => {
	let reads = 0;
	const operation = new ManagedOperation("upload", {
		result: () => Promise.resolve(line),
		adopted: () => Promise.resolve(false),
		originalIntent: () => upload,
		prepareResultAcquisition: () =>
			Promise.resolve({ submit: () => Promise.resolve({ status: "committed" }), free() {} }),
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({
		snapshot: () => ++reads === 1 ? Promise.resolve(lineSnapshot()) : Promise.reject(refusal),
	});
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "the final refresh fails");
		assertEquals(operation.acquired, true, "the acquisition itself committed");
		assertNamed(outcome.reason, "addressed-snapshot");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a seat that cannot identify its manager names the identity step", async () => {
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
	const operation = new ManagedOperation("manager", {
		result: () => Promise.resolve({ control: "returned-control" }),
		adopted: () => Promise.resolve(false),
		originalIntent: () => ["manager", 1, "operator", ["operator-key", "giveManager", "manager-identity"]],
		free() {},
	} as unknown as RoomsManagedCommand);
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		roomManagementIdentity: () => Promise.reject(refusal),
	});
	try {
		const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
		assert(outcome.status === "rejected", "no seat answered");
		assertNamed(outcome.reason, "managedRoomIdentity");
	} finally {
		await operation.close();
		await session.close();
	}
});

Deno.test("a committed receipt names the resume call that failed", async () => {
	const request = {
		status: () => Promise.resolve("committed"),
		resume: () => Promise.reject(refusal),
		free() {},
	} as unknown as RoomsManagedRecoveredEffect;
	const [outcome] = await Promise.allSettled([resumeEffect(request, () => {})]);
	assert(outcome.status === "rejected", "the resume fails");
	assertNamed(outcome.reason, "resume-effect");
});
