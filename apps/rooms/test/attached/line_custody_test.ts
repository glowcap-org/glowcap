/// <reference lib="dom" />

import type { Attachment } from "../../lib/attachment.ts";
import { MAX_SCROLLBACK } from "../../lib/limits.ts";
import type { AttachedRoomsController } from "../../web/ui/session/attached.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionFiles } = await import("../../web/ui/session/attached_files.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { dirId } = await import("../../web/ui/types.ts");

function resetRoom(page: InstanceType<typeof RoomsPage>, name: string) {
	page.projection.reset();
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	return store.ensureRoom(page.projection, directory, name, { persistId: name });
}

function attachment(name: string): Attachment {
	return { name, mime: "text/plain", size: 1, width: 0, height: 0, blob: {} as Attachment["blob"] };
}

Deno.test("attached lines release file capability custody whenever they leave the store", () => {
	const page = new RoomsPage();
	const released: string[] = [];
	const controller = {
		releaseAttachment: (file: Attachment) => released.push(file.name),
	} as unknown as AttachedRoomsController;
	const files = new AttachedSessionFiles(controller, page.projection);
	const room = resetRoom(page, "custody");
	const first = attachment("cleared.txt");
	store.deliver(
		page.projection,
		room.key,
		store.chatItem(page.projection, "bo", "first", false, undefined, [files.hold(first)]),
	);
	store.clearHistory(page.projection, room.key);
	assertEquals(released, [first.name]);

	const second = attachment("forgotten.txt");
	store.deliver(
		page.projection,
		room.key,
		store.chatItem(page.projection, "bo", "second", false, undefined, [files.hold(second)]),
	);
	store.forgetConv(page.projection, room.key);
	assertEquals(released, [first.name, second.name]);
	files.close();
});

Deno.test("bounded history insertion retires rows that never enter the visible log", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "bounded-history");
	let dropped = 0;
	const stop = page.projection.onLinesDropped((_key, lines) => dropped += lines.length);
	store.prependHistory(
		page.projection,
		room.key,
		Array.from({ length: MAX_SCROLLBACK + 1 }, (_, at) => ({ from: "bo", text: String(at), mine: false, at })),
		"Earlier messages",
	);
	assertEquals(store.historyOf(page.projection, room.key).length, MAX_SCROLLBACK);
	assertEquals(dropped, 2);
	store.forgetConv(page.projection, room.key);
	stop();
});
