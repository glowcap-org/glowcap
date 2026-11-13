// Typing projection changes only ephemeral composition state and retires it with the conversation.
// A composer's level is told once, renewed on the clock while it holds, and stopped on a pause.
/// <reference lib="dom" />
import "../support/match_media.ts";
import "../support/browser_application.ts";
import { assert } from "../assert.ts";

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/directory.ts");
const { assertEquals } = await import("../assert.ts");

Deno.test("a typing flag does not replace the conversation", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "typing-identity");
	const before = store.getConv(projection, room.key);
	store.setTyper(projection, room.key, "bob", true);
	assert(store.getConv(projection, room.key) === before, "typing replaced the conversation");
	assertEquals([...store.typersOf(projection, room.key)], ["bob"]);
	store.setTyper(projection, room.key, "bob", true);
	assert(store.getConv(projection, room.key) === before, "a repeated flag replaced the conversation");
	store.setTyper(projection, room.key, "bob", false);
	assertEquals([...store.typersOf(projection, room.key)], []);
	assert(store.getConv(projection, room.key) === before, "clearing typing replaced the conversation");
});

Deno.test("forgetting a conversation forgets who was composing in it", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "typing-forget");
	store.setTyper(projection, room.key, "bob", true);
	store.forgetConv(projection, room.key);
	assertEquals([...store.typersOf(projection, room.key)], []);
	store.setTyper(projection, room.key, "bob", true);
	assertEquals([...store.typersOf(projection, room.key)], []);
});

/** A clock a test moves by hand, running what falls due in order. */
function clock() {
	let now = 0;
	const due: { at: number; run: () => void }[] = [];
	return {
		now: () => now,
		waiting: () => due.length,
		after(ms: number, run: () => void) {
			const entry = { at: now + ms, run };
			due.push(entry);
			return () => {
				const at = due.indexOf(entry);
				if (at !== -1) due.splice(at, 1);
			};
		},
		advance(ms: number) {
			const end = now + ms;
			const soonest = () => due.filter((entry) => entry.at <= end).sort((a, b) => a.at - b.at)[0];
			for (let next = soonest(); next != null; next = soonest()) {
				due.splice(due.indexOf(next), 1);
				now = next.at;
				next.run();
			}
			now = end;
		},
	};
}

/** A composer in conversation "a", with what it sent and when. */
async function composer() {
	const { ComposerTyping } = await import("../../web/ui/typing.ts");
	const time = clock();
	const sent: [number, string, boolean][] = [];
	const typing = new ComposerTyping((conversation, on) => sent.push([time.now(), conversation, on]), time);
	return { time, sent, typing, levels: () => sent.map(([, conversation, on]) => `${conversation} ${on}`) };
}

Deno.test("a member typing as slowly as still counts is renewed inside a reader's wait", async () => {
	const { TYPING_IDLE_MS, TYPING_RENEW_MS } = await import("../../lib/limits.ts");
	const { time, sent, typing } = await composer();
	typing.note("a", true, true);
	// Keystrokes just inside the pause are the slowest typing that still counts.
	for (let key = 0; key < 6; key++) {
		time.advance(TYPING_IDLE_MS - 100);
		typing.note("a", true, true);
	}
	const renewals = Math.floor(6 * (TYPING_IDLE_MS - 100) / TYPING_RENEW_MS);
	assert(renewals >= 2, "the member typed through more than one renewal");
	assertEquals(
		sent.map(([at, , on]) => [at, on]),
		Array.from({ length: renewals + 1 }, (_, turn) => [turn * TYPING_RENEW_MS, true]),
	);
	time.advance(TYPING_IDLE_MS);
	assertEquals(sent.at(-1), [6 * (TYPING_IDLE_MS - 100) + TYPING_IDLE_MS, "a", false]);
	assertEquals(time.waiting(), 0, "a stopped level leaves nothing waiting");
});

Deno.test("one keystroke and a pause is a start and a stop, with no renewal between", async () => {
	const { TYPING_CLEAR_MS } = await import("../../lib/limits.ts");
	const { time, typing, levels } = await composer();
	typing.note("a", true, true);
	time.advance(TYPING_CLEAR_MS);
	assertEquals(levels(), ["a true", "a false"]);
	typing.note("a", true, true);
	typing.note("a", false, true);
	assertEquals(levels(), ["a true", "a false", "a true", "a false"], "an emptied draft stops at once");
	assertEquals(time.waiting(), 0);
});

Deno.test("a draft that changes with no keystroke is not typing", async () => {
	const { TYPING_CLEAR_MS } = await import("../../lib/limits.ts");
	const { time, typing, levels } = await composer();
	typing.note("a", true, false);
	time.advance(TYPING_CLEAR_MS);
	assertEquals([levels(), time.waiting()], [[], 0], "focus on a kept draft, or a draft put back, says nothing");
	typing.note("a", true, true);
	typing.note("a", false, false);
	typing.note("a", true, false);
	assertEquals(levels(), ["a true", "a false"], "a blur stops it, and focus alone does not start it again");
	assertEquals(time.waiting(), 0);
});

Deno.test("a composer speaks only for a draft that a line can follow", async () => {
	const { composerSpeaks } = await import("../../web/ui/typing.ts");
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "typing-speaks");
	const writing: Parameters<typeof composerSpeaks>[1] = {
		enabled: true,
		focused: true,
		changing: undefined,
		draft: "hello",
	};
	const speaks = (changed: Partial<typeof writing>) =>
		composerSpeaks(store.getConv(projection, room.key) ?? null, { ...writing, ...changed });
	assertEquals(composerSpeaks(null, writing), false);
	assertEquals(speaks({}), true, "a focused draft in a room that hears typing");
	assertEquals(
		[speaks({ focused: false }), speaks({ enabled: false }), speaks({ draft: "  " }), speaks({ changing: 7 })],
		[false, false, false, false],
		"no caret, no way to send, nothing written, or a line already said",
	);
});

Deno.test("a stop names the conversation that heard the start", async () => {
	const { time, typing, levels } = await composer();
	typing.note("a", true, true);
	typing.note("b", true, false);
	assertEquals(levels(), ["a true", "a false"], "leaving stops it there, and a kept draft in the next says nothing");
	typing.note("b", true, true);
	typing.note("a", true, false);
	assertEquals(levels(), ["a true", "a false", "b true", "b false"]);
	typing.note("a", true, true);
	typing.close();
	typing.close();
	assertEquals(levels().slice(4), ["a true", "a false"], "a closed composer owes one stop");
	typing.note(null, false, false);
	assertEquals([levels().length, time.waiting()], [6, 0]);
});

Deno.test("a line said now ends its author's typing, and a replayed one does not", async () => {
	const { AttachedLineProjection } = await import("../../web/ui/session/line_projection.ts");
	const { RoomsPage } = await import("../../web/ui/page.ts");
	const { applyTyping } = await import("../../web/ui/typing.ts");
	const page = new RoomsPage();
	const directory = dirId("typing-line");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	const room = store.ensureRoom(page.projection, directory, "general", { persistId: "room-id" });
	store.setRoomMembership(page.projection, room.key, "joined", "");
	store.patchDir(page.projection, room.dir, { nick: "ada", session: "connected" });
	const lines = new AttachedLineProjection(
		(id) => store.convByPersistId(page.projection, id)?.key ?? null,
		null,
		page,
	);
	const line = (lineId: number, replayed: boolean, change: "said" | "edited") => ({
		conversationId: "room-id",
		from: "bo",
		text: "hello",
		at: lineId,
		replayed,
		lineId,
		change,
		editable: false,
		history: null,
		system: false,
		previewUrls: [],
		attachments: [],
	});
	try {
		applyTyping(page, room.key, "bo", true);
		applyTyping(page, room.key, "cy", true);
		lines.apply(line(1, true, "said"));
		lines.apply(line(1, false, "edited"));
		assertEquals([...store.typersOf(page.projection, room.key)], ["bo", "cy"]);
		lines.apply(line(2, false, "said"));
		assertEquals([...store.typersOf(page.projection, room.key)], ["cy"]);
		assertEquals(page.typing.timers.size, 1, "the line retired its author's expiry with the flag");
	} finally {
		applyTyping(page, room.key, "cy", false);
		applyTyping(page, room.key, "bo", false);
	}
});
