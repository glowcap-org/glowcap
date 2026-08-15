// The composer's inline-completion rules, held where they are pure: which
// caret positions raise which trigger, how candidates rank, and what
// accepting one leaves in the draft. The browser proof drives the widget;
// this file pins the grammar the widget trusts.

import { acceptCompletion, completeCandidates, triggerAt } from "../web/ui/complete.ts";
import { EMOJI_TABLE } from "../web/ui/emoji.ts";
import { mentionsYou, PICKER, ROOM_MENTIONS, ROOM_MENTIONS_OFFERED, substituteEmoji } from "../web/ui/text.ts";
import { actionIn, commandIn, noticeIn, notifiesYou } from "../web/ui/commands.ts";

function fail(message: string): never {
	throw new Error(message);
}
import { assertEquals } from "./assert.ts";

function assert(ok: boolean, what: string): void {
	if (!ok) throw new Error(what);
}

const SOURCES = { nicks: ["alice", "alicia", "bob"], rooms: ["lobby", "logs", "dev"] };

Deno.test("a sigil triggers only at the start of the token under the caret", () => {
	assertEquals(triggerAt("@al", 3), { kind: "nick", start: 0, query: "al" });
	assertEquals(triggerAt("hey @al", 7), { kind: "nick", start: 4, query: "al" });
	assertEquals(triggerAt("#lo", 3), { kind: "room", start: 0, query: "lo" });
	// A sigil inside a token is plain text: addresses and clock times stay quiet.
	assertEquals(triggerAt("mail@host", 9), null);
	assertEquals(triggerAt("10:30", 5), null);
	// The caret has to sit in the token, not before it.
	assertEquals(triggerAt("@al done", 8), null);
});

Deno.test("completion starts with the first useful character", () => {
	assertEquals(triggerAt(":f", 2), { kind: "emoji", start: 0, query: "f" });
	assertEquals(triggerAt(":fi", 3), { kind: "emoji", start: 0, query: "fi" });
	// `:)` and a colon at a clause end never pop the list.
	assertEquals(triggerAt(":)", 2), null);
	assertEquals(triggerAt("note: done", 5), null);
});

Deno.test("slash commands are discoverable and have one parser", () => {
	const trigger = triggerAt("/", 1);
	assertEquals(trigger, { kind: "command", start: 0, query: "" });
	// The rule rather than the roster, because the roster is meant to grow. Every
	// command offered has to be one that exists: completion and the runner read
	// one registry, so being suggested something that then says "no such command"
	// is not a thing that can happen — and this is what says so.
	const offered = completeCandidates(trigger!, SOURCES);
	if (offered.length === 0) fail("a bare slash offered no commands at all");
	for (const candidate of offered) {
		const name = candidate.insert.trim();
		if (commandIn(name) === null) fail(`completion offered ${name}, which no command answers to`);
	}
	// A command nothing has handed out says so where it is offered, so the
	// distinction is met before the refusal is.
	const ungranted = offered.filter((candidate) => candidate.label.includes("(not granted here)"));
	if (ungranted.length === 0) fail("no offered command said the room has not granted it");
	assertEquals(actionIn("/me waves"), "waves");
	// A notice travels the same way and is read back the same way, but it is not
	// an action: it keeps its author and gives up the notification instead.
	assertEquals(noticeIn("/notice the build is green"), "the build is green");
	assertEquals(actionIn("/notice the build is green"), null, "a notice is not an action");
	assertEquals(noticeIn("/me waves"), null, "an action is not a notice");
	assertEquals(noticeIn("nothing special"), null, "an ordinary line is not a notice");
	// Written with nothing to say it is not one, the same as `/me`.
	assertEquals(noticeIn("/notice"), null);
	// And the whole point of sending one: it can name somebody without asking for
	// them. Both halves are checked, because either one alone still passes every
	// other test in this file.
	assertEquals(notifiesYou("morning @zoe", "zoe"), true, "an ordinary mention");
	assertEquals(notifiesYou("/notice @zoe the build is green", "zoe"), false, "a notice naming you");
	assertEquals(notifiesYou("/notice nothing about you", "zoe"), false, "a notice naming nobody");
	assertEquals(notifiesYou("morning @alice", "zoe"), false, "somebody else's mention");
	assertEquals(actionIn("/ME   waves hello"), "waves hello");
	// Written with no action, `/me` is not one: the composer says how to use it
	// and nothing travels.
	assertEquals(actionIn("/me"), null);
	// A line that opens with a slash and names no command anybody knows is
	// ordinary text — somebody talking about /etc/hosts is not giving an order.
	assertEquals(actionIn("/unknown stays text"), null);
	// A command that is not the kind that travels is not an action either, even
	// though it is a command: /help acts on this window and says nothing here.
	assertEquals(actionIn("/help"), null);
});

Deno.test("the list gives Enter back once a whole command needs nothing more", () => {
	// Enter is the send key. The list borrows it while it still has something to
	// offer and hands it back when it does not, so `/delete` typed out and sent
	// withdraws a line instead of returning `/delete ` to the composer — which is
	// what it used to do, and which looked exactly like a key that does nothing.
	const only = (query: string) => {
		const rows = completeCandidates({ kind: "command", start: 0, query }, SOURCES);
		const row = rows.find((candidate) => candidate.insert.trim() === `/${query}`) ?? rows[0];
		if (row === undefined) fail(`nothing was offered for /${query}`);
		return row;
	};
	assertEquals(only("delete").keepsEnter, false, "a whole command that needs nothing");
	// Half typed, the row is still completing the name.
	assertEquals(only("del").keepsEnter, true, "a name still being written");
	// Written out but wanting words after it: accepting leaves the reader at the
	// argument, which is where they were going.
	assertEquals(only("edit").keepsEnter, true, "a whole command that needs an argument");
	// A name is a word inside a sentence, so its row keeps Enter even complete.
	const alice = completeCandidates({ kind: "nick", start: 0, query: "alice" }, SOURCES)[0];
	assertEquals(alice.keepsEnter, true, "a mention written out in full");
});

Deno.test("an empty name query offers the people first, then the room itself", () => {
	const all = completeCandidates({ kind: "nick", start: 0, query: "" }, SOURCES);
	// Reaching for somebody is what `@` nearly always means, so the members come
	// first and alphabetically. The room-wide names follow rather than taking the
	// top of a list this short.
	assertEquals(all.slice(0, 3).map((c) => c.label), ["alice", "alicia", "bob"]);
	const wide = all.slice(3).map((c) => c.label);
	if (wide.length === 0) fail("reaching the whole room was not offered at all");
	for (const label of wide) {
		if (!label.includes("everyone in this room")) {
			fail(`a name ranked behind the members is not a room-wide one: ${label}`);
		}
	}
});

Deno.test("typing toward a room-wide name brings it straight up", () => {
	const here = completeCandidates({ kind: "nick", start: 0, query: "her" }, SOURCES);
	if (here[0]?.insert !== "@here ") {
		fail(`typing @her offered ${JSON.stringify(here.map((c) => c.insert))} rather than @here first`);
	}
});

Deno.test("every spelling of a room-wide call is understood, two are proposed", () => {
	// Liberal in what it accepts: somebody arriving from another client writes
	// the word their client taught them, and is read rather than corrected.
	for (const name of ROOM_MENTIONS) {
		if (!mentionsYou(`morning @${name}`, "zoe")) fail(`@${name} did not reach a reader of the room`);
	}
	// Brief in what it proposes: a list is a recommendation, and five ways to say
	// one thing recommends nothing.
	for (const offered of ROOM_MENTIONS_OFFERED) {
		if (!ROOM_MENTIONS.includes(offered)) fail(`${offered} is proposed but not understood`);
	}
	if (ROOM_MENTIONS_OFFERED.length >= ROOM_MENTIONS.length) {
		fail("every spelling is proposed, so the list is a menu of synonyms rather than a recommendation");
	}
	// And a room-wide call reaches you whether or not you have a name yet.
	if (!mentionsYou("@here anyone about?", "")) fail("a room-wide call missed a reader with no name granted");
});

Deno.test("prefix matches outrank substring matches", () => {
	const rows = completeCandidates({ kind: "room", start: 0, query: "lo" }, SOURCES);
	// `lobby` and `logs` start with the query; `dev` does not match at all.
	assertEquals(rows.map((c) => c.label), ["lobby", "logs"]);
	const sub = completeCandidates({ kind: "nick", start: 0, query: "li" }, SOURCES);
	assertEquals(sub.map((c) => c.label), ["alice", "alicia"]);
});

Deno.test("emoji rank code before keywords and insert the glyph", () => {
	const rows = completeCandidates({ kind: "emoji", start: 0, query: "fire" }, SOURCES);
	assert(rows.length >= 1, "`fire` finds at least its own code");
	assertEquals(rows[0].label, ":fire:");
	assertEquals(rows[0].insert, "🔥");
	const byKeyword = completeCandidates({ kind: "emoji", start: 0, query: "approve" }, SOURCES);
	assert(byKeyword.some((c) => c.label === ":+1:"), "keywords still reach a row");
});

Deno.test("accepting replaces the trigger and lands the caret after it", () => {
	const trigger = triggerAt("hey @al how", 7);
	assert(trigger !== null, "trigger under the caret");
	const [candidate] = completeCandidates(trigger!, SOURCES);
	const next = acceptCompletion("hey @al how", trigger!, 7, candidate);
	// The insert's own trailing space folds into the one already there.
	assertEquals(next.text, "hey @alice how");
	assertEquals(next.caret, "hey @alice".length);
	const atEnd = acceptCompletion("hey @al", trigger!, 7, candidate);
	assertEquals(atEnd.text, "hey @alice ");
	assertEquals(atEnd.caret, "hey @alice ".length);
});

Deno.test("the emoji table is one authority: unique codes, picker and substitution derive", () => {
	const codes = new Set<string>();
	for (const entry of EMOJI_TABLE) {
		assert(!codes.has(entry.code), `duplicate emoji code: ${entry.code}`);
		codes.add(entry.code);
		assert(entry.glyph.length > 0 && !entry.glyph.includes("�"), `broken glyph for ${entry.code}`);
	}
	assert(PICKER.length > 0, "the tray derives a page of favourites");
	assertEquals(substituteEmoji("ship it :rocket:"), "ship it 🚀");
	assertEquals(substituteEmoji("no such :nope_nope:"), "no such :nope_nope:");
});

Deno.test("what the header claims the registry holds, the registry holds", () => {
	// The file's own first lines name examples of each kind. A name there that no
	// command answers to is the cheapest possible lie and the hardest to notice,
	// because it reads as documentation rather than as a claim — `/clear` was one
	// for a while, described in the header and absent from the list.
	const header = Deno.readTextFileSync(new URL("../web/ui/commands.ts", import.meta.url)).split("\n")
		.filter((line) => line.startsWith("//"))
		.join("\n");
	for (const [, named] of header.matchAll(/`\/(\w+)`/g)) {
		if (commandIn(`/${named}`) === null) {
			fail(`the header names /${named}, which no command answers to`);
		}
	}
});
