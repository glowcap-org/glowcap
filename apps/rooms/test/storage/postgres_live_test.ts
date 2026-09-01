// The PostgreSQL backend against a real database, whenever one is offered.
//
// The hermetic suites hold the walk to RFC 7677's vector and to a scripted
// fixture that speaks the same wire grammar as production — which proves
// pancake agrees with pancake, and nothing more. This suite is the other
// half: point PANCAKE_ROOMS_STORAGE_LIVE_URL at a disposable database and
// the full round trip runs against PostgreSQL's own word. Without the
// variable it reports itself ignored, so its absence in a green run is
// visible rather than silent.

import { PgHistoryBackend } from "../../server/storage/postgres.ts";
import { HistoryIndex } from "../../server/history_index.ts";
import { optionalEnv } from "../../lib/env.ts";
import { assertEquals } from "../assert.ts";

const url = optionalEnv("PANCAKE_ROOMS_STORAGE_LIVE_URL");

Deno.test({
	name: "a live database carries append, restore, rewrite, and a reopened backend",
	ignore: url === undefined,
	fn: async () => {
		const room = `live-proof-${Date.now()}`;
		const backend = await PgHistoryBackend.open(url!);
		try {
			await backend.append(room, { from: "alice", text: "first", at: 1000 }, null);
			await backend.append(room, { from: "bob", text: "second", at: 2000 }, null);
			const restored = new HistoryIndex();
			await backend.restore(restored);
			const kept = restored.read(room, 500);
			assertEquals(kept.map((line) => line.text), ["first", "second"]);
			assertEquals(kept[0].from, "alice");
			assertEquals(kept[1].at, 2000);

			await backend.replace(room, [{ from: "alice", text: "first, edited", at: 1000 }]);
			const edited = new HistoryIndex();
			await backend.restore(edited);
			assertEquals(edited.read(room, 500).map((line) => line.text), ["first, edited"]);

			// A fresh backend on the same database is the restart story.
			const reopened = await PgHistoryBackend.open(url!);
			try {
				const afterRestart = new HistoryIndex();
				await reopened.restore(afterRestart);
				assertEquals(afterRestart.read(room, 500).map((line) => line.text), ["first, edited"]);
			} finally {
				reopened.close();
			}
		} finally {
			// Leave the database as found: the room's rows go with the test.
			await backend.replace(room, []).catch(() => {});
			backend.close();
		}
	},
});
