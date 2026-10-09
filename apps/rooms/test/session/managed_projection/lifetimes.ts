// Live registration and entrance lifetimes do not replace a conversation.
import { assert, assertEquals } from "../../assert.ts";
import * as store from "../../../web/ui/store.ts";
import { dirId } from "../../../web/ui/types.ts";
import { fixture, room } from "./fixture.ts";

for (const retirement of ["notice", "snapshot", "replacement"] as const) {
	Deno.test(`managed room line numbers retire with membership: ${retirement}`, () => {
		const row = room();
		assert(row.kind === "room", "room fixture");
		row.seat = "original-seat";
		row.inbox = "original-inbox";
		const f = fixture(row);
		const line = (text: string, change: "said" | "edited" = "said") =>
			f.projection.activity({
				cursor: text,
				gap: false,
				event: {
					target: { kind: "room", id: row.id },
					notice: { kind: "line", from: "bo", text, marker: { id: 1, change } },
				},
			});
		try {
			line("old generation");
			const key = f.selected().key;
			const original = store.historyOf(f.page.projection, key).find((item) => item.kind === "chat")!;
			store.updateItem(f.page.projection, key, original.id, { held: true });
			store.startChange(f.page.projection, original.id, "unfinished edit");
			if (retirement === "notice") {
				f.projection.activity({
					cursor: "ended",
					gap: false,
					event: { target: { kind: "room", id: row.id }, notice: { kind: "ended" } },
				});
			} else if (retirement === "snapshot") {
				delete row.seat;
				f.apply();
			}
			row.seat = "replacement-seat";
			row.inbox = "replacement-inbox";
			f.apply();
			assertEquals(store.draftFor(f.page.projection, key).changing, undefined);
			assertEquals(store.draftFor(f.page.projection, key).text, "unfinished edit");
			const retired = store.historyOf(f.page.projection, key).find((item) => item.id === original.id);
			assertEquals(retired?.kind === "chat" && retired.held, false);
			line("new generation");
			line("new generation edited", "edited");
			const lines = store.historyOf(f.page.projection, f.selected().key).filter((item) => item.kind === "chat");
			assertEquals(lines.map((item) => [item.text, item.lineId]), [
				["old generation", undefined],
				["new generation edited", 1],
			]);
		} finally {
			f.close();
		}
	});
}

Deno.test("directory registration retirement reports only its own outage and restoration", () => {
	const f = fixture();
	try {
		const home = f.current.intent.directories[0];
		home.name = "home-registration";
		home.assignedNick = "ada";
		f.current.intent.directories.push({ ...home, id: "elsewhere", home: false, name: "other-registration" });
		f.apply();
		const id = dirId(home.id);
		const other = dirId("elsewhere");
		assertEquals(f.page.projection.get().dirs.get(id)?.session, "connected");
		delete home.name;
		delete home.assignedNick;
		f.apply();
		assertEquals(f.page.projection.get().dirs.get(id)?.session, "reconnecting");
		assert(f.page.projection.get().dirs.get(id)?.statusText !== "", "retirement must remain visible");
		assertEquals(f.page.projection.get().dirs.get(other)?.session, "connected");
		delete f.current.intent.directories[1].name;
		delete f.current.intent.directories[1].assignedNick;
		f.apply();
		store.patchDir(f.page.projection, other, {
			session: "disconnected",
			statusText: "Other directory unavailable",
		});
		home.name = "restored-registration";
		home.assignedNick = "ada";
		f.apply();
		assertEquals(f.page.projection.get().dirs.get(id)?.session, "connected");
		assertEquals(f.page.projection.get().dirs.get(id)?.statusText, "");
		assertEquals(f.page.projection.get().dirs.get(other)?.session, "disconnected");
		assertEquals(f.page.projection.get().dirs.get(other)?.statusText, "Other directory unavailable");
	} finally {
		f.close();
	}
});

Deno.test("saving a public room entrance preserves its identity through worker replacement", () => {
	const row = room();
	assert(row.kind === "room", "room fixture");
	row.publicEntry = { access: "directory-access" };
	row.publication = "exact-bridge-generation";
	row.seat = "original-seat";
	const f = fixture(row);
	try {
		const before = f.selected();
		store.setRoomMembership(f.page.projection, before.key, "joined");
		store.deliver(f.page.projection, before.key, store.sysItem(f.page.projection, "kept line"));
		f.stage("kept draft");
		f.page.projection.set({ aboutConv: true });
		row.access = "exact-saved-link";
		delete row.publicEntry;
		f.apply();
		delete row.seat;
		f.apply();
		row.seat = "replacement-seat";
		f.apply();
		const after = f.selected();
		assert(after.type === "room", "room projection");
		assertEquals([after.key, after.publicationId, after.linkToken], [before.key, row.publication, row.access]);
		assertEquals(f.page.projection.get().convs.size, 1);
		assertEquals(store.historyOf(f.page.projection, after.key).length, 1);
		assertEquals(store.draftFor(f.page.projection, after.key).text, "kept draft");
		assertEquals(f.page.projection.get().aboutConv, true);
	} finally {
		f.close();
	}
});

Deno.test("choosing a different directory nickname does not report an outage", () => {
	const f = fixture();
	try {
		const row = f.current.intent.directories[0];
		row.name = "original-registration";
		row.assignedNick = "ada";
		f.apply();
		row.nick = "bo";
		delete row.name;
		delete row.assignedNick;
		f.apply();
		const view = f.page.projection.get().dirs.get(dirId(row.id));
		assertEquals(view?.requestedNick, "bo");
		assertEquals(view?.session, "connected");
		assertEquals(view?.statusText, "");
	} finally {
		f.close();
	}
});
