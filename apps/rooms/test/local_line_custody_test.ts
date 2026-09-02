/// <reference lib="dom" />

import { type Argument, type Behavior, Ref, type Session } from "@glowcap/runtime";
import type { Attachment } from "../lib/attachment.ts";
import { MAX_LINE } from "../lib/limits.ts";
import type { Message, Room } from "../lib/room/client.ts";
import type { Live } from "../web/ui/net/live.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { receiveDm } = await import("../web/ui/net/direct.ts");
const { releaseHeldFile } = await import("../web/ui/net/files.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { projectRoomMessage } = await import("../web/ui/net/room_messages.ts");
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");

function attachment(name: string): Attachment {
	return { name, mime: "text/plain", size: 1, width: 0, height: 0, blob: Object.create(Ref.prototype) as Ref };
}

function message(name: string, overrides: Partial<Message> = {}): Message {
	return {
		from: "bo",
		text: name,
		system: false,
		lineId: 1,
		change: "said",
		attachments: [attachment(name)],
		...overrides,
	};
}

function resetStore(page: InstanceType<typeof RoomsPage>): void {
	page.projection.set({
		...store.initialState(),
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	page.live.dirs.clear();
}

function live(page: InstanceType<typeof RoomsPage>, id: ReturnType<typeof dirId>): Live {
	const session = {
		page,
		id,
		files: new Map(),
		objectUrls: new Map(),
		echoes: [],
		refiling: new Map(),
		outgoing: new Map(),
		posted: new Map(),
		progress: { pending: new Map(), frame: null },
	} as unknown as Live;
	page.live.dirs.set(id, session);
	return session;
}

function withExpectedTrouble(work: () => void): void {
	const report = console.error;
	console.error = () => {};
	try {
		work();
	} finally {
		console.error = report;
	}
}

Deno.test("local room projection releases rejected, orphaned, and mismatched file occurrences", () => {
	const page = new RoomsPage();
	resetStore(page);
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	store.patchDir(page.projection, directory, { nick: "ada" });
	const owner = live(page, directory);
	const released: string[] = [];
	const room = {
		release: (file: Attachment) => released.push(file.name),
	} as unknown as Room;
	const key = store.roomKey(directory, "general");

	projectRoomMessage(page, directory, key, "general", room, message("too-long.txt", { from: "x".repeat(257) }));
	projectRoomMessage(page, directory, key, "general", room, message("system.txt", { system: true }));
	projectRoomMessage(page, directory, key, "general", room, message("edited.txt", { change: "edited" }));
	projectRoomMessage(
		page,
		directory,
		key,
		"general",
		room,
		message("missing-refile.txt", {
			change: "refiled",
			lineId: 99,
		}),
	);
	assertEquals(released, ["too-long.txt", "system.txt", "edited.txt", "missing-refile.txt"]);

	const optimistic = store.chatItem(page.projection, "ada", "mine", true, "sending");
	store.deliver(page.projection, key, optimistic);
	owner.echoes.push({ key, id: optimistic.id, attachmentIds: [], text: "mine" });
	withExpectedTrouble(() =>
		projectRoomMessage(
			page,
			directory,
			key,
			"general",
			room,
			message("extra-echo.txt", {
				from: "ada",
				text: "mine",
			}),
		)
	);
	assertEquals(released.at(-1), "extra-echo.txt");
	const missingView = store.attachmentView(page.projection, { name: "missing.txt", mime: "text/plain", size: 1 });
	const missingItem = store.chatItem(page.projection, "ada", "missing", true, "sending", [missingView]);
	store.deliver(page.projection, key, missingItem);
	owner.echoes.push({ key, id: missingItem.id, attachmentIds: [missingView.id], text: "missing" });
	withExpectedTrouble(() =>
		projectRoomMessage(
			page,
			directory,
			key,
			"general",
			room,
			message("ignored", {
				from: "ada",
				text: "missing",
				attachments: [],
			}),
		)
	);
	const missing = store.historyOf(page.projection, key).find((item) => item.id === missingItem.id);
	assertEquals(missing?.kind === "chat" ? missing.attachments?.[0]?.lost : false, true);

	projectRoomMessage(page, directory, key, "general", room, message("held.txt", { lineId: 2 }));
	const held = store.historyOf(page.projection, key).find((item) => item.kind === "chat" && item.lineId === 2);
	if (held?.kind !== "chat") throw new Error("the local room fixture retained no ordinary file line");
	const heldView = held.attachments?.[0];
	if (heldView == null) throw new Error("the local room fixture retained no ordinary file");
	releaseHeldFile(owner, heldView.id);
	assertEquals(released.at(-1), "held.txt");

	projectRoomMessage(page, directory, key, "general", room, message("before-refile.txt", { lineId: 3 }));
	const beforeRefile = store.historyOf(page.projection, key).find((item) =>
		item.kind === "chat" && item.lineId === 3
	);
	if (beforeRefile?.kind !== "chat") throw new Error("the local room fixture retained no refile target");
	owner.refiling.set(key, new Map([[3, []]]));
	const otherKey = store.roomKey(directory, "other");
	projectRoomMessage(page, directory, otherKey, "other", room, message("other-before.txt", { lineId: 3 }));
	projectRoomMessage(
		page,
		directory,
		otherKey,
		"other",
		room,
		message("other-after.txt", { change: "refiled", lineId: 3 }),
	);
	assertEquals(owner.refiling.get(key)?.has(3), true);
	withExpectedTrouble(() =>
		projectRoomMessage(
			page,
			directory,
			key,
			"general",
			room,
			message("after-refile.txt", {
				change: "refiled",
				lineId: 3,
			}),
		)
	);
	const afterRefile = store.historyOf(page.projection, key).find((item) => item.kind === "chat" && item.lineId === 3);
	assertEquals(afterRefile?.kind === "chat" ? afterRefile.attachments?.[0]?.name : null, "after-refile.txt");
	const afterRefileView = afterRefile?.kind === "chat" ? afterRefile.attachments?.[0] : null;
	if (afterRefileView != null) releaseHeldFile(owner, afterRefileView.id);
	const other = store.historyOf(page.projection, otherKey).find((item) => item.kind === "chat" && item.lineId === 3);
	const otherView = other?.kind === "chat" ? other.attachments?.[0] : null;
	if (otherView != null) releaseHeldFile(owner, otherView.id);
	page.live.dirs.clear();
	store.forgetConv(page.projection, otherKey);
	store.forgetConv(page.projection, key);
});

Deno.test("local direct delivery releases files and surplus line-capability arguments", () => {
	const page = new RoomsPage();
	resetStore(page);
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	store.patchDir(page.projection, directory, { nick: "ada" });
	live(page, directory);
	const direct = store.restoreDm(page.projection, directory, "bo", registrationId(1), "direct", false);
	if (direct == null) throw new Error("the local direct fixture created no conversation");
	const hosted: Behavior[] = [];
	const released: Ref[] = [];
	const via = {
		spawn: (run: Behavior) => {
			hosted.push(run);
			return Object.create(Ref.prototype) as Ref;
		},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;

	const refusedFile = attachment("refused.txt");
	receiveDm(page, direct.key, "bo", "x".repeat(MAX_LINE + 1), [refusedFile], via);
	assertEquals(released, [refusedFile.blob]);
	receiveDm(page, direct.key, "bo", "line", [], via);
	const behavior = hosted[0];
	if (behavior == null) throw new Error("the local direct fixture received no line capability");

	const surplus = attachment("surplus.txt");
	let editRefused = false;
	try {
		behavior("edit", ["changed", surplus.blob]);
	} catch {
		editRefused = true;
	}
	assertEquals(editRefused, true);
	assertEquals(released.at(-1), surplus.blob);

	const refile = attachment("refile.txt");
	let refileRefused = false;
	try {
		behavior("refile", [
			"x".repeat(MAX_LINE + 1),
			"file",
			refile.name,
			refile.mime,
			BigInt(refile.size),
			refile.blob,
			0n,
			0n,
		] as Argument[]);
	} catch {
		refileRefused = true;
	}
	assertEquals(refileRefused, true);
	assertEquals(released.at(-1), refile.blob);
	page.live.dirs.clear();
	store.forgetConv(page.projection, direct.key);
});
