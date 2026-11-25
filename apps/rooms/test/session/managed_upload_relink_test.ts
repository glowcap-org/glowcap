// A file a person sends while the link to its session breaks goes out at most
// once. An upload only prepared when the link broke reads its file again and is
// prepared over the new link, because a preparation consumes what it read. One
// the session took is looked up by its operation id over the new link and is
// not uploaded again.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import { until } from "../support/wait.ts";
import { snapshot as managedSnapshot } from "../support/managed_viewer.ts";
import { linkedWorkspace, relinking, request } from "../support/managed_link.ts";
import type { RoomsBrowserSource } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { fixture, store, tick } from "./managed_composer/fixture.ts";

/** What each link's workspace saw: one entry per upload prepared over it, as
 * the link's name and how many files it read, and the operation id each
 * preparation named. */
type Seen = { prepared: string[]; ids: string[]; submitted: string[]; lookups: string[] };

/** A composer whose sends go through a page linked to `first`, then `second`,
 * with a file picked in a room that allows files. */
async function sending(first: ReturnType<typeof linkedWorkspace>, second: ReturnType<typeof linkedWorkspace>) {
	const f = fixture();
	const { session, relinked } = relinking(first.workspace, second.workspace);
	await session.start();
	const current = managedSnapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "first",
		directory: "directory",
		name: "first",
		access: null,
		seat: "seat",
		control: null,
		reconnect: "manual",
		standing: null,
		draft: "",
	});
	Object.defineProperty(f.session, "current", { value: current });
	f.session.readNow = () => Promise.resolve(current);
	f.session.perform = (...args) => session.perform(...args);
	const room = store.getConv(f.page.projection, f.first.key);
	if (room?.type !== "room") throw new Error("room fixture");
	store.put(f.page.projection, { ...room, grants: new Set(["files"]) });
	f.completion.resolve();
	const send = () => {
		store.addDraftFiles(f.page.projection, [new File(["picked bytes"], "picked.txt", { type: "text/plain" })]);
		f.actions.send();
	};
	const close = async () => {
		await session.close();
		f.close();
	};
	return { f, session, relinked, send, close };
}

/** The rooms whose line landed, and how many lines the room shows. */
const lines = (f: ReturnType<typeof fixture>) => [
	f.linesLanded,
	store.historyOf(f.page.projection, f.first.key).filter((row) => row.kind === "chat").length,
];

/** A workspace's upload preparation over the link `name`, recorded in `seen`,
 * answered by `prepared` once the file it read is released, as the binding's
 * argument conversion consumes it. */
function uploads(name: string, seen: Seen, prepared: () => Promise<unknown>) {
	return {
		prepareUpload: (
			id: string,
			_revision: string,
			_conversation: string,
			_caption: string,
			_previews: string,
			sources: RoomsBrowserSource[],
		) => {
			seen.prepared.push(`${name}:${sources.length}`);
			seen.ids.push(id);
			for (const source of sources) source.free();
			return prepared();
		},
	};
}

/** A file line the session committed, submitted over the link `name`. */
const committed = (name: string, seen: Seen) =>
	Promise.resolve(Object.assign(
		request(() => {
			seen.submitted.push(name);
			return Promise.resolve({ status: "committed" });
		}, () => Promise.resolve("committed")),
		{ result: () => Promise.resolve(null) },
	));

Deno.test("a file only prepared when the link broke is read again and uploaded once over the new link", async () => {
	const seen: Seen = { prepared: [], ids: [], submitted: [], lookups: [] };
	const first = linkedWorkspace("first", []);
	Object.assign(first.workspace, uploads("first", seen, () => first.park()));
	const second = linkedWorkspace("second", []);
	Object.assign(second.workspace, uploads("second", seen, () => committed("second", seen)));
	const { f, relinked, send, close } = await sending(first, second);
	try {
		send();
		await until(() => seen.prepared.length === 1, "the first preparation");
		first.lose();
		await relinked();
		await until(() => f.linesLanded.length > 0, "the upload to land");
		for (let i = 0; i < 5; i++) await tick();
		assertEquals([seen.prepared, seen.submitted], [["first:1", "second:1"], ["second"]]);
		assertEquals(seen.ids, [seen.ids[0], seen.ids[0]], "both preparations name one operation");
		assertEquals(lines(f), [["first"], 1], "the file line lands once");
	} finally {
		await close();
	}
});

Deno.test("a file upload the session took before the link broke is looked up over the new link, never sent again", async () => {
	const seen: Seen = { prepared: [], ids: [], submitted: [], lookups: [] };
	const held = new Set<string>();
	const first = linkedWorkspace("first", []);
	Object.assign(
		first.workspace,
		uploads("first", seen, () =>
			Promise.resolve(request(() => {
				seen.submitted.push("first");
				held.add(seen.ids[0]);
				return first.submitLost();
			}, () => first.park<string>()))),
	);
	const second = linkedWorkspace("second", []);
	Object.assign(second.workspace, {
		...uploads("second", seen, () => committed("second", seen)),
		recoverEffect: (id: string) => {
			seen.lookups.push(id);
			return Promise.resolve(
				!held.has(id) ? null : {
					status: () => Promise.resolve("committed"),
					resume: () => Promise.resolve("committed"),
					result: () => Promise.resolve(null),
					free() {},
				},
			);
		},
	});
	const { f, relinked, send, close } = await sending(first, second);
	try {
		send();
		await until(() => seen.submitted.length === 1, "the upload to reach the session");
		first.lose();
		await relinked();
		await until(() => f.linesLanded.length > 0, "the upload to land");
		for (let i = 0; i < 5; i++) await tick();
		assertEquals([seen.prepared, seen.submitted, seen.lookups], [["first:1"], ["first"], seen.ids]);
		assertEquals(lines(f), [["first"], 1], "the file line lands once");
	} finally {
		await close();
	}
});
