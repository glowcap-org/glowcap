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

for (const echoFirst of [true, false]) {
	Deno.test(`a commit receipt names the sending bubble, which keeps sending, echo first: ${echoFirst}`, () => {
		const page = new RoomsPage();
		const directory = dirId("directory");
		store.openDir(page.projection, directory, "directory");
		store.patchDir(page.projection, directory, { nick: "ada" });
		const room = store.ensureRoom(page.projection, directory, "garden", { persistId: "conversation" });
		const projection = new AttachedLineProjection(() => room.key, null, page);
		const original = store.chatItem(page.projection, "ada", "hello", true, "sending", undefined, 1);
		store.deliver(page.projection, room.key, { ...original, awaitingReceipt: true, operation: "op" });
		const coordinates = { source: "archive", generation: "original", id: "7" };
		const echo = () =>
			projection.apply({
				conversationId: "conversation",
				from: "ada",
				text: "hello",
				at: 2,
				lineId: 7,
				change: "said",
				editable: true,
				history: coordinates,
				system: false,
				previewUrls: [],
				attachments: [],
			});
		const chat = () => store.historyOf(page.projection, room.key).filter((item) => item.kind === "chat");
		try {
			if (echoFirst) echo();
			store.nameSentLine(page.projection, room.key, original.id, { id: 7, history: coordinates });
			if (!echoFirst) echo();
			assertEquals(chat().map((line) => [line.id, line.lineId, line.history, line.state, line.operation]), [
				[original.id, 7, coordinates, "sending", "op"],
			]);
			store.confirmSentLine(page.projection, room.key, original.id, { id: 7, history: coordinates, held: true });
			assertEquals(chat().map((line) => [line.id, line.lineId, line.state, line.held, line.at]), [
				[original.id, 7, undefined, true, original.at],
			]);
		} finally {
			store.forgetConv(page.projection, room.key);
		}
	});
}
