// Attached history invalidation is scoped, coalesced, and retired with the projection that requested it.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import { type HistoryChange, parseHistoryChange } from "../../lib/session/history.ts";
import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import type { ArchiveLine } from "../../lib/archive/protocol.ts";
import type { AttachedRoomsController } from "../../web/ui/session/attached.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";

Deno.test("history invalidation admits only whole-account or bounded conversation scopes", () => {
	assertEquals(parseHistoryChange([]), null);
	for (const kind of ["room", "direct"]) {
		assertEquals(parseHistoryChange([kind, "directory", "conversation"]), {
			kind,
			directory: "directory",
			conversation: "conversation",
		});
	}
	for (
		const args of [
			[null],
			["standing", "d", "c"],
			["room", "", "c"],
			["room", 3, "c"],
			["room", "d", "a".repeat(513)],
			["direct", "é".repeat(4097), "c"],
			["room", "d", "c", 1],
		]
	) {
		assertEquals(
			(() => {
				try {
					parseHistoryChange(args);
					return false;
				} catch {
					return true;
				}
			})(),
			true,
		);
	}
});

Deno.test("history invalidations coalesce across reads, preserve scope and stop with their projection", async () => {
	Object.defineProperty(globalThis, "matchMedia", {
		configurable: true,
		value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
	});
	const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
	const { RoomsPage } = await import("../../web/ui/page.ts");
	const store = await import("../../web/ui/store.ts");
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const conversations = Array.from({ length: 6 }, (_, index) => ({
		kind: "room" as const,
		id: `room-${index}`,
		directory: "directory",
		name: `room-${index}`,
		held: false,
		standing: null,
		draft: "",
	}));
	const snapshot = roomsSessionSnapshot({
		checkpoint: {
			...emptyRoomsSessionState(),
			directories: [{ id: "directory", locator: "127.0.0.1:3", home: true, nick: "ada", standing: null }],
			conversations,
		},
	});
	let changed!: (snapshot: RoomsSessionSnapshot) => void;
	let invalidated!: (change: HistoryChange) => void;
	const reads: string[] = [];
	const pending = new Map<string, (records: ArchiveLine[]) => void>();
	let active = 0;
	let maximum = 0;
	const controller = {
		onSnapshot(listener: typeof changed) {
			changed = listener;
			return () => {};
		},
		onHistoryInvalidated(listener: typeof invalidated) {
			invalidated = listener;
			return () => {
				invalidated = () => {};
			};
		},
		onLine() {
			return () => {};
		},
		ignoredNickname() {
			return undefined;
		},
		pendingDraft() {
			return undefined;
		},
		readHistory(_kind: string, _directory: string, conversation: string) {
			reads.push(conversation);
			active += 1;
			maximum = Math.max(maximum, active);
			return new Promise<ArchiveLine[]>((resolve) => pending.set(conversation, resolve)).finally(() => {
				active -= 1;
			});
		},
	} as unknown as AttachedRoomsController;
	const stop = projection.bind(controller);
	const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
	const scope = (conversation: string): HistoryChange => ({ kind: "room", directory: "directory", conversation });
	const line = (conversation: string, text: string): ArchiveLine => ({
		kind: "line",
		source: "archive",
		generation: "generation",
		id: "line",
		conversationKind: "room",
		directory: "directory",
		conversation,
		from: "bo",
		text,
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [],
	});
	const answer = (conversation: string, text: string) => {
		const resolve = pending.get(conversation);
		if (resolve == null) throw new Error(`no read for ${conversation}`);
		pending.delete(conversation);
		resolve([line(conversation, text)]);
	};
	const texts = (id: string) => {
		const conv = [...page.projection.get().convs.values()].find((conv) =>
			conv.type !== "directory" && conv.persistId === id
		);
		return store.historyOf(page.projection, conv?.key ?? "").filter((item) => item.kind === "chat").map((item) =>
			item.text
		);
	};
	try {
		changed(snapshot);
		assertEquals(reads.length, 4);
		for (let i = 0; i < 10; i++) invalidated(scope("room-0"));
		assertEquals(reads.length, 4, "invalidating an active read must not add parallel copies");
		answer("room-0", "stale");
		await tick();
		assertEquals(texts("room-0"), [], "an invalidated result must not enter the projection");
		assertEquals(reads[4], "room-4", "a repeatedly invalidated conversation cannot starve initial history reads");
		while (pending.size !== 0) {
			for (const id of [...pending.keys()]) answer(id, "fresh");
			await tick();
		}
		assertEquals(maximum, 4);
		assertEquals(reads.filter((id) => id === "room-0").length, 2);
		assertEquals(reads.length, 7);
		assertEquals(texts("room-0"), ["fresh"]);
		invalidated({ kind: "direct", directory: "directory", conversation: "room-0" });
		invalidated({ kind: "room", directory: "another", conversation: "room-0" });
		assertEquals(reads.length, 7, "both kind and directory belong to history identity");
		invalidated(scope("room-0"));
		answer("room-0", "committed later");
		await tick();
		assertEquals(texts("room-0"), ["committed later"]);
		invalidated(null);
		assertEquals(pending.size, 4);
		stop();
		for (const id of [...pending.keys()]) answer(id, "after stop");
		await tick();
		assertEquals(pending.size, 0, "stopping retires queued reads too");
		assertEquals(texts("room-0"), ["committed later"]);
	} finally {
		stop();
		for (const resolve of pending.values()) resolve([]);
		await tick();
		for (const key of page.projection.get().convs.keys()) store.forgetConv(page.projection, key);
	}
});
