// Shared banners sit in the room's centre with no extra words. A line that
// never left this tab is marked, and drawn on your side, so the two cannot
// be mistaken for each other. Consecutive lines of one kind share one run.

import { blocksOf, ONLY_YOU } from "../web/ui/log_blocks.ts";
import { lineCarried } from "../web/ui/commands.ts";
import type { Item } from "../web/ui/types.ts";
import { assertEquals } from "./assert.ts";

const none = new Set<string>();

function banners(history: readonly Item[]) {
	return blocksOf(history, null, none).flatMap((block) => {
		if (block.kind === "banner") {
			return [{ className: block.className, text: block.text, who: block.who }];
		}
		if (block.kind === "span") {
			return block.lines.map((line) => ({
				className: block.className,
				text: line.text,
				who: block.who,
			}));
		}
		return [];
	});
}

Deno.test("a local system line sits on this tab's side and says only you", () => {
	assertEquals(
		banners([{ kind: "sys", id: 1, text: "Not connected", at: 0, audience: "here" }]),
		[{ className: "sys here", text: "Not connected", who: ONLY_YOU }],
	);
});

Deno.test("a room announcement stays a centred banner with no caption", () => {
	assertEquals(
		banners([{ kind: "sys", id: 1, text: "alice joined", at: 0, audience: "shared" }]),
		[{ className: "sys", text: "alice joined", who: undefined }],
	);
});

Deno.test("an action and a notice stay shared banners", () => {
	assertEquals(
		banners([
			{ kind: "action", id: 1, from: "alice", text: "waves", at: 0 },
			// A line reaches the log already stamped with what its words carry,
			// by the same reader the store runs when the line enters.
			{
				kind: "chat",
				id: 2,
				from: "alice",
				text: "/notice keep it down",
				carried: lineCarried("/notice keep it down"),
				mine: false,
				at: 1,
			},
		]),
		[
			{ className: "sys action", text: "✻ alice waves", who: undefined },
			{ className: "sys notice", text: "-alice- keep it down", who: undefined },
		],
	);
});

Deno.test("consecutive local lines share one Only-you run", () => {
	const blocks = blocksOf(
		[
			{
				kind: "sys",
				id: 1,
				text: "Ignoring alice in this window. Their lines still reach the room.",
				at: 0,
				audience: "here",
			},
			{ kind: "sys", id: 2, text: "No longer ignoring alice.", at: 1, audience: "here" },
		],
		null,
		none,
	);
	assertEquals(blocks.filter((block) => block.kind !== "day"), [
		{
			kind: "span",
			key: "s-1",
			className: "sys here",
			who: ONLY_YOU,
			lines: [
				{ key: "b-1", text: "Ignoring alice in this window. Their lines still reach the room." },
				{ key: "b-2", text: "No longer ignoring alice." },
			],
		},
	]);
});

Deno.test("a shared announcement breaks a local run, and a chat line does too", () => {
	const kinds = blocksOf(
		[
			{ kind: "sys", id: 1, text: "first", at: 0, audience: "here" },
			{ kind: "sys", id: 2, text: "alice joined", at: 1, audience: "shared" },
			{ kind: "sys", id: 3, text: "second", at: 2, audience: "here" },
			{ kind: "chat", id: 4, from: "bob", text: "hi", mine: false, at: 3 },
			{ kind: "sys", id: 5, text: "third", at: 4, audience: "here" },
		],
		null,
		none,
	)
		.filter((block) => block.kind !== "day")
		.map((block) => {
			if (block.kind === "span") return `${block.className}:${block.lines.length}`;
			if (block.kind === "group") return "group";
			return block.kind;
		});
	assertEquals(kinds, ["sys here:1", "sys:1", "sys here:1", "group", "sys here:1"]);
});

Deno.test("consecutive room announcements share one centred run", () => {
	assertEquals(
		blocksOf(
			[
				{ kind: "sys", id: 1, text: "alice joined", at: 0, audience: "shared" },
				{ kind: "sys", id: 2, text: "bob joined", at: 1, audience: "shared" },
			],
			null,
			none,
		).filter((block) => block.kind !== "day"),
		[
			{
				kind: "span",
				key: "s-1",
				className: "sys",
				who: undefined,
				lines: [
					{ key: "b-1", text: "alice joined" },
					{ key: "b-2", text: "bob joined" },
				],
			},
		],
	);
});

// Measured against the defects it claims to cover: printing every group's stamp
// the way the log did before turns the first case red, and a day heading that no
// longer restarts the reckoning turns the third one red.
Deno.test("a stamp is printed where it says something the one above it did not", () => {
	// A back-and-forth inside one minute. Every change of speaker opens a group,
	// so without this each of them printed the same four characters.
	const minute = 60_000;
	const stamps = (history: readonly Item[]) =>
		blocksOf(history, null, none)
			.filter((block) => block.kind === "group")
			.map((block) => (block as Extract<typeof block, { kind: "group" }>).group.showTime);
	assertEquals(
		stamps([
			{ kind: "chat", id: 1, from: "bo", text: "morning", mine: false, at: 0 },
			{ kind: "chat", id: 2, from: "ada", text: "hello", mine: true, at: 1000 },
			{ kind: "chat", id: 3, from: "bo", text: "ready?", mine: false, at: 2000 },
		]),
		[true, false, false],
	);
	// A group far enough along to land on another minute answers a new question.
	assertEquals(
		stamps([
			{ kind: "chat", id: 1, from: "bo", text: "morning", mine: false, at: 0 },
			{ kind: "chat", id: 2, from: "ada", text: "hello", mine: true, at: 1000 },
			{ kind: "chat", id: 3, from: "bo", text: "still here?", mine: false, at: 20 * minute },
		]),
		[true, false, true],
	);
	// And across a day heading the same clock time is a different time, so the
	// reckoning starts again.
	assertEquals(
		stamps([
			{ kind: "chat", id: 1, from: "bo", text: "night", mine: false, at: 0 },
			{ kind: "chat", id: 2, from: "ada", text: "morning", mine: true, at: 24 * 60 * minute },
		]),
		[true, true],
	);
});

function drawnIds(history: readonly Item[]): number[] {
	return blocksOf(history, null, none).flatMap((block) =>
		block.kind === "group" ? block.group.items.map((item) => item.id) : []
	);
}

Deno.test("equal text cannot hide a named line while another send waits for its receipt", () => {
	const sending: Item = { kind: "chat", id: 1, from: "ada", text: "hello", mine: true, at: 0, state: "sending" };
	const echo: Item = { kind: "chat", id: 2, from: "ada", text: "hello", mine: true, at: 1, lineId: 7 };
	assertEquals(drawnIds([sending, echo]), [1, 2]);
	// A failed send does not wait, so the room's copy shows beside it.
	assertEquals(drawnIds([{ ...sending, state: "failed" }, echo]), [1, 2]);
	// Different words, another of this reader's lines, and somebody else's
	// line with the same words all draw at once.
	assertEquals(drawnIds([sending, { ...echo, text: "other" }]), [1, 2]);
	assertEquals(drawnIds([sending, { ...echo, mine: false, from: "bob" }]), [1, 2]);
	// Independent messages keep their identities even when the words agree.
	assertEquals(drawnIds([sending, echo, { ...echo, id: 3, lineId: 8 }]), [1, 2, 3]);
});
