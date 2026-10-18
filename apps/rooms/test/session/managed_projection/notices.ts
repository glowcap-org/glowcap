// Match activity/projection.rs and the browser reader's merged history field.
import { assert, assertEquals } from "../../assert.ts";
import { activityNotice } from "../../../web/ui/session/managed/model.ts";
import { ActivityDelivery } from "../../../web/ui/session/managed/activity.ts";
import * as store from "../../../web/ui/store.ts";
import { dirId } from "../../../web/ui/types.ts";
import { direct, fixture, room } from "./fixture.ts";

for (const conversation of [room, direct]) {
	for (const history of [null, { source: "recorder", generation: "membership", id: "1" }]) {
		Deno.test(`managed ${conversation().kind} renders live messages with ${history == null ? "no" : "recorded"} history`, () => {
			const row = conversation();
			const f = fixture(row);
			try {
				f.current.intent.keepHistory = history != null;
				f.projection.activity(new ActivityDelivery({
					cursor: "1",
					event: {
						target: { kind: row.kind, id: row.id },
						notice: {
							kind: "line",
							from: "bo",
							text: "live message",
							marker: { id: 1, change: "said" },
							metadata: null,
							previewUrls: [],
							history,
						},
					},
				}).take());
				const lines = store.historyOf(f.page.projection, f.selected().key).filter((item) =>
					item.kind === "chat"
				);
				assertEquals(lines.map((item) => item.text), ["live message"]);
				assertEquals(lines[0].history ?? null, history);
			} finally {
				f.close();
			}
		});
	}
}

for (const change of ["edited", "refiled", "withdrawn"] as const) {
	Deno.test(`managed sender ${change} accepts Rust's absent operation correlation`, () => {
		const row = direct();
		const f = fixture(row);
		const history = { source: "recorder", generation: "sender", id: "1" };
		const notice = {
			kind: "line",
			from: "ada",
			text: "original",
			marker: { id: 1, change: "said" },
			metadata: { operation: "post" },
			previewUrls: [],
			history,
		};
		const apply = (notice: unknown) =>
			f.projection.activity(new ActivityDelivery({
				cursor: "1",
				event: { target: { kind: "direct", id: row.id }, notice },
			}).take());
		try {
			apply(notice);
			const update = {
				...notice,
				text: change === "withdrawn" ? "" : "changed",
				marker: { id: 1, change },
				metadata: { operation: null },
			};
			assertEquals(activityNotice(update), update);
			apply(update);
			const lines = store.historyOf(f.page.projection, f.selected().key).filter((item) => item.kind === "chat");
			assertEquals(lines.length, 1);
			// Withdrawal hides the content while retaining the local history item.
			assertEquals(lines[0].text, change === "withdrawn" ? notice.text : update.text);
			assertEquals(lines[0].withdrawn === true, change === "withdrawn");
		} finally {
			f.close();
		}
	});
}

Deno.test("managed discovery applies the Rust snapshot's omitted count", () => {
	const f = fixture();
	const entry = {
		id: "publication",
		name: "garden",
		kind: "local",
		count: 1,
		origin: "",
		proof: "local",
		offers: "participant",
	};
	const peer = { name: "bo", registrationId: "00000000-0000-4000-8000-000000000001" };
	try {
		const notice = {
			kind: "discoverySnapshot",
			snapshot: { rooms: [entry], peers: [peer], omitted: 2 },
			history: null,
		};
		const parsed = activityNotice(notice);
		assert(parsed?.kind === "discoverySnapshot", "a Rust discovery snapshot must be admitted");
		assertEquals(parsed.snapshot, notice.snapshot);
		f.projection.activity(new ActivityDelivery({
			cursor: "1",
			event: { target: { kind: "discovery", id: "directory" }, notice },
		}).take());
		const directory = f.page.projection.get().dirs.get(dirId("directory"))!;
		assertEquals([...directory.liveRooms.values()], [entry]);
		assertEquals([...directory.dmablePeers.values()], [peer]);
		assertEquals(directory.session, "connected");
	} finally {
		f.close();
	}
});

for (
	const notice of [
		{ kind: "occupancy", listed: true, claimable: null },
		{ kind: "mintInboxFor", peer: "bo", registration: "registration", opening: null },
		{ kind: "directRequested", peer: "bo", registration: "registration", opening: null },
		{ kind: "introducible", peer: "bo", registration: "registration", opening: null },
	]
) {
	Deno.test(`managed ${notice.kind} accepts Rust's absent optional value`, () => {
		assertEquals(activityNotice(notice), notice);
	});
}

for (
	const notice of [
		{ kind: "line", history: { source: "recorder", generation: "membership", id: 1 } },
		{ kind: "line", metadata: { operation: 1 } },
		{ kind: "occupancy", listed: true, claimable: "yes" },
		{ kind: "introducible", opening: 1 },
		{ kind: "discoverySnapshot", snapshot: { rooms: [], peers: [], omitted: "2" } },
	]
) {
	Deno.test(`managed ${notice.kind} rejects a malformed projection field`, () => {
		assertEquals(activityNotice(notice), null);
	});
}

Deno.test("a restored room has not heard its policy until its directory answers", () => {
	const row = room();
	assert(row.kind === "room", "room fixture");
	const f = fixture(row);
	try {
		const restored = f.selected();
		assert(restored.type === "room", "room projection");
		// The private-room address waits on this rather than reading the open
		// default as the room's word.
		assertEquals(restored.policyHeard, false);
		assertEquals(restored.held, false);
		f.projection.activity({
			cursor: "1",
			gap: false,
			event: {
				target: { kind: "room", id: row.id },
				notice: { kind: "occupancy", listed: false, claimable: true },
			},
		});
		const answered = f.selected();
		assert(answered.type === "room", "room projection");
		assertEquals(answered.policyHeard, true);
		assertEquals(answered.held, true);
	} finally {
		f.close();
	}
});
