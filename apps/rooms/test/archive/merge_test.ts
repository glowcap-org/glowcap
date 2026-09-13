// The combined archive view's coalescing rule (ADR-0144): one coordinate key
// shows one record, lifecycle state outranks, the write target breaks the
// remaining tie, and no record ever leaves its recorder's source.

import { mergeArchiveAccounts } from "../support/archive/merge.ts";
import type { ArchiveLine, ArchiveStanding } from "../../lib/archive/protocol.ts";
import { assertEquals } from "../assert.ts";

function line(id: string, over: Partial<ArchiveLine> = {}): ArchiveLine {
	return {
		kind: "line",
		source: "source-a",
		generation: "generation-1",
		id,
		conversationKind: "direct",
		directory: "directory",
		conversation: "peer",
		from: "peer",
		text: `text of ${id}`,
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [],
		...over,
	};
}

function standing(id = "standing"): ArchiveStanding {
	return {
		kind: "standing",
		source: "source-a",
		generation: "generation-1",
		id,
		directory: "directory",
		room: "room",
		nick: "ada",
		at: 1,
	};
}

Deno.test("disjoint accounts contribute every record under its own keeper", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "this device", writes: false, records: [line("one")] },
		{ keeper: "peer", writes: true, records: [line("two", { source: "source-b" })] },
	]);
	assertEquals(merged.map(({ keeper, record }) => [keeper, record.id]), [
		["this device", "one"],
		["peer", "two"],
	]);
});

Deno.test("one coordinate key in two accounts is one record, not two", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "this device", writes: false, records: [line("shared")] },
		{ keeper: "peer", writes: true, records: [line("shared")] },
	]);
	assertEquals(merged.length, 1, "a duplicated key must not render twice");
	assertEquals(merged[0].keeper, "peer", "the write target holds the newest intent");
});

Deno.test("a withdrawal in any account outranks the stale present record", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "peer", writes: true, records: [line("gone")] },
		{ keeper: "this device", writes: false, records: [line("gone", { state: "withdrawn", text: "" })] },
	]);
	assertEquals(merged.length, 1);
	assertEquals(
		[merged[0].keeper, merged[0].record.kind === "line" ? merged[0].record.state : null],
		["this device", "withdrawn"],
		"the member withdrew after switching recorders; the older present copy must not stand",
	);
});

Deno.test("an edit outranks the present original whichever account holds it", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "this device", writes: true, records: [line("edited", { text: "before" })] },
		{
			keeper: "peer",
			writes: false,
			records: [line("edited", { state: "edited", text: "after" })],
		},
	]);
	assertEquals(merged.length, 1);
	assertEquals(merged[0].record.kind === "line" ? merged[0].record.text : null, "after");
});

Deno.test("equal states with different content favor the write target", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "this device", writes: false, records: [line("twice", { state: "edited", text: "older edit" })] },
		{ keeper: "peer", writes: true, records: [line("twice", { state: "edited", text: "newer edit" })] },
	]);
	assertEquals(merged.length, 1);
	assertEquals(merged[0].record.kind === "line" ? merged[0].record.text : null, "newer edit");
});

Deno.test("without a write target the listed order names the preference", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "first", writes: false, records: [line("tie", { text: "first account" })] },
		{ keeper: "second", writes: false, records: [line("tie", { text: "second account" })] },
	]);
	assertEquals(merged.length, 1);
	assertEquals(merged[0].keeper, "first");
});

Deno.test("two recorder sources never merge into one account", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "peer", writes: true, records: [line("same-id", { source: "device-one" })] },
		{ keeper: "peer", writes: true, records: [line("same-id", { source: "device-two" })] },
	]);
	assertEquals(merged.length, 2, "distinct sources are distinct accounts of the conversation");
});

Deno.test("standings coalesce under the same rule", () => {
	const merged = mergeArchiveAccounts([
		{ keeper: "this device", writes: false, records: [standing()] },
		{ keeper: "peer", writes: true, records: [{ ...standing(), nick: "ada elsewhere" }] },
	]);
	assertEquals(merged.length, 1);
	assertEquals(merged[0].record.kind === "standing" ? merged[0].record.nick : null, "ada elsewhere");
});
