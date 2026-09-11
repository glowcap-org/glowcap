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
	store.restoreHistory(
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

Deno.test("independent prefix histories keep separate attribution dividers", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "attributed-history");
	store.restoreHistory(page.projection, room.key, [{ from: "bo", text: "first", mine: false, at: 1 }], "Earlier");
	store.restoreHistory(page.projection, room.key, [{ from: "cy", text: "second", mine: false, at: 2 }], "Earlier");
	assertEquals(
		store.historyOf(page.projection, room.key).filter((item) => item.kind === "sys" && item.text === "Earlier")
			.length,
		2,
	);
});

Deno.test("chronological reconciliation orders its own rows before their boundary", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "ordered-history");
	store.reconcileHistory(
		page.projection,
		room.key,
		[{ from: "cy", text: "later", mine: false, at: 20 }, { from: "bo", text: "earlier", mine: false, at: 10 }],
		"Earlier",
	);
	assertEquals(
		store.historyOf(page.projection, room.key).map((item) => item.text),
		["earlier", "later", "Earlier"],
	);
});

Deno.test("history keeper reconciliation updates the existing semantic boundary without new rows", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "keeper-reconciliation");
	store.reconcileHistory(
		page.projection,
		room.key,
		[{ from: "cy", text: "kept", mine: false, at: 10 }],
		"Earlier messages, kept on this device",
	);
	store.reconcileHistory(
		page.projection,
		room.key,
		[],
		"Earlier messages kept by the shared Rooms session archive peer and on this device",
	);
	assertEquals(store.historyOf(page.projection, room.key).map((item) => item.text), [
		"kept",
		"Earlier messages kept by the shared Rooms session archive peer and on this device",
	]);
});

Deno.test("chronological reconciliation uses conversation order rather than opaque archive identity", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "equal-time-history");
	store.deliver(page.projection, room.key, {
		...store.chatItem(page.projection, "bo", "middle", false, undefined, undefined, 10),
		history: { source: "archive", generation: "generation", id: "10" },
		order: 2,
	});
	store.reconcileHistory(page.projection, room.key, [
		{
			from: "bo",
			text: "last",
			mine: false,
			at: 10,
			history: { source: "archive", generation: "generation", id: "2" },
			order: 3,
		},
		{
			from: "bo",
			text: "first",
			mine: false,
			at: 10,
			history: { source: "archive", generation: "generation", id: "20" },
			order: 1,
		},
	], "Earlier");
	assertEquals(store.historyOf(page.projection, room.key).map((item) => item.text), [
		"first",
		"middle",
		"last",
		"Earlier",
	]);
});

Deno.test("history reconciliation keeps the unread rule on a retained row", () => {
	const page = new RoomsPage();
	const room = resetRoom(page, "reconciled-unread");
	for (let at = 0; at < MAX_SCROLLBACK; at += 1) {
		store.deliver(
			page.projection,
			room.key,
			store.chatItem(page.projection, "bo", String(at), false, undefined, undefined, at),
		);
	}
	store.reconcileHistory(page.projection, room.key, [
		{
			from: "cy",
			text: "missed one",
			mine: false,
			at: MAX_SCROLLBACK + 1,
			history: { source: "archive", generation: "generation", id: "missed-one" },
		},
		{
			from: "cy",
			text: "missed two",
			mine: false,
			at: MAX_SCROLLBACK + 2,
			history: { source: "archive", generation: "generation", id: "missed-two" },
		},
	], "Earlier");
	const history = store.historyOf(page.projection, room.key);
	const unread = store.unreadOf(page.projection, room.key);
	assertEquals(unread.kind === "unread" && history.some((item) => item.id === unread.from), true);
	store.clearHistory(page.projection, room.key);
	assertEquals(store.unreadOf(page.projection, room.key).kind, "caught-up");
});
