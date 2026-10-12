// A committed room receipt correlates the server's normalized echo with the
// original gesture in either arrival order, without guessing from its text.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import type { Attachment } from "../../lib/attachment.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { AttachedLineProjection } = await import("../../web/ui/session/line_projection.ts");
const { AttachedSessionFiles } = await import("../../web/ui/session/attached_files.ts");

for (const echoFirst of [true, false]) {
	Deno.test(`normalized send receipt preserves one bubble and file owner, echo first: ${echoFirst}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		store.patchDir(page.projection, directory, { nick: "ada" });
		const room = store.ensureRoom(page.projection, directory, "garden", { persistId: "conversation" });
		store.setRoomMembership(page.projection, room.key, "joined", "");
		let released = 0;
		const files = new AttachedSessionFiles({
			fetchAttachment: () => Promise.resolve(new Uint8Array()),
			releaseAttachment: () => {
				released++;
			},
			archiveSource: () => null,
		}, page.projection);
		const projection = new AttachedLineProjection(() => room.key, files, page);
		const attachment: Attachment = {
			name: "before.txt",
			mime: "text/plain",
			size: 1,
			width: 0,
			height: 0,
			blob: {} as Attachment["blob"],
		};
		const placeholder = store.attachmentView(page.projection, attachment);
		const original = store.chatItem(page.projection, "ada", "", true, "sending", [placeholder], 1);
		store.deliver(page.projection, room.key, { ...original, awaitingReceipt: true });
		const coordinates = { source: "archive", generation: "original", id: "7" };
		const echo = () =>
			projection.apply({
				conversationId: "conversation",
				from: "ada",
				text: "before.txt",
				at: 2,
				lineId: 7,
				change: "said",
				editable: true,
				history: coordinates,
				system: false,
				previewUrls: [],
				attachments: [attachment],
			});
		try {
			if (echoFirst) echo();
			store.confirmSentLine(page.projection, room.key, original.id, { id: 7, history: coordinates, held: true });
			if (!echoFirst) echo();
			const lines = store.historyOf(page.projection, room.key).filter((item) => item.kind === "chat");
			assertEquals(lines.length, 1);
			const line = lines[0];
			if (line.kind !== "chat") throw new Error("chat");
			assertEquals(line.at, original.at);
			assertEquals([line.id, line.text, line.lineId, line.history, line.state], [
				original.id,
				"before.txt",
				7,
				coordinates,
				undefined,
			]);
			assertEquals(files.retains(line.attachments![0].id), true);
			assertEquals(released, 0, "the committed echo's file custody was released during correlation");
		} finally {
			files.close();
			store.forgetConv(page.projection, room.key);
		}
		assertEquals(released, 1, "the surviving file occurrence must retire exactly once");
	});
}

const { reconcileSharedArchive } = await import("../../web/ui/session/shared_archive_projection.ts");
for (const archiveFirst of [true, false]) {
	Deno.test(`direct send receipt unifies archive replay without mutation authority, archive first: ${archiveFirst}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		const direct = store.restoreDm(page.projection, directory, "bob", "bob-registration", "direct", false);
		if (direct == null) throw new Error("direct conversation");
		const original = store.chatItem(page.projection, "ada", "hello", true, "sending", undefined, 1);
		store.deliver(page.projection, direct.key, { ...original, awaitingReceipt: true });
		const history = { source: "direct-archive", generation: "first", id: "7" };
		const replay = () =>
			reconcileSharedArchive(page, direct.key, [{
				...history,
				kind: "line",
				conversationKind: "direct",
				directory: "directory",
				conversation: "bob",
				from: "ada",
				text: "hello",
				mine: true,
				at: 1,
				order: 7,
				state: "present",
				previewUrls: [],
				attachments: [],
			}], "ada");
		try {
			if (archiveFirst) replay();
			store.confirmSentLine(page.projection, direct.key, original.id, { id: 7, history, held: false });
			if (!archiveFirst) replay();
			const rows = store.historyOf(page.projection, direct.key).filter((item) => item.kind === "chat");
			assertEquals(rows.length, 1);
			assertEquals([rows[0].id, rows[0].at, rows[0].lineId, rows[0].history, rows[0].held, rows[0].state], [
				original.id,
				original.at,
				7,
				history,
				false,
				undefined,
			]);
		} finally {
			store.forgetConv(page.projection, direct.key);
		}
	});
}

for (const archived of [false, true]) {
	Deno.test(`a retired receipt preserves a newer numeric identity, archived: ${archived}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		const room = store.ensureRoom(page.projection, directory, "garden", { persistId: "conversation" });
		store.setRoomMembership(page.projection, room.key, "joined", "");
		const original = store.chatItem(page.projection, "ada", "original", true, "sending", undefined, 1);
		store.deliver(page.projection, room.key, { ...original, awaitingReceipt: true, operation: "op" });
		const history = { source: "archive", generation: "original", id: "7" };
		const echo = store.chatItem(page.projection, "ada", archived ? "original" : "newer", true);
		store.deliver(page.projection, room.key, { ...echo, lineId: 7, held: true, ...(archived ? { history } : {}) });
		try {
			store.confirmSentLine(page.projection, room.key, original.id, { history, held: false });
			const lines = store.historyOf(page.projection, room.key).filter((row) => row.kind === "chat");
			assertEquals(
				lines.map((row) => [row.id, row.text, row.lineId, row.held, row.state]),
				archived
					? [[original.id, "original", 7, true, undefined]]
					: [[original.id, "original", undefined, false, undefined], [echo.id, "newer", 7, true, undefined]],
			);
		} finally {
			store.forgetConv(page.projection, room.key);
		}
	});
}

for (const confirmed of [false, true]) {
	Deno.test(`an ended notice prevents receipt naming before refresh, previously confirmed: ${confirmed}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		const room = store.ensureRoom(page.projection, directory, "garden", { persistId: "conversation" });
		store.setRoomMembership(page.projection, room.key, "joined", "");
		const original = store.chatItem(page.projection, "ada", "sent", true, "sending");
		store.deliver(page.projection, room.key, original);
		try {
			if (confirmed) store.confirmSentLine(page.projection, room.key, original.id, { id: 7, held: true });
			store.setRoomMembership(page.projection, room.key, "unavailable", "ended");
			store.confirmSentLine(page.projection, room.key, original.id, { id: 7, held: true });
			const line = store.historyOf(page.projection, room.key).find((row) => row.kind === "chat")!;
			assertEquals([line.lineId, line.held, line.state], [undefined, false, undefined]);
		} finally {
			store.forgetConv(page.projection, room.key);
		}
	});
}

for (const committedFirst of [false, true]) {
	Deno.test(`correlated echoes keep identical posts and another viewer distinct, commitment first: ${committedFirst}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		store.patchDir(page.projection, directory, { nick: "ada" });
		const room = store.ensureRoom(page.projection, directory, "garden", { persistId: "conversation" });
		store.setRoomMembership(page.projection, room.key, "joined", "");
		const projection = new AttachedLineProjection(() => room.key, null, page);
		const originals = ["first", "second"].map((operation) => {
			const line = store.chatItem(page.projection, "ada", "same", true, "sending");
			store.deliver(page.projection, room.key, { ...line, operation, awaitingReceipt: true });
			return line;
		});
		const echo = (operation: string, lineId: number) =>
			projection.apply({
				conversationId: "conversation",
				operation,
				from: "ada",
				text: "same",
				at: 2,
				lineId,
				change: "said",
				editable: false,
				history: null,
				system: false,
				previewUrls: [],
				attachments: [],
			});
		if (committedFirst) store.confirmSentOperations(page.projection, new Set(["first", "second"]));
		echo("second", 8);
		assertEquals(
			store.historyOf(page.projection, room.key).map((line) => line.id),
			originals.map((line) => line.id),
		);
		echo("another-viewer", 9);
		echo("first", 7);
		echo("second", 8);
		assertEquals(store.historyOf(page.projection, room.key).length, 3);
		for (const [index, id] of [7, 8].entries()) {
			store.confirmSentLine(page.projection, room.key, originals[index].id, { id, held: true });
		}
		const lines = store.historyOf(page.projection, room.key);
		assertEquals(lines.length, 3);
		assertEquals(lines.slice(0, 2).map((line) => line.id), originals.map((line) => line.id));
		store.forgetConv(page.projection, room.key);
	});
}
