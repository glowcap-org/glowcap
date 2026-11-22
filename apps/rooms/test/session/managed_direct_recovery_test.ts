// Reconnection changes live custody, preserving data only for the same peer.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import { ManagedActions } from "../../web/ui/session/managed/actions.ts";
import { cannotSendRegistrationEnded } from "../../lib/text/conversation.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import type { DirectIntent } from "../../web/ui/session/managed/model.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import { acquireDirect } from "../../web/ui/session/managed/direct.ts";

function saved() {
	const current = snapshot();
	current.intent.directories.push({
		id: "directory",
		access: "directory-access",
		source: "directory-source",
		name: "local-name",
		inbox: "local-callback",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const row: DirectIntent = {
		kind: "direct",
		id: "saved",
		directory: "directory",
		peer: "bob",
		source: "old-source",
		access: null,
		closed: true,
		draft: "saved draft",
		introduction: {
			access: "directory-access",
			name: "old-name",
			callback: "old-callback",
			registration: "peer-registration",
			opening: "old-opening",
		},
	};
	current.intent.conversations.push(row);
	current.intent.active = row.id;
	return current;
}

for (const change of ["none", "draft", "source", "removed", "peer"] as const) {
	Deno.test(`direct reconnect adoption preserves data and fences ${change} during conflict`, async () => {
		const current = saved();
		if (change === "peer") {
			(current.intent.conversations[0] as DirectIntent).introduction!.registration = "different-peer";
		}
		let preparations = 0;
		const operation = new ManagedOperation("reconnect", {
			result: () => Promise.resolve({ inbox: "new-route" }),
			adopted: () => Promise.resolve(false),
			originalIntent:
				() => ["reconnect", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]],
			prepareResultAcquisition: (_revision: string, _imports: string, _releases: string, intent: string) => {
				preparations++;
				return Promise.resolve({
					submit: () => {
						if (preparations === 1 && change !== "none" && change !== "peer") {
							current.revision = "2";
							if (change === "draft") current.intent.conversations[0].draft = "latest draft";
							if (change === "source") current.intent.conversations[0].source = "replacement-source";
							if (change === "removed") current.intent.conversations = [];
							return Promise.resolve({ status: "conflict" });
						}
						current.intent = JSON.parse(intent);
						return Promise.resolve({ status: "committed" });
					},
					free() {},
				});
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			const [outcome] = await Promise.allSettled([completeResult(session, operation)]);
			if (change === "source" || change === "removed") {
				assertEquals(outcome.status, "rejected");
				assertEquals(preparations, 1, "changed targets cannot acquire the old result");
				assertEquals(operation.acquired, false);
			} else {
				assertEquals(outcome.status, "fulfilled");
				assertEquals(current.intent.conversations.length, change === "peer" ? 2 : 1);
				const row = current.intent.conversations.at(-1) as DirectIntent;
				assertEquals(
					[row.id, row.draft],
					change === "peer"
						? ["reconnect", ""]
						: ["saved", change === "draft" ? "latest draft" : "saved draft"],
				);
				assert(!row.closed && row.access != null, "only committed route custody reopens the conversation");
				assertEquals(row.introduction?.registration, "peer-registration");
				assertEquals(row.introduction?.opening, "new-opening");
				assertEquals(current.intent.active, "saved", "adoption is independent of navigation");
			}
		} finally {
			await operation.close();
			await session.close();
		}
	});
}

Deno.test("direct reconnect refuses a reused name before introduction", async () => {
	const current = saved();
	let freed = 0;
	let introduced = 0;
	const session = {
		execute: async (
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation) => Promise<void>,
			continuation?: { settled(): Promise<void> },
		) => {
			await complete(await prepare());
			await continuation?.settled();
		},
		refresh: () => Promise.resolve(current),
		workspace: {
			directoryReader: () =>
				Promise.resolve({ memberRegistration: () => Promise.resolve("different-peer"), free: () => freed++ }),
		},
		command: () => {
			introduced++;
			throw new Error("unexpected introduction");
		},
	} as unknown as ManagedRoomsSession;
	const [outcome] = await Promise.allSettled([
		new ManagedActions(session).direct("directory", "bob", false, "peer-registration"),
	]);
	assertEquals(outcome.status, "rejected");
	if (outcome.status === "rejected") {
		assert(outcome.reason instanceof LocalRefusal, "a reused name is a refusal the page words");
		assertEquals(outcome.reason.message, cannotSendRegistrationEnded);
	}
	assertEquals([freed, introduced], [1, 0]);
});

Deno.test("direct action returns the adopted conversation identity after reconnect", async () => {
	const current = saved();
	let opening = "";
	const selected: string[] = [];
	const session = {
		execute: async (
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation) => Promise<void>,
			continuation?: { settled(): Promise<void> },
		) => {
			await complete(await prepare());
			await continuation?.settled();
		},
		refresh: () => Promise.resolve(current),
		workspace: {
			directoryReader: () =>
				Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
		},
		command: (_name: string, args: string[]) => {
			opening = args[3];
			return Promise.resolve({
				id: "receipt",
				result: () => Promise.resolve({ inbox: "route" }),
			});
		},
		completeResult: () => {
			const row = current.intent.conversations[0] as DirectIntent;
			row.closed = false;
			row.access = "route";
			row.introduction!.opening = opening;
			return Promise.resolve();
		},
		navigation: {
			select: (id: string) => {
				selected.push(id);
				return Promise.resolve();
			},
		},
	} as unknown as ManagedRoomsSession;
	assertEquals(await new ManagedActions(session).direct("directory", "bob", true, "peer-registration"), "saved");
	assertEquals(selected, ["saved"]);
});

/** The saved row open, introduced under the directory's earlier contact. The
 * member opened it when the session accepted their introduction and holds no
 * route yet. This session opened it when it holds the member's route. */
function open(opener: "member" | "session") {
	const current = saved();
	const row = current.intent.conversations[0] as DirectIntent;
	row.closed = false;
	row.peer = "Bob";
	if (opener === "session") row.access = "old-route";
	else row.introduction!.opening = "their-opening";
	return current;
}

for (const opener of ["member", "session"] as const) {
	Deno.test(`a direct route given back to the row the ${opener} opened releases its receipt`, async () => {
		const current = open(opener);
		const before = structuredClone(current.intent);
		let released = 0;
		const operation = new ManagedOperation("again", {
			result: () => Promise.resolve({ inbox: "surplus-route" }),
			adopted: () => Promise.resolve(false),
			originalIntent: () => ["again", 1, "startDirect", ["directory", "bob", "peer-registration", "new-opening"]],
			prepareResultAcquisition: () => {
				throw new Error("a second open row was prepared");
			},
			release: () => {
				released++;
				return Promise.resolve();
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		try {
			await completeResult(session, operation);
			assertEquals([released, operation.acquired], [1, false]);
			assertEquals(current.intent, before);
		} finally {
			await operation.close();
			await session.close();
		}
	});

	Deno.test(`a direct action reaches the row the ${opener} opened after the directory registers again`, async () => {
		const current = open(opener);
		let introduced = 0;
		const session = {
			refresh: () => Promise.resolve(current),
			workspace: {
				directoryReader: () =>
					Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
			},
			command: () => {
				introduced++;
				throw new Error("unexpected introduction");
			},
		} as unknown as ManagedRoomsSession;
		assertEquals(await acquireDirect(session, "directory", "bob"), "saved");
		assertEquals(introduced, 0);
	});
}

Deno.test("an opening whose route was given back does not own the row it reaches", async () => {
	const current = saved();
	const acquired: string[] = [];
	const session = {
		execute: async (
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation) => Promise<void>,
			continuation?: { settled(): Promise<void> },
		) => {
			await complete(await prepare());
			await continuation?.settled();
		},
		refresh: () => Promise.resolve(current),
		workspace: {
			directoryReader: () =>
				Promise.resolve({ memberRegistration: () => Promise.resolve("peer-registration"), free() {} }),
		},
		command: () => Promise.resolve({ id: "receipt", result: () => Promise.resolve({ inbox: "route" }) }),
		// The member opened the conversation while this command ran, so the
		// route went back and the row keeps the member's opening.
		completeResult: () => {
			const row = current.intent.conversations[0] as DirectIntent;
			row.closed = false;
			row.introduction!.opening = "their-opening";
			return Promise.resolve();
		},
	} as unknown as ManagedRoomsSession;
	const opening = {
		acquired: (id: string) => {
			acquired.push(id);
			return Promise.resolve();
		},
	} as unknown as ConversationOpening;
	assertEquals(await acquireDirect(session, "directory", "bob", undefined, opening), "saved");
	assertEquals(acquired, []);
});
