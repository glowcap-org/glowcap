// Line projection releases every rejected or replaced capability occurrence it was handed.
/// <reference lib="dom" />

import type { Attachment } from "../../lib/attachment.ts";
import type { RoomsSessionLineEvent } from "../../lib/session/client.ts";
import type { AttachedRoomsController } from "../../web/ui/session/attached.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const { AttachedSessionFiles, EARLIER_CONNECTION_BYTES_UNAVAILABLE } = await import(
	"../../web/ui/session/attached_files.ts"
);
const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { reconcileAttachedHistory } = await import("../../web/ui/session/history_reconciliation.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");

function attachment(name: string): Attachment {
	return { name, mime: "text/plain", size: 1, width: 0, height: 0, blob: {} as Attachment["blob"] };
}

function event(name: string, overrides: Partial<RoomsSessionLineEvent> = {}): RoomsSessionLineEvent {
	return {
		source: "lines",
		sequence: 1,
		conversationId: "room-id",
		from: "bo",
		text: name,
		at: 1,
		lineId: 1,
		change: "said",
		editable: false,
		history: null,
		system: false,
		previewUrls: [],
		attachments: [attachment(name)],
		...overrides,
	};
}

Deno.test("attached line projection releases rejected and replaced capability occurrences", () => {
	const page = new RoomsPage();
	page.projection.set({
		...store.initialState(),
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const released: string[] = [];
	const controller = {
		releaseAttachment: (file: Attachment) => released.push(file.name),
	} as unknown as AttachedRoomsController;
	const files = new AttachedSessionFiles(controller, page.projection);
	const projection = new AttachedSessionProjection(page, files);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "room-id",
			directory: "directory",
			name: "general",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "room-id",
	};
	projection.apply(roomsSessionSnapshot({ checkpoint }));
	const room = store.activeConv(page.projection);
	if (room?.type !== "room") throw new Error("the line-custody fixture created no room");
	store.patchDir(page.projection, room.dir, { nick: "ada", session: "connected" });
	const optimistic = store.chatItem(
		page.projection,
		"ada",
		"pending words",
		true,
		"sending",
		undefined,
		undefined,
		["https://preview.example/"],
	);
	const optimisticAt = optimistic.at;
	const optimisticHistory = { source: "archive", generation: "pending", id: "pending-line" };
	store.deliver(page.projection, room.key, optimistic);
	projection.line(event("unused", {
		from: "ada",
		text: "pending words",
		at: optimisticAt + 60_000,
		lineId: 2,
		history: optimisticHistory,
		attachments: [],
		editable: true,
	}));
	const confirmed = store.historyOf(page.projection, room.key).find((item) => item.id === optimistic.id);
	assertEquals(
		confirmed?.kind === "chat"
			? [
				confirmed.state,
				confirmed.lineId,
				confirmed.held,
				confirmed.at,
				confirmed.history,
				confirmed.previewUrls,
			]
			: null,
		[
			undefined,
			2,
			true,
			optimisticAt,
			optimisticHistory,
			[],
		],
	);
	assertEquals(
		store.historyOf(page.projection, room.key).filter((item) =>
			item.kind === "chat" && item.text === "pending words"
		)
			.length,
		1,
		"the authoritative echo duplicated its optimistic intent",
	);
	reconcileAttachedHistory(page, room.key, [{
		kind: "line",
		...optimisticHistory,
		conversationKind: "room",
		directory: "directory",
		conversation: "room-id",
		from: "ada",
		text: "pending words",
		mine: true,
		at: optimisticAt + 60_000,
		order: 2,
		state: "present",
		previewUrls: [],
		attachments: [],
	}], files);
	assertEquals(
		store.historyOf(page.projection, room.key).filter((item) =>
			item.kind === "chat" && item.text === "pending words"
		).length,
		1,
		"archive replay duplicated the confirmed optimistic intent",
	);

	projection.line(event("unknown.txt", { conversationId: "unknown" }));
	projection.line(event("typing.txt", {
		text: "",
		lineId: null,
		change: null,
		system: true,
		presence: { kind: "typing", name: "bo", on: true },
	}));
	projection.line(event("system.txt", { system: true }));
	projection.line(event("missing-refile.txt", { lineId: 99, change: "refiled" }));
	projection.line(event("oversized-name.txt", { from: "x".repeat(257) }));
	assertEquals(released, ["unknown.txt", "typing.txt", "system.txt", "missing-refile.txt", "oversized-name.txt"]);
	store.patchDir(page.projection, room.dir, { session: "disconnected" });
	projection.line(event("late.txt", { lineId: 3 }));
	const late = store.historyOf(page.projection, room.key).find((item) =>
		item.kind === "chat" && item.text === "late.txt"
	);
	assertEquals(
		late?.kind === "chat" ? [late.attachments?.[0]?.lost, late.attachments?.[0]?.error] : null,
		[true, EARLIER_CONNECTION_BYTES_UNAVAILABLE],
		"a late event resurrected file authority from a disconnected directory",
	);
	assertEquals(released.at(-1), "late.txt");
	store.patchDir(page.projection, room.dir, { session: "connected" });

	const oldFile = attachment("archived.txt");
	const oldView = files.hold(oldFile);
	const history = { source: "archive", generation: "generation", id: "line" };
	store.deliver(page.projection, room.key, {
		...store.chatItem(page.projection, "bo", "archived", false, undefined, [oldView]),
		history,
	});
	projection.line(event("live.txt", { history }));
	assertEquals(released.at(-1), oldFile.name);
	const live = store.historyOf(page.projection, room.key).find((item) =>
		item.kind === "chat" && item.history?.id === "line"
	);
	assertEquals(live?.kind === "chat" ? live.attachments?.[0]?.name : null, "live.txt");
	const liveView = live?.kind === "chat" ? live.attachments?.[0] : undefined;
	projection.line(event("live.txt", { history }));
	const replayed = store.historyOf(page.projection, room.key).find((item) =>
		item.kind === "chat" && item.history?.id === "line"
	);
	assertEquals(
		replayed?.kind === "chat" ? replayed.attachments?.[0]?.id : null,
		liveView?.id,
		"replaying one line replaced its settled attachment view",
	);
	assertEquals(released.at(-1), "live.txt", "the replayed capability occurrence was not released");

	const firstPreview = "https://example.com/first";
	const secondPreview = "https://example.com/second";
	projection.line(event("previews", {
		text: `${firstPreview} ${secondPreview}`,
		lineId: 4,
		previewUrls: [firstPreview, secondPreview],
		attachments: [],
	}));
	const previewUrls = () => {
		const item = store.historyOf(page.projection, room.key).find((candidate) =>
			candidate.kind === "chat" && candidate.lineId === 4
		);
		return item?.kind === "chat" ? item.previewUrls : null;
	};
	assertEquals(previewUrls(), [firstPreview, secondPreview]);
	projection.line(event("previews-edited", {
		text: secondPreview,
		lineId: 4,
		change: "edited",
		previewUrls: [secondPreview],
		attachments: [],
	}));
	assertEquals(previewUrls(), [secondPreview]);
	projection.line(event("previews-withdrawn", {
		text: "",
		lineId: 4,
		change: "withdrawn",
		previewUrls: [],
		attachments: [],
	}));
	assertEquals(previewUrls(), undefined);
	store.clearHistory(page.projection, room.key);
	assertEquals(released.at(-1), "live.txt");
	files.close();
});
