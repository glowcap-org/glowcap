// A direct line is live only while the snapshot holds its route and its callback.
import { assert, assertEquals } from "../../assert.ts";
import * as store from "../../../web/ui/store.ts";
import { direct, fixture } from "./fixture.ts";

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
			event: { at: 0, target: { kind: "direct", id: row.id }, notice: { kind: "ready" } },
		}, false);
		assertEquals(line(), "introducing");
		// A line can arrive before the session holds the route to answer it.
		f.projection.activity({
			cursor: "line",
			event: {
				at: 0,
				target: { kind: "direct", id: row.id },
				notice: { kind: "line", from: "bo", text: "hello" },
			},
		}, false);
		assertEquals(line(), "introducing", "an arriving line does not open the composer");
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
		f.projection.activity({
			cursor: "line",
			event: {
				at: 0,
				target: { kind: "direct", id: row.id },
				notice: { kind: "line", from: "bo", text: "again" },
			},
		}, false);
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
		assertEquals(store.historyOf(f.page.projection, after.key).length, 2);
	} finally {
		f.close();
	}
});
