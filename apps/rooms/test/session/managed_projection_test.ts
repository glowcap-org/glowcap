// Exercise the production presentation owner with managed workspace intent and activity.
/// <reference lib="dom" />
import { assert, assertEquals } from "../assert.ts";
import type { ActivityPage } from "../../web/ui/session/managed/model.ts";
import type { RoomInfo } from "../../lib/directory_publications.ts";
import type { Presence } from "../../lib/room/presence.ts";
import { initializeApplication } from "../support/application.ts";
import { ROOM_SENDER } from "../../lib/protocol_data.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");
await initializeApplication();

const { fixture, room, direct } = await import("./managed_projection/fixture.ts");
await import("./managed_projection/lifetimes.ts");
await import("./managed_projection/commits.ts");
await import("./managed_projection/notices.ts");
await import("./managed_projection/delivery.ts");

Deno.test("managed occupancy changes visibility and keeps the independent seat live", () => {
	const row = room();
	assert(row.kind === "room", "room fixture");
	row.seat = "seat";
	const f = fixture(row);
	try {
		const before = f.selected();
		assert(before.type === "room", "room projection");
		store.setRoomPolicy(f.page.projection, before.key, {
			visibility: "listed",
			entry: "open",
			speaking: "open",
		});
		store.setRoomMembership(f.page.projection, before.key, "joined");
		f.projection.activity({
			cursor: "1",
			gap: false,
			event: {
				target: { kind: "room", id: row.id },
				notice: { kind: "occupancy", listed: false, claimable: true },
			},
		});
		const after = f.selected();
		assert(after.type === "room", "room projection");
		assertEquals(after.policy, { visibility: "secret", entry: "invite-only", speaking: "moderated" });
		assertEquals(after.membership, "joined");
		assertEquals(after.key, before.key);
		assertEquals(row.seat, "seat");
	} finally {
		f.close();
	}
});

Deno.test("managed public room retains its publication for bridge facts and repeated entry", () => {
	const row = room();
	assert(row.kind === "room", "room fixture");
	row.publicEntry = { access: "directory-access" };
	row.publication = "bridge-publication";
	const f = fixture(row);
	try {
		const selected = f.selected();
		assert(selected.type === "room", "room projection");
		assertEquals(selected.publicationId, "bridge-publication");
		assertEquals(store.existingRoom(f.page.projection, dirId("directory"), "garden")?.persistId, row.id);
		f.apply();
		assertEquals(f.selected().key, selected.key);
	} finally {
		f.close();
	}
});

Deno.test("revoking an entrance preserves the independent seat and its displayed lines", () => {
	const row = room();
	if (row.kind !== "room") throw new Error("room");
	row.access = "entry";
	row.seat = "seat";
	const f = fixture(row);
	try {
		const conversation = store.convByPersistId(f.page.projection, row.id)!;
		store.deliver(f.page.projection, conversation.key, store.sysItem(f.page.projection, "retained history"));
		row.access = null;
		f.apply();
		assertEquals(store.convByPersistId(f.page.projection, row.id)?.key, conversation.key);
		assertEquals(store.historyOf(f.page.projection, conversation.key).length, 1);
	} finally {
		f.close();
	}
});

Deno.test("managed connection loss retires live grants while preserving the conversation", () => {
	const original = room();
	assert(original.kind === "room", "fixture supplies a room");
	original.seat = "seat-one";
	original.files = "files-one";
	original.topic = "topic-one";
	original.access = "entrance-one";
	original.reconnect = "requested";
	const f = fixture(original);
	try {
		const before = f.selected();
		store.setRoomMembership(f.page.projection, before.key, "joined");
		store.deliver(f.page.projection, before.key, store.chatItem(f.page.projection, "bo", "kept history", false));
		f.stage("kept draft");
		delete original.seat;
		delete original.files;
		delete original.topic;
		f.apply();
		const after = f.selected();
		assert(after.type === "room", "room remains selected");
		assertEquals(after.membership, "unavailable");
		assertEquals(after.key, before.key);
		assertEquals(after.linkToken, "entrance-one");
		assertEquals(after.reconnect, "requested");
		assertEquals([after.grants.has("files"), after.grants.has("topic")], [false, false]);
		assertEquals(store.historyOf(f.page.projection, after.key).length, 1);
		assertEquals(store.draftFor(f.page.projection, after.key).text, "kept draft");
	} finally {
		f.close();
	}
});

Deno.test("managed membership warns once when entering under an ignored name of your own", () => {
	const f = fixture();
	try {
		f.current.intent.directories[0].assignedNick = "Ada";
		f.current.intent.ignored = ["ada"];
		const row = f.current.intent.conversations[0];
		assert(row.kind === "room", "room fixture");
		row.seat = "accepted-seat";
		f.apply();
		const key = f.selected().key;
		f.page.projection.set({ activeKey: null });
		const arrival: ActivityPage = {
			cursor: "1",
			gap: false,
			event: {
				target: { kind: "room", id: "conversation" },
				notice: { kind: "line", from: ROOM_SENDER, text: "joined" },
			},
		};
		f.projection.activity(arrival);
		f.projection.activity({ ...arrival, cursor: "2" });
		assertEquals(store.historyOf(f.page.projection, key).every((item) => item.kind === "sys"), true);
		assertEquals(store.unreadOf(f.page.projection, key).kind, "caught-up");
		const warnings = store.historyOf(f.page.projection, key).filter((item) =>
			item.kind === "sys" && item.text.includes("is on your ignore list")
		);
		assertEquals(warnings.length, 1);
	} finally {
		f.close();
	}
});

Deno.test("managed authority changes preserve selection, history and a newer local draft", () => {
	const f = fixture();
	try {
		const before = f.selected();
		store.deliver(
			f.page.projection,
			before.key,
			store.chatItem(f.page.projection, "bo", "before authority", false),
		);
		f.stage("newer local edit");
		const row = f.current.intent.conversations[0];
		assert(row.kind === "room", "managed projection contract");
		row.access = "exact-room";
		row.moderator = "exact-moderator";
		f.apply();
		const acquired = f.selected();
		assertEquals(acquired.key, before.key);
		assertEquals(store.historyOf(f.page.projection, acquired.key).length, 1);
		assertEquals(store.draftFor(f.page.projection, acquired.key).text, "newer local edit");
		assert(acquired.type === "room", "managed projection contract");
		assertEquals([acquired.linkToken, acquired.stewardToken, acquired.grants.has("steward")], [
			"exact-room",
			"exact-moderator",
			true,
		]);
		row.access = null;
		delete row.moderator;
		f.apply();
		const narrowed = f.selected();
		assert(narrowed.type === "room", "managed projection contract");
		assertEquals([narrowed.linkToken, narrowed.stewardToken, narrowed.grants.has("steward")], [
			undefined,
			undefined,
			false,
		]);
	} finally {
		f.close();
	}
});

Deno.test("managed direct route replacement cannot inherit the previous peer history", () => {
	const f = fixture(direct());
	try {
		const before = f.selected();
		store.deliver(f.page.projection, before.key, store.chatItem(f.page.projection, "bo", "previous holder", false));
		f.current.intent.conversations[0].access = "route-two";
		f.apply();
		assert(f.selected().key !== before.key, "managed projection contract");
		assertEquals(store.historyOf(f.page.projection, f.selected().key), []);
	} finally {
		f.close();
	}
});

Deno.test("managed unchanged intent preserves shared store identities across receipt revisions", () => {
	const f = fixture();
	try {
		const before = f.page.projection.get();
		f.apply();
		const after = f.page.projection.get();
		for (const key of ["convs", "dirs", "drafts", "invites", "archiveShares", "ignored", "remembered"] as const) {
			assert(before[key] === after[key], `unchanged intent replaced ${key}`);
		}
		f.current.intent.directories[0].home = false;
		f.apply();
		assertEquals(f.page.projection.get().homeDir, null);
	} finally {
		f.close();
	}
});

Deno.test("managed direct readiness and line activity preserve live state across intent changes", () => {
	const row = direct();
	assert(row.kind === "direct", "direct scenario");
	row.inbox = "installed-callback";
	const f = fixture(row);
	try {
		const before = f.selected();
		assert(before.type === "dm", "managed projection contract");
		f.projection.activity({
			cursor: "ready",
			event: { target: { kind: "direct", id: before.persistId }, notice: { kind: "ready" } },
		});
		f.apply();
		const ready = f.selected();
		assert(ready.type === "dm", "managed projection contract");
		assertEquals(ready.line, "live");
		f.projection.activity({
			cursor: "line",
			event: {
				target: { kind: "direct", id: before.persistId },
				notice: { kind: "line", from: ROOM_SENDER, text: "hello", marker: { id: 1, change: "said" } },
			},
		});
		const line = store.historyOf(f.page.projection, before.key).find((item) => item.kind === "chat");
		assertEquals(line?.from, ROOM_SENDER);
		const row = f.current.intent.conversations[0];
		assert(row.kind === "direct", "managed projection contract");
		row.closed = true;
		f.apply();
		const closed = f.selected();
		assert(closed.type === "dm", "managed projection contract");
		assertEquals(closed.line, "closed");
	} finally {
		f.close();
	}
});

Deno.test("managed discovery establishes directory liveness and ignores stale publication removal", () => {
	const f = fixture();
	try {
		const id = dirId("directory");
		assertEquals(f.page.projection.get().dirs.get(id)?.reached, false);
		const entry: RoomInfo = {
			id: "current",
			name: "garden",
			kind: "foreign",
			count: null,
			origin: "elsewhere",
			proof: "authenticated",
			offers: "participant",
		};
		f.projection.activity({
			cursor: "snapshot",
			event: {
				target: { kind: "discovery", id },
				notice: { kind: "discoverySnapshot", snapshot: { rooms: [entry], peers: [], omitted: 0 } },
			},
		});
		assertEquals(f.page.projection.get().dirs.get(id)?.session, "connected");
		f.projection.activity({
			cursor: "closed",
			event: {
				target: { kind: "discovery", id },
				notice: {
					kind: "discoveryChanged",
					event: { kind: "closed", name: entry.name, count: null, entry: { ...entry, id: "old" } },
				},
			},
		});
		assertEquals(store.liveRoom(f.page.projection, id, "garden")?.id, "current");
	} finally {
		f.close();
	}
});

Deno.test("managed state-only room activity updates presence and facts without drawing empty lines", () => {
	const f = fixture();
	try {
		const row = f.selected();
		const event = (presence: Presence): ActivityPage => ({
			cursor: "presence",
			event: {
				target: { kind: "room" as const, id: row.persistId },
				notice: {
					kind: "line",
					from: "",
					text: "",
					metadata: { presence, facts: { topic: "Bridge topic", lineBytes: 512 } },
				},
			},
		});
		f.page.projection.set({ members: new Map([[row.key, new Map([["ada", { online: true, away: "" }]])]]) });
		f.projection.activity(
			event({
				kind: "seat",
				name: "ada",
				state: "connecting",
				nick: "ada_irc",
				network: "Libera",
				badge: "LINKING",
				said: "Linking",
			}),
		);
		assertEquals(store.membersOf(f.page.projection, row.key).get("ada")?.seat?.state, "connecting");
		assertEquals(store.historyOf(f.page.projection, row.key).length, 0);
		const current = f.selected();
		assert(current.type === "room", "managed projection contract");
		assertEquals([current.topic, current.lineBytes], ["Bridge topic", 512]);
	} finally {
		f.close();
	}
});

Deno.test("managed intent projection preserves an in-progress line edit", () => {
	const f = fixture();
	try {
		const before = store.draftFor(f.page.projection, f.selected().key);
		f.apply();
		assertEquals(store.draftFor(f.page.projection, f.selected().key) === before, true);
		store.startChange(f.page.projection, 42, "editing a posted line");
		const edit = store.activeDraft(f.page.projection);
		f.apply();
		assertEquals(store.activeDraft(f.page.projection) === edit, true);
	} finally {
		f.close();
	}
});

Deno.test("managed incoming direct lines use this page's notification gate", () => {
	const f = fixture(direct());
	const previous = globalThis.Notification;
	const notifications: string[] = [];
	Object.defineProperty(globalThis, "Notification", {
		configurable: true,
		value: class {
			static permission = "granted";
			constructor(title: string) {
				notifications.push(title);
			}
		},
	});
	try {
		f.page.projection.set({ activeKey: null, notifyOn: true, visible: false });
		f.projection.activity({
			cursor: "notification",
			event: {
				target: { kind: "direct", id: "conversation" },
				notice: { kind: "line", text: "hello", marker: { id: 1, change: "said" } },
			},
		});
		assertEquals(notifications, ["bo"]);
		f.page.projection.set({ ignored: new Set(["bo"]) });
		f.projection.activity({
			cursor: "silenced",
			event: {
				target: { kind: "direct", id: "conversation" },
				notice: { kind: "line", text: "silenced", marker: { id: 2, change: "said" } },
			},
		});
		assertEquals(notifications, ["bo"]);
	} finally {
		Object.defineProperty(globalThis, "Notification", { configurable: true, value: previous });
		f.page.projection.set({ notifyOn: false, visible: true });
		f.close();
	}
});

Deno.test("managed active selection preserves this tab's directory view and draft", () => {
	const f = fixture();
	try {
		const view = store.ensureDirectory(f.page.projection, dirId("directory"));
		store.switchTo(f.page.projection, view.key);
		store.setDraft(f.page.projection, "/help");
		f.current.intent.active = null;
		f.apply();
		assertEquals(store.activeConv(f.page.projection)?.key, view.key);
		assertEquals(store.activeDraft(f.page.projection).text, "/help");
		assertEquals(f.current.intent.conversations.length, 1);
	} finally {
		f.close();
	}
});

Deno.test("managed invitation and archive offers retire when removed from intent", () => {
	const f = fixture();
	try {
		f.current.intent.invitations.push({
			id: "invite",
			directory: "directory",
			label: "plans",
			from: "bo",
			authority: { role: "offer", key: "exact-offer" },
		});
		f.current.intent.archiveShares = [{
			id: "history",
			channel: "conversation",
			directory: "directory",
			source: "source",
			from: "bo",
			kind: "room",
			conversation: "garden",
			access: "exact-history",
			durable: false,
		}];
		f.apply();
		assertEquals(f.page.projection.get().invites.map((row) => [row.id, row.label, row.link]), [[
			"invite",
			"plans",
			"",
		]]);
		assertEquals(f.page.projection.get().archiveShares.map((row) => [row.id, row.custody, row.copyable]), [[
			"history",
			"live",
			false,
		]]);
		f.current.intent.invitations = [];
		f.current.intent.archiveShares = [];
		f.apply();
		assertEquals(f.page.projection.get().invites, []);
		assertEquals(f.page.projection.get().archiveShares, []);
	} finally {
		f.close();
	}
});

Deno.test("managed direct activity isolates same-named peers in different directories", () => {
	const f = fixture(direct());
	try {
		f.current.intent.directories.push({ ...f.current.intent.directories[0], id: "elsewhere", home: false });
		f.current.intent.conversations.push({ ...direct(), id: "other", directory: "elsewhere" });
		f.apply();
		const other = store.convByPersistId(f.page.projection, "other")!;
		const first = f.selected();
		for (const [id, text] of [["conversation", "first"], ["other", "second"]]) {
			f.projection.activity({
				cursor: id,
				event: {
					target: { kind: "direct", id },
					notice: { kind: "line", text, marker: { id: 1, change: "said" } },
				},
			});
		}
		assertEquals(
			store.historyOf(f.page.projection, first.key).filter((item) => item.kind === "chat").map((item) =>
				item.text
			),
			["first"],
		);
		assertEquals(
			store.historyOf(f.page.projection, other.key).filter((item) => item.kind === "chat").map((item) =>
				item.text
			),
			["second"],
		);
		f.projection.activity({
			cursor: "ended",
			event: {
				target: { kind: "direct", id: "conversation" },
				notice: { kind: "ended", reason: "peer retired" },
			},
		});
		const closed = store.getConv(f.page.projection, first.key);
		assertEquals(closed?.type === "dm" ? closed.line : null, "closed");
		const live = store.getConv(f.page.projection, other.key);
		assertEquals(live?.type === "dm" ? live.line : null, "live");
	} finally {
		f.close();
	}
});

Deno.test("managed recovery pending changes project without a workspace revision", () => {
	const f = fixture();
	try {
		f.pending.push("original-command");
		f.acquisitions.push("original-acquisition");
		f.projection.apply();
		assertEquals(f.page.projection.get().sessionEffects, ["original-command", "original-acquisition"]);
		const unchanged = f.page.projection.get().sessionEffects;
		f.projection.apply();
		assertEquals(f.page.projection.get().sessionEffects === unchanged, true);
		f.pending.splice(0);
		f.acquisitions.splice(0);
		f.projection.apply();
		assertEquals(f.page.projection.get().sessionEffects, []);
	} finally {
		f.close();
	}
});

Deno.test("managed direct readiness waits for committed route and callback custody", () => {
	const row = direct();
	assert(row.kind === "direct", "direct scenario");
	row.access = null;
	row.inbox = "installed-callback";
	row.introduction = {
		access: "directory-access",
		name: "our-name",
		callback: "our-inbox",
		registration: "peer-registration",
		opening: "opening",
	};
	const f = fixture(row);
	const line = () => {
		const selected = f.selected();
		assert(selected.type === "dm", "direct scenario");
		return selected.line;
	};
	try {
		f.projection.activity({
			cursor: "ready",
			event: { target: { kind: "direct", id: row.id }, notice: { kind: "ready" } },
		});
		assertEquals(line(), "introducing");
		row.access = "committed-route";
		f.apply();
		assertEquals(line(), "live");
		delete row.inbox;
		f.apply();
		assertEquals(line(), "introducing");
	} finally {
		f.close();
	}
});

for (const change of ["route", "registration", "opening", "local"] as const) {
	Deno.test(`direct presentation survives ${change} only for the same peer registration`, () => {
		const row = direct();
		assert(row.kind === "direct", "direct scenario");
		row.introduction = {
			access: "directory-access",
			name: "our-name",
			callback: "our-inbox",
			registration: "peer-registration",
			opening: "opening",
		};
		if (change !== "registration") row.inbox = "installed-callback";
		const f = fixture(row);
		try {
			const before = f.selected();
			store.setDmLine(f.page.projection, before.key, "live");
			store.deliver(f.page.projection, before.key, store.chatItem(f.page.projection, "bo", "same peer", false));
			row.access = "reciprocal-route";
			if (change === "registration") row.introduction.registration = "another-registration";
			if (change === "opening") row.introduction.opening = "new-opening";
			if (change === "local") row.introduction.name = "new-local-name";
			f.apply();
			const after = f.selected();
			assert(after.type === "dm", "direct scenario");
			assertEquals(after.key === before.key, change !== "registration");
			assertEquals(after.line, change !== "registration" ? "live" : "introducing");
			assertEquals(store.historyOf(f.page.projection, after.key).length, change !== "registration" ? 1 : 0);
		} finally {
			f.close();
		}
	});
}

Deno.test("committed direct reconnect reopens saved presentation only after route and callback adoption", () => {
	const row = direct();
	assert(row.kind === "direct", "direct scenario");
	row.introduction = {
		access: "directory-access",
		name: "our-name",
		callback: "our-inbox",
		registration: "peer-registration",
		opening: "old-opening",
	};
	row.closed = true;
	const f = fixture(row);
	try {
		const before = f.selected();
		assert(before.type === "dm", "direct projection");
		store.deliver(f.page.projection, before.key, store.chatItem(f.page.projection, "bo", "saved history", false));
		store.setDmLine(f.page.projection, before.key, "live");
		const notified = f.selected();
		assertEquals(
			notified.type === "dm" && notified.line,
			"closed",
			"notifications cannot reopen the saved row",
		);
		row.closed = false;
		row.source = "new-source";
		row.access = "new-route";
		row.inbox = undefined;
		row.introduction.opening = "new-opening";
		f.apply();
		const introducing = f.selected();
		assertEquals(introducing.type === "dm" && introducing.line, "introducing");
		row.inbox = "new-callback";
		f.apply();
		const after = f.selected();
		assert(after.type === "dm", "direct projection");
		assertEquals([after.key, after.line], [before.key, "live"]);
		assertEquals(store.historyOf(f.page.projection, after.key).length, 1);
	} finally {
		f.close();
	}
});
