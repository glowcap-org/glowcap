// Persistence behind the history seam is one operation at a time: the
// PostgreSQL rewrite is a multi-statement transaction on one connection, so
// an append allowed to interleave would land inside it and vanish with a
// rollback. This suite drives the seam with a scripted backend whose verbs
// only finish on cue, and holds the chain to strict one-at-a-time order.

import { type KeptLine, liveKeptLine, RoomHistory } from "../server/history.ts";
import { assertEquals } from "./assert.ts";
import { HISTORY_LINES_KEPT, HISTORY_ROOMS_KEPT, HistoryIndex, LINES_KEPT } from "../server/history_index.ts";

function gate(): { open: () => void; held: Promise<void> } {
	let open!: () => void;
	const held = new Promise<void>((resolve) => {
		open = resolve;
	});
	return { open, held };
}

Deno.test("backend verbs run one at a time, in the order the room spoke", async () => {
	const history = new RoomHistory(() => {});
	const calls: string[] = [];
	let inFlight = 0;
	let overlapped = false;
	const firstAppend = gate();
	const step = async (name: string, hold?: Promise<void>) => {
		inFlight++;
		if (inFlight > 1) overlapped = true;
		calls.push(name);
		if (hold !== undefined) await hold;
		inFlight--;
	};
	let appends = 0;
	await history.open({
		restore: () => Promise.resolve(),
		append: (_room, line) => step(`append:${line.text}`, ++appends === 1 ? firstAppend.held : undefined),
		replace: (_room, tail) => step(`replace:${tail.map((l) => l.text).join("+")}`),
		close: () => {},
	}, true);
	assertEquals(history.enabled, true);

	const line = (at: number, text: string) => liveKeptLine("alice", text, at);
	const one = line(1, "one");
	history.record("general", one);
	history.record("general", line(2, "two"));
	history.update("general", one, "one, edited");
	// Everything above is queued behind the first append, which is still
	// held open: nothing may have started beside it.
	await new Promise((resolve) => setTimeout(resolve, 20));
	assertEquals(calls, ["append:one"]);
	firstAppend.open();
	await new Promise((resolve) => setTimeout(resolve, 20));
	assertEquals(calls, ["append:one", "append:two", "replace:one, edited+two"]);
	assertEquals(overlapped, false);

	await history.close();
});

Deno.test("an operation persists what the room said at that moment, not later", async () => {
	const history = new RoomHistory(() => {});
	const replaced: string[][] = [];
	const appended: string[] = [];
	const firstAppend = gate();
	let appends = 0;
	await history.open({
		restore: () => Promise.resolve(),
		append: async (_room, line) => {
			appended.push(line.text);
			if (++appends === 1) await firstAppend.held;
		},
		replace: (_room, tail) => {
			replaced.push(tail.map((l) => l.text));
			return Promise.resolve();
		},
		close: () => {},
	}, true);

	const line = (at: number, text: string) => liveKeptLine("alice", text, at);
	const one = line(1, "one");
	history.record("general", one);
	await new Promise((resolve) => setTimeout(resolve, 10));
	history.update("general", one, "one, edited");
	await new Promise((resolve) => setTimeout(resolve, 10));
	history.record("general", line(2, "two"));
	firstAppend.open();
	await new Promise((resolve) => setTimeout(resolve, 20));
	// The rewrite queued before "two" existed must not carry it: a rewrite
	// that did would persist the line a queued append then writes again.
	assertEquals(replaced, [["one, edited"]]);
	assertEquals(appended, ["one", "two"]);

	await history.close();
});

Deno.test("a live line governs its exact retained row, never a restored generation", () => {
	const index = new HistoryIndex();
	const restored: KeptLine = { from: "alice", text: "before restart", at: 1 };
	const live = liveKeptLine("alice", "after restart", 1);
	index.restoreRoom("general", [restored]);
	index.record("general", live);

	assertEquals(index.update("general", live, "after restart, edited")?.map((line) => line.text), [
		"before restart",
		"after restart, edited",
	]);
	assertEquals(index.forget("general", live)?.map((line) => line.text), ["before restart"]);
});

Deno.test("the shared index bounds each room and evicts one oldest whole room at the server edge", () => {
	const index = new HistoryIndex();
	const line = (id: number, at = id): KeptLine => ({ from: "alice", text: `line ${id}`, at });
	for (let id = 1; id <= LINES_KEPT + 1; id++) index.record("solo", line(id));
	assertEquals(
		index.read("solo", LINES_KEPT).map((kept) => kept.text),
		Array.from({ length: LINES_KEPT }, (_, i) => `line ${i + 2}`),
	);

	index.clear();
	for (let room = 0; room < Math.floor(HISTORY_LINES_KEPT / LINES_KEPT); room++) {
		for (let id = 0; id < LINES_KEPT; id++) index.record(`room-${room}`, line(room * LINES_KEPT + id, room));
	}
	let evicted: string | null = null;
	for (let id = 0; id <= HISTORY_LINES_KEPT % LINES_KEPT; id++) {
		evicted = index.record("newest", line(HISTORY_LINES_KEPT + id, 100));
	}
	assertEquals(evicted, "room-0");
	assertEquals(index.read("room-0", LINES_KEPT), []);
	assertEquals(index.read("room-1", LINES_KEPT).length, LINES_KEPT);
	assertEquals(index.read("newest", LINES_KEPT).length, HISTORY_LINES_KEPT % LINES_KEPT + 1);
});

Deno.test("the shared index bounds retained room identities as well as lines", () => {
	const index = new HistoryIndex();
	let evicted: string | null = null;
	for (let room = 0; room <= HISTORY_ROOMS_KEPT; room++) {
		evicted = index.record(`r${room}`, { from: "alice", text: "one", at: room });
	}
	assertEquals(evicted, "r0");
	assertEquals(index.read("r0", 1), []);
	assertEquals(index.read(`r${HISTORY_ROOMS_KEPT}`, 1).length, 1);
});

Deno.test("controlled history shutdown stops admission, drains the last append, then closes storage", async () => {
	const history = new RoomHistory(() => {});
	const append = gate();
	const calls: string[] = [];
	await history.open({
		restore: () => Promise.resolve(),
		append: async () => {
			calls.push("append");
			await append.held;
		},
		replace: () => Promise.resolve(),
		close: () => calls.push("close"),
	}, true);
	history.record("general", { from: "alice", text: "last", at: 1 });
	const closing = history.close();
	history.record("general", { from: "alice", text: "too late", at: 2 });
	await new Promise((resolve) => setTimeout(resolve, 10));
	assertEquals(calls, ["append"]);
	append.open();
	await closing;
	assertEquals(calls, ["append", "close"]);
	assertEquals(history.enabled, false);
});

Deno.test("room servers retain, report, and close history independently", async () => {
	const leftReports: string[] = [];
	const rightReports: string[] = [];
	const closed: string[] = [];
	const left = new RoomHistory((source) => leftReports.push(source));
	const right = new RoomHistory((source) => rightReports.push(source));
	await left.open({
		restore: () => Promise.resolve(),
		append: () => Promise.reject(new Error("left storage failed")),
		replace: () => Promise.resolve(),
		close: () => closed.push("left"),
	}, true);
	await right.open({
		restore: () => Promise.resolve(),
		append: () => Promise.resolve(),
		replace: () => Promise.resolve(),
		close: () => closed.push("right"),
	}, true);

	left.record("general", { from: "alice", text: "left", at: 1 });
	right.record("general", { from: "bob", text: "right", at: 2 });
	await left.close();

	assertEquals(leftReports, ["could not keep a line for general"]);
	assertEquals(rightReports, []);
	assertEquals(closed, ["left"]);
	assertEquals(left.enabled, false);
	assertEquals(right.enabled, true);
	assertEquals(await left.read("general", 10), []);
	assertEquals(await right.read("general", 10), [{ from: "bob", text: "right", at: 2 }]);

	await right.close();
	assertEquals(closed, ["left", "right"]);
});
