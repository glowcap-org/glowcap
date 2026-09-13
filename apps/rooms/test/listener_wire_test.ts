// Native peers return protocol integers; UI identifiers must stay exact.
import { parseListenerRows } from "../lib/listeners.ts";
import { assertEquals } from "./assert.ts";

function snapshot(id: unknown, locator = "127.0.0.1:9000") {
	return [["tcp", "Plain TCP", "", "", [], "", id, locator, locator !== ""]];
}

Deno.test("listener IDs preserve exact native integers", () => {
	for (const id of [1n, BigInt(Number.MAX_SAFE_INTEGER)]) {
		assertEquals(parseListenerRows(snapshot(id))[0].id, Number(id));
	}
	assertEquals(parseListenerRows(snapshot(0n, ""))[0].id, null);
});

Deno.test("listener snapshots refuse lossy IDs and inconsistent live state", () => {
	for (
		const raw of [
			...[-1n, 9007199254740992n, 9007199254740993n, 0, 1, Infinity, 1.5, "1", true, null]
				.map((id) => snapshot(id)),
			snapshot(0n),
			snapshot(1n, ""),
		]
	) {
		let refused = false;
		try {
			parseListenerRows(raw);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
	}
});
