// Line projection releases every rejected or replaced capability occurrence it was handed.
/// <reference lib="dom" />

import type { Attachment } from "../../lib/attachment.ts";
import type { PresentedLine } from "../../web/ui/session/line_projection.ts";
type RoomsSessionLineEvent = PresentedLine<Attachment>;
import type { FileSources } from "../../web/ui/session/attached_files.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionFiles, EARLIER_CONNECTION_BYTES_UNAVAILABLE } = await import(
	"../../web/ui/session/attached_files.ts"
);
const { AttachedLineProjection } = await import("../../web/ui/session/line_projection.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { reconcileAttachedHistory } = await import("../../web/ui/session/history_reconciliation.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");

function attachment(name: string): Attachment {
	return { name, mime: "text/plain", size: 1, width: 0, height: 0, blob: {} as Attachment["blob"] };
}

function event(name: string, overrides: Partial<RoomsSessionLineEvent> = {}): RoomsSessionLineEvent {
	return {
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
	} as unknown as FileSources<Attachment>;
	const files = new AttachedSessionFiles(controller, page.projection);
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	const room = store.ensureRoom(page.projection, directory, "general", { persistId: "room-id" });
	store.switchTo(page.projection, room.key);
	const projection = new AttachedLineProjection(
		(id) => store.convByPersistId(page.projection, id)?.key ?? null,
		files,
		page,
	);
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
	projection.apply(event("unused", {
		from: "ada",
		text: "pending words",
		at: optimisticAt + 60_000,
		lineId: 2,
		history: optimisticHistory,
		attachments: [],
		editable: true,
	}));
	store.confirmSentLine(page.projection, room.key, optimistic.id, { id: 2, held: true });
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
			undefined,
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

	const placeholder = store.attachmentView(page.projection, { name: "pending.txt", mime: "text/plain", size: 1 });
	const uploading = store.chatItem(page.projection, "ada", "pending upload", true, "sending", [placeholder]);
	store.deliver(page.projection, room.key, { ...uploading, awaitingReceipt: true });
	const uploadHistory = { source: "upload", generation: "generation", id: "4" };
	projection.apply(event("pending.txt", { from: "ada", text: "pending upload", lineId: 4, history: uploadHistory }));
	const pending = store.historyOf(page.projection, room.key).find((item) => item.id === uploading.id);
	assertEquals(
		pending?.kind === "chat" ? pending.state : null,
		"sending",
		"the echo cannot settle the upload receipt",
	);
	store.confirmSentLine(page.projection, room.key, uploading.id, { id: 4, held: true });
	const echoed = store.historyOf(page.projection, room.key).find((item) => item.id === uploading.id);
	assertEquals(echoed?.kind === "chat" ? echoed.state : null, undefined);
	assertEquals(
		echoed?.kind === "chat" && files.retains(echoed.attachments![0].id),
		true,
		"metadata is not file custody",
	);
	assertEquals(released.includes("pending.txt"), false);
	assertEquals(echoed?.kind === "chat" ? echoed.history : null, uploadHistory);
	projection.apply(event("pending.txt", { from: "ada", text: "pending upload", lineId: 4 }));
	assertEquals(
		released.filter((name) => name === "pending.txt").length,
		1,
		"replay releases only the extra occurrence",
	);
	projection.apply(event("replacement.txt", {
		from: "ada",
		text: "refiled upload",
		lineId: 4,
		history: uploadHistory,
		change: "refiled",
	}));
	const refiledUpload = store.historyOf(page.projection, room.key).find((item) => item.id === uploading.id);
	assertEquals(refiledUpload?.kind === "chat" ? refiledUpload.text : null, "refiled upload");
	// Retire this independently exercised send before the rejection inventory.
	store.clearHistory(page.projection, room.key);
	released.length = 0;

	projection.apply(event("unknown.txt", { conversationId: "unknown" }));
	projection.apply(event("typing.txt", {
		text: "",
		lineId: null,
		change: null,
		system: true,
		presence: { kind: "typing", name: "bo", on: true },
	}));
	projection.apply(event("system.txt", { system: true }));
	projection.apply(event("missing-refile.txt", { lineId: 99, change: "refiled" }));
	projection.apply(event("oversized-name.txt", { from: "x".repeat(257) }));
	assertEquals(released, ["unknown.txt", "typing.txt", "system.txt", "missing-refile.txt", "oversized-name.txt"]);
	store.patchDir(page.projection, room.dir, { session: "disconnected" });
	projection.apply(event("late.txt", { lineId: 3 }));
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
	projection.apply(event("live.txt", { history }));
	assertEquals(released.at(-1), oldFile.name);
	const live = store.historyOf(page.projection, room.key).find((item) =>
		item.kind === "chat" && item.history?.id === "line"
	);
	assertEquals(live?.kind === "chat" ? live.attachments?.[0]?.name : null, "live.txt");
	const liveView = live?.kind === "chat" ? live.attachments?.[0] : undefined;
	projection.apply(event("live.txt", { history }));
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
	projection.apply(event("previews", {
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
	projection.apply(event("previews-edited", {
		text: secondPreview,
		lineId: 4,
		change: "edited",
		previewUrls: [secondPreview],
		attachments: [],
	}));
	assertEquals(previewUrls(), [secondPreview]);
	projection.apply(event("previews-withdrawn", {
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
