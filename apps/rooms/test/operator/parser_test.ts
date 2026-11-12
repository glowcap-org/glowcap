// Operator tuple adapters enforce bounded schemas and preserve complete pages through their wire round trip.
import { parseDiagnosticRows } from "../../lib/diagnostics.ts";
import { parseListenerRows } from "../../lib/listeners.ts";
import { type OperatorPage, operatorPageAnswer, parseOperatorPageAnswer } from "../../lib/operator.ts";
import { assertEquals } from "../assert.ts";

function refusal(work: () => unknown): string {
	try {
		work();
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

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
		refusal(() => parseOperatorPageAnswer("registrations", [1n, null, [[oversized, "session", false]], 1n])),
		"the Rooms operator answered an out-of-bounds inventory row",
	);
	assertEquals(
		refusal(() =>
			parseOperatorPageAnswer("rooms", [
				1n,
				null,
				[["room-id", "local", "general", "", "local", 0n, [[oversized, "session", ""]], false]],
				1n,
			])
		),
		"the Rooms operator answered an invalid room page",
	);
	assertEquals(refused(() => parseDiagnosticRows([["room", oversized, "live"]])), true);
	assertEquals(refused(() => parseDiagnosticRows([["room", "general", "live", "surplus"]])), true);
});

Deno.test("a malformed operator page names the page it refuses", () => {
	const page = (category: Parameters<typeof parseOperatorPageAnswer>[0], rows: unknown) =>
		refusal(() => parseOperatorPageAnswer(category, [1n, null, rows, 1n]));
	assertEquals(
		page("references", [["id", "line", "owner", "room", "member", 7]]),
		"the Rooms operator answered an invalid reference page",
	);
	assertEquals(page("trouble", [["source", "reason", 0n]]), "the Rooms operator answered an invalid trouble page");
	assertEquals(
		page("rooms", [["room-id", "local", "general", "", "local", null, [["nick", 1, "here"]], false]]),
		"the Rooms operator answered an invalid room page",
	);
	assertEquals(
		page("sessions", [["id", "tcp", "nick", "yes"]]),
		"the Rooms operator answered an invalid inventory row",
	);
	assertEquals(page("links", [["name", 3, "listed"]]), "the Rooms operator answered an invalid inventory row");
	assertEquals(page("trouble", "rows"), "the Rooms operator answered an invalid category page");
	assertEquals(
		refusal(() => parseOperatorPageAnswer("links", [1n, null, []])),
		"the Rooms operator answered an invalid snapshot page",
	);
});

Deno.test("an operator page survives the answer-and-parse round trip", () => {
	// The encoder and the parser are the two directions of one wire form, and
	// a durable session facet re-encodes what it parsed, so a field one side
	// carries and the other drops breaks every attached view. The caller mark
	// is the field that once went missing on the answering side.
	const pages: OperatorPage[] = [
		{
			category: "registrations",
			revision: 7n,
			next: 32,
			total: 40,
			rows: [
				{ nick: "alice", sessionId: "one", you: false },
				{ nick: "jim", sessionId: "two", you: true },
			],
		},
		{
			category: "sessions",
			revision: 7n,
			next: null,
			total: 2,
			rows: [
				{ id: "one", transport: "iroh", nick: "alice", you: false },
				{ id: "two", transport: "iroh", nick: "jim", you: true },
			],
		},
	];
	for (const page of pages) {
		const back = parseOperatorPageAnswer(page.category, operatorPageAnswer(page));
		// Piecewise, because the shared assert stringifies and a revision is a
		// bigint JSON will not carry.
		assertEquals(back.revision === page.revision, true);
		assertEquals(back.next, page.next);
		assertEquals(back.total, page.total);
		assertEquals(back.rows, page.rows);
	}
});

Deno.test("listener tuple adapters enforce exact and consistent rows", () => {
	const row = ["tcp", "TCP", "", "", [], "", 0n, "", false];
	assertEquals(parseListenerRows([row])[0]?.id, null);
	assertEquals(refused(() => parseListenerRows([[...row, "surplus"]])), true);
	assertEquals(
		refused(() =>
			parseListenerRows([["tcp", "TCP", "", "", [["bind", "host", "hint", "surplus"]], "", 0n, "", false]])
		),
		true,
	);
	assertEquals(refused(() => parseListenerRows([["tcp", "TCP", "", "", [], "", 0n, "tcp://live", false]])), true);
});
