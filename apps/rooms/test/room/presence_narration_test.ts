// Churn summaries change narration without changing roster authority.
import { assertEquals } from "../assert.ts";
import { PresenceNarration } from "../../web/ui/session/presence_narration.ts";
Deno.test("flapping updates one bounded-window notice, explicit leave remains visible", () => {
	const narration = new PresenceNarration();
	const rows: string[] = [];
	const append = (text: string) => {
		rows.push(text);
		return rows.length - 1;
	};
	const update = (id: number, text: string) => {
		rows[id] = text;
		return true;
	};
	narration.present("room", { kind: "join", name: "Ada" }, "Ada joined", 0, append, update);
	narration.present("room", { kind: "offline", names: ["Ada"] }, "Ada offline", 1000, append, update);
	narration.present("room", { kind: "join", name: "Ada" }, "Ada joined", 2000, append, update);
	assertEquals(rows, ["Ada’s connection changed 3 times. Now online."]);
	narration.present("room", { kind: "leave", name: "Ada" }, "Ada left", 2500, append, update);
	narration.present("room", { kind: "join", name: "Ada" }, "Ada joined", 3000, append, update);
	assertEquals(rows.length, 3);
	narration.present("room", { kind: "offline", names: ["Ada"] }, "Ada offline", 9000, append, update);
	narration.present("other", { kind: "join", name: "Ada" }, "Ada joined other", 9100, append, update);
	assertEquals(rows.length, 5);
});
