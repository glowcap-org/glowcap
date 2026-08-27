import { parseDiagnosticRows } from "../lib/diagnostics.ts";
import { parseListenerRows } from "../lib/listeners.ts";
import { parseOperatorPageAnswer } from "../lib/operator.ts";
import { assertEquals } from "./assert.ts";

function refused(work: () => unknown): boolean {
	try {
		work();
		return false;
	} catch {
		return true;
	}
}

Deno.test("operator and diagnostic tuple adapters enforce their bounded row schemas", () => {
	const oversized = "x".repeat(64 * 1024 + 1);
	assertEquals(
		refused(() => parseOperatorPageAnswer("registrations", [1n, null, [[oversized, "session"]]])),
		true,
	);
	assertEquals(
		refused(() =>
			parseOperatorPageAnswer("rooms", [
				1n,
				null,
				[["room-id", "local", "general", "", "local", 0n, [[oversized, "session", ""]], false]],
			])
		),
		true,
	);
	assertEquals(refused(() => parseDiagnosticRows([["room", oversized, "live"]])), true);
	assertEquals(refused(() => parseDiagnosticRows([["room", "general", "live", "surplus"]])), true);
});

Deno.test("listener tuple adapters enforce exact and consistent rows", () => {
	const row = ["tcp", "TCP", "", "", [], "", 0, "", false];
	assertEquals(parseListenerRows([row])[0]?.id, null);
	assertEquals(refused(() => parseListenerRows([[...row, "surplus"]])), true);
	assertEquals(
		refused(() =>
			parseListenerRows([["tcp", "TCP", "", "", [["bind", "host", "hint", "surplus"]], "", 0, "", false]])
		),
		true,
	);
	assertEquals(refused(() => parseListenerRows([["tcp", "TCP", "", "", [], "", 0, "tcp://live", false]])), true);
});
