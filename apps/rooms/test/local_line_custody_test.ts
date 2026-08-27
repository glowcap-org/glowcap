/// <reference lib="dom" />

import { type Argument, type Behavior, Ref, type Session } from "@pancake/runtime";
import type { Attachment } from "../lib/attachment.ts";
import { MAX_LINE } from "../lib/limits.ts";
import type { Message, Room } from "../lib/room_client.ts";
import type { Live } from "../web/ui/net/live.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { receiveDm } = await import("../web/ui/net/direct.ts");
const { releaseHeldFile } = await import("../web/ui/net/files.ts");
const { dirs } = await import("../web/ui/net/live.ts");
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

function resetStore(): void {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	dirs.clear();
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

function live(id: ReturnType<typeof dirId>): Live {
	return {
		id,
		files: new Map(),
		objectUrls: new Map(),
		echoes: [],
		refiling: new Map(),
		outgoing: new Map(),
		posted: new Map(),
		progress: { pending: new Map(), frame: null },
	} as unknown as Live;
}

Deno.test("local room projection releases rejected, orphaned, and mismatched file occurrences", () => {
	resetStore();
	const directory = dirId("directory");
	store.openDir(directory, "127.0.0.1:1");
	store.patchDir(directory, { nick: "ada" });
	const owner = live(directory);
	dirs.set(directory, owner);
	const released: string[] = [];
	const room = {
		release: (file: Attachment) => released.push(file.name),
	} as unknown as Room;
	const key = store.roomKey(directory, "general");

	projectRoomMessage(directory, key, "general", room, message("too-long.txt", { from: "x".repeat(257) }));
	projectRoomMessage(directory, key, "general", room, message("system.txt", { system: true }));
	projectRoomMessage(directory, key, "general", room, message("edited.txt", { change: "edited" }));
	projectRoomMessage(
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

	const optimistic = store.chatItem("ada", "mine", true, "sending");
	store.deliver(key, optimistic);
	owner.echoes.push({ key, id: optimistic.id, attachmentIds: [], text: "mine" });
	withExpectedTrouble(() =>
		projectRoomMessage(
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
	const missingView = store.attachmentView({ name: "missing.txt", mime: "text/plain", size: 1 });
	const missingItem = store.chatItem("ada", "missing", true, "sending", [missingView]);
	store.deliver(key, missingItem);
	owner.echoes.push({ key, id: missingItem.id, attachmentIds: [missingView.id], text: "missing" });
	withExpectedTrouble(() =>
		projectRoomMessage(
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
	const missing = store.getConv(key)?.history.find((item) => item.id === missingItem.id);
	assertEquals(missing?.kind === "chat" ? missing.attachments?.[0]?.lost : false, true);

	projectRoomMessage(directory, key, "general", room, message("held.txt", { lineId: 2 }));
	const held = store.getConv(key)?.history.find((item) => item.kind === "chat" && item.lineId === 2);
	if (held?.kind !== "chat") throw new Error("the local room fixture retained no ordinary file line");
	const heldView = held.attachments?.[0];
	if (heldView == null) throw new Error("the local room fixture retained no ordinary file");
	releaseHeldFile(owner, heldView.id);
	assertEquals(released.at(-1), "held.txt");

	projectRoomMessage(directory, key, "general", room, message("before-refile.txt", { lineId: 3 }));
	const beforeRefile = store.getConv(key)?.history.find((item) => item.kind === "chat" && item.lineId === 3);
	if (beforeRefile?.kind !== "chat") throw new Error("the local room fixture retained no refile target");
	owner.refiling.set(3, []);
	withExpectedTrouble(() =>
		projectRoomMessage(
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
	const afterRefile = store.getConv(key)?.history.find((item) => item.kind === "chat" && item.lineId === 3);
	assertEquals(afterRefile?.kind === "chat" ? afterRefile.attachments?.[0]?.name : null, "after-refile.txt");
	const afterRefileView = afterRefile?.kind === "chat" ? afterRefile.attachments?.[0] : null;
	if (afterRefileView != null) releaseHeldFile(owner, afterRefileView.id);
	dirs.clear();
	store.forgetConv(key);
});

Deno.test("local direct delivery releases files and surplus line-capability arguments", () => {
	resetStore();
	const directory = dirId("directory");
	store.openDir(directory, "127.0.0.1:1");
	store.patchDir(directory, { nick: "ada" });
	const owner = live(directory);
	dirs.set(directory, owner);
	const direct = store.restoreDm(directory, "bo", registrationId(1), "direct", false);
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
	receiveDm(direct.key, "bo", "x".repeat(MAX_LINE + 1), [refusedFile], via);
	assertEquals(released, [refusedFile.blob]);
	receiveDm(direct.key, "bo", "line", [], via);
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
	dirs.clear();
	store.forgetConv(direct.key);
});
