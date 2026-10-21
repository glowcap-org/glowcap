// Live registration and entrance lifetimes do not replace a conversation.
import { assert, assertEquals } from "../../assert.ts";
import * as store from "../../../web/ui/store.ts";
import { dirId } from "../../../web/ui/types.ts";
import { direct, fixture, room } from "./fixture.ts";

for (const target of [room, direct]) {
	for (const saved of [false, true]) {
		Deno.test(`explicit ${target().kind} selection leaves directory view, saved selection: ${saved}`, () => {
			const f = fixture();
			try {
				const view = store.ensureDirectory(f.page.projection, dirId("directory"));
				store.switchTo(f.page.projection, view.key);
				store.setDraft(f.page.projection, "/help");
				const row = { ...target(), id: "new-conversation" };
				f.current.intent.conversations.push(row);
				if (saved) f.current.intent.active = row.id;
				f.apply();
				assertEquals(store.activeConv(f.page.projection)?.key, view.key);
				f.navigation.choice = { id: row.id, operation: "first-choice" };
				f.projection.apply();
				assertEquals(f.selected().persistId, row.id);
				assertEquals(store.draftFor(f.page.projection, view.key).text, "/help");
				// A pending selection save must not undo a subsequent directory choice.
				store.switchTo(f.page.projection, view.key);
				f.apply();
				assertEquals(store.activeConv(f.page.projection)?.key, view.key);
				// Choosing the same room again is a new gesture, even while its
				// earlier selection receipt still waits for acknowledgment. status-allow: event or source ordering
				f.navigation.choice = { id: row.id, operation: "next-choice" };
				f.projection.apply();
				assertEquals(f.selected().persistId, row.id);
			} finally {
				f.close();
			}
		});
	}
}

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

for (const change of ["kind", "directory", "name", "publication", "unpublish"] as const) {
	Deno.test(`managed ${change} preserves only the same persistent conversation`, () => {
		const f = fixture();
		try {
			const before = f.selected();
			store.deliver(
				f.page.projection,
				before.key,
				store.chatItem(f.page.projection, "bo", "old identity", false),
			);
			f.stage("old recipient draft");
			const row = f.current.intent.conversations[0];
			assert(row.kind === "room", "managed projection contract");
			if (change === "kind") f.current.intent.conversations = [direct()];
			if (change === "name") row.name = "renamed room";
			if (change === "unpublish") {
				delete row.publication;
				delete row.publicEntry;
			}
			if (change === "publication") {
				row.publicEntry = { access: "directory-access" };
				row.publication = "another-publication";
			}
			if (change === "directory") {
				row.directory = "another-directory";
				f.current.intent.directories.push({
					...f.current.intent.directories[0],
					id: row.directory,
					home: false,
				});
			}
			f.apply();
			const after = f.selected();
			assertEquals(after.persistId, before.persistId);
			if (change === "kind" || change === "directory") {
				assertEquals(store.historyOf(f.page.projection, after.key), []);
				assertEquals(
					store.draftFor(f.page.projection, after.key).text,
					f.current.intent.conversations[0].draft,
				);
			} else {
				assertEquals(store.historyOf(f.page.projection, after.key).length, 1);
				assertEquals(after.key, before.key);
				assertEquals(store.draftFor(f.page.projection, after.key).text, "old recipient draft");
			}
		} finally {
			f.close();
		}
	});
}

Deno.test("room traffic cannot enable the composer before the accepted seat, and late installation restores it", () => {
	const row = room();
	assert(row.kind === "room", "room fixture");
	row.inbox = "joining-inbox";
	const f = fixture(row);
	try {
		f.projection.activity({
			cursor: "early",
			event: {
				target: { kind: "room", id: row.id },
				notice: { kind: "line", from: "bo", text: "already here" },
			},
		});
		assertEquals((f.selected() as import("../../../web/ui/types.ts").RoomConv).membership === "joined", false);
		f.apply();
		row.seat = "accepted-seat";
		f.apply();
		assertEquals((f.selected() as import("../../../web/ui/types.ts").RoomConv).membership, "joined");
		f.projection.activity({
			cursor: "ended",
			event: {
				target: { kind: "room", id: row.id },
				notice: { kind: "ended" },
			},
		});
		f.apply();
		assertEquals((f.selected() as import("../../../web/ui/types.ts").RoomConv).membership, "unavailable");
		row.inbox = "replacement-inbox";
		row.seat = "replacement-seat";
		f.apply();
		assertEquals((f.selected() as import("../../../web/ui/types.ts").RoomConv).membership, "joined");
	} finally {
		f.close();
	}
});
