// A page that attaches to a session with history reads what already happened.
// It learns the outcome and draws nothing that was only true at the time.
import { assertEquals } from "../../assert.ts";
import type { ActivityPage } from "../../../web/ui/session/managed/model.ts";
import type { Presence } from "../../../lib/room/presence.ts";
import { ROOM_SENDER } from "../../../lib/protocol_data.ts";
import * as store from "../../../web/ui/store.ts";
import { direct, fixture, room } from "./fixture.ts";

function presence(at: number, text: string, change: Presence): ActivityPage {
	return {
		cursor: String(at),
		event: {
			at,
			target: { kind: "room", id: room().id },
			notice: { kind: "line", from: ROOM_SENDER, text, metadata: { presence: change } },
		},
	};
}
function narrated(f: ReturnType<typeof fixture>): [string, number][] {
	return store.historyOf(f.page.projection, f.selected().key).filter((item) => item.kind === "sys").map((
		item,
	) => [item.text, item.at]);
}

Deno.test("a roster read while catching up is published once, as the room stands", () => {
	const f = fixture();
	try {
		const roster = () => [...store.membersOf(f.page.projection, f.selected().key)];
		f.projection.activity(presence(0, "bo joined", { kind: "join", name: "bo" }), true);
		f.projection.activity(presence(1, "cy joined", { kind: "join", name: "cy" }), true);
		f.projection.activity(presence(2, "bo left", { kind: "leave", name: "bo" }), true);
		assertEquals(roster(), [], "a room as it once stood is never drawn");
		f.projection.activity({ cursor: "2" }, false);
		assertEquals(roster(), [["cy", { online: true, away: "" }]]);
		f.projection.activity(presence(3, "bo joined", { kind: "join", name: "bo" }), false);
		assertEquals(roster().map(([name]) => name), ["cy", "bo"], "a live change is drawn as it arrives");
	} finally {
		f.close();
	}
});

Deno.test("a membership that ended while catching up publishes no roster", () => {
	const f = fixture();
	try {
		const key = f.selected().key;
		f.projection.activity(presence(0, "bo joined", { kind: "join", name: "bo" }), true);
		f.projection.activity(
			{ cursor: "1", event: { at: 1, target: { kind: "room", id: room().id }, notice: { kind: "ended" } } },
			true,
		);
		f.projection.activity({ cursor: "1" }, false);
		assertEquals([...store.membersOf(f.page.projection, key)], []);
	} finally {
		f.close();
	}
});

Deno.test("a conversation closed while catching up publishes no roster", () => {
	const f = fixture();
	try {
		const key = f.selected().key;
		f.projection.activity(presence(0, "bo joined", { kind: "join", name: "bo" }), true);
		store.forgetConv(f.page.projection, key);
		f.projection.activity({ cursor: "0" }, false);
		assertEquals(f.page.projection.get().members.has(key), false);
	} finally {
		f.close();
	}
});

Deno.test("someone who was typing when it happened is not typing now", () => {
	for (const conversation of [room, direct]) {
		const row = conversation();
		const f = fixture(row);
		try {
			const typing = (at: number): ActivityPage => ({
				cursor: String(at),
				event: {
					at,
					target: { kind: row.kind, id: row.id },
					notice: row.kind === "room"
						? {
							kind: "line",
							from: ROOM_SENDER,
							metadata: { presence: { kind: "typing", name: "bo", on: true } },
						}
						: { kind: "typing", on: true },
				},
			});
			const typers = () => [...f.page.projection.get().typers.get(f.selected().key) ?? []].length;
			f.projection.activity(typing(0), true);
			assertEquals(typers(), 0, row.kind);
			f.projection.activity(typing(1), false);
			assertEquals(typers(), 1, row.kind);
		} finally {
			for (const timer of f.page.typing.timers.values()) clearTimeout(timer);
			f.close();
		}
	}
});

Deno.test("a line and its presence narration carry the time the session accepted them", () => {
	const f = fixture();
	try {
		// Three changes ten seconds apart were three notices to whoever read them
		// live. Reading them back to back must not fold them into churn.
		f.projection.activity(presence(1_000, "bo joined", { kind: "join", name: "bo" }), true);
		f.projection.activity(presence(11_000, "bo went offline", { kind: "offline", names: ["bo"] }), true);
		f.projection.activity(presence(21_000, "bo joined", { kind: "join", name: "bo" }), true);
		assertEquals(narrated(f), [["bo joined", 1_000], ["bo went offline", 11_000], ["bo joined", 21_000]]);
		// Changes inside one window still fold, by the same clock.
		f.projection.activity(presence(22_000, "bo went offline", { kind: "offline", names: ["bo"] }), true);
		assertEquals(narrated(f).length, 3);
		f.projection.activity({
			cursor: "line",
			event: {
				at: 30_000,
				target: { kind: "room", id: room().id },
				notice: { kind: "line", from: "bo", text: "back", marker: { id: 1, change: "said" } },
			},
		}, true);
		const said = store.historyOf(f.page.projection, f.selected().key).filter((item) => item.kind === "chat");
		assertEquals(said.map((item) => [item.text, item.at]), [["back", 30_000]]);
	} finally {
		f.close();
	}
});
