// Completion carries only the scalar witness from its exact accepted candidate.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../web/ui/session/managed/operation.ts";
import { AcquisitionConflict } from "../../web/ui/session/managed/acquisition.ts";
import { CompletedLine } from "../../web/ui/session/managed/completed_line.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

for (const kind of ["room", "direct"] as const) {
	for (const change of ["none", "refresh", "presentation", "uncertain", "other viewer"] as const) {
		Deno.test(`${kind} line completion fences ${change} against its acquired field`, async () => {
			const current = snapshot();
			const common = {
				id: "conversation",
				directory: "directory",
				access: "access",
				source: "source",
				inbox: "inbox",
				draft: "",
				standing: null,
			};
			current.intent.conversations.push(
				kind === "room"
					? { ...common, kind, name: "garden", control: null, reconnect: "requested", seat: "seat" }
					: { ...common, kind, peer: "bob", closed: false, lines: [{ id: 7, handle: "sender-origin" }] },
			);
			const history = { source: "archive", generation: "original", id: "7" };
			let submissions = 0;
			let acquired = false;
			const replace = () => {
				const row = current.intent.conversations[0];
				row.inbox = "replacement-inbox";
				if (row.kind === "room") row.seat = "replacement-seat";
				else row.access = "replacement-access";
				row.lines = [{ id: 7, handle: "replacement-line" }];
			};
			const operation = new ManagedOperation("send", {
				result: () => Promise.resolve({ id: 7, line: "receipt-line", history }),
				adopted: () => Promise.resolve(change === "other viewer"),
				originalIntent: () => ["send", 1, "say", ["conversation", "hello"]],
				prepareResultAcquisition: (_revision: string, _imports: string, _dropped: string, intent: string) => {
					return Promise.resolve({
						submit: () => {
							submissions++;
							current.intent = JSON.parse(intent);
							acquired = true;
							return change === "uncertain" && submissions === 1
								? Promise.reject(new Error("reply lost after acquisition"))
								: Promise.resolve("committed");
						},
						free() {},
					});
				},
				free() {},
			} as unknown as RoomsManagedCommand);
			const session = viewer({
				snapshot: () => {
					if (acquired && change === "refresh") replace();
					return Promise.resolve(current);
				},
			});
			try {
				if (change === "uncertain") {
					assertEquals(
						(await Promise.allSettled([completeResult(session, operation)]))[0].status,
						"rejected",
					);
					await operation.retryAcquisition();
				}
				const completed = await completeResult(session, operation);
				assert(completed instanceof CompletedLine, "completion retains line delivery evidence");
				operation.finish();
				if (change === "presentation") replace();
				const live = change === "none" || change === "uncertain";
				assertEquals(completed.receipt(session.current), { id: live ? 7 : undefined, history, held: live });
				assertEquals(submissions, change === "other viewer" ? 0 : change === "uncertain" ? 2 : 1);
				if (live) {
					// The numeric identity alone cannot authorize the replacement field.
					current.intent.conversations[0].lines = [{ id: 7, handle: "different-field" }];
					assertEquals(completed.receipt(session.current), { id: undefined, history, held: false });
				}
			} finally {
				await operation.close();
				await session.close();
			}
		});
	}
}

for (const failure of ["result read", "preparation", "submission", "conflicts", "refresh"] as const) {
	Deno.test(`completion preserves delivery evidence after ${failure} failure`, async () => {
		const current = snapshot();
		current.intent.conversations.push({
			kind: "room",
			id: "conversation",
			directory: "directory",
			name: "garden",
			access: "access",
			source: "source",
			seat: "seat",
			inbox: "inbox",
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		const result = { id: 7, line: "returned-field" };
		const reason = new Error("original failure");
		let reads = 0;
		let preparations = 0;
		let submissions = 0;
		const operation = new ManagedOperation("post", {
			result: () => {
				reads++;
				return failure === "result read" ? Promise.reject(reason) : Promise.resolve(result);
			},
			adopted: () => Promise.resolve(false),
			originalIntent: () => ["post", 1, "say", ["conversation", "hello"]],
			prepareResultAcquisition: () => {
				preparations++;
				if (failure === "preparation") return Promise.reject(reason);
				return Promise.resolve({
					submit: () => {
						submissions++;
						return failure === "submission"
							? Promise.reject(reason)
							: Promise.resolve(failure === "conflicts" ? "conflict" : "committed");
					},
					free() {},
				});
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({
			snapshot: () => operation.acquired ? Promise.reject(reason) : Promise.resolve(current),
		});
		try {
			const outcome = (await Promise.allSettled([completeResult(session, operation)]))[0];
			assert(outcome.status === "rejected", "the failed completion cannot report acquisition success");
			if (failure === "result read") {
				assert(outcome.reason === reason, "an unread result does not establish delivery");
			} else {
				assert(
					outcome.reason instanceof ResultAcquisitionError,
					"committed evidence crosses the failure boundary",
				);
				assert(outcome.reason.result === result, "the failure borrows the exact result, without copying it");
				if (failure === "conflicts") {
					assert(outcome.reason.cause instanceof AcquisitionConflict, "conflict cause survives");
				} else assert(outcome.reason.cause === reason, "the original failure stays available");
			}
			assertEquals(reads, 1, "candidate conflicts do not reread the committed result");
			assertEquals(preparations, failure === "result read" ? 0 : failure === "conflicts" ? 4 : 1);
			assertEquals(
				submissions,
				failure === "result read" || failure === "preparation" ? 0 : failure === "conflicts" ? 4 : 1,
			);
		} finally {
			await operation.close();
			await session.close();
		}
	});
}
