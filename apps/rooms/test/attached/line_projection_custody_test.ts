/// <reference lib="dom" />

import type { Attachment } from "../../lib/attachment.ts";
import type { RoomsSessionLineEvent } from "../../lib/session/client.ts";
import type { AttachedRoomsController } from "../../web/ui/session/attached.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const { AttachedSessionFiles } = await import("../../web/ui/session/attached_files.ts");
const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
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
	store.clearHistory(page.projection, room.key);
	assertEquals(released.at(-1), "live.txt");
	files.close();
});
