import { assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { DOC_INDEX_EDGES, docIndexesForTarget } from "./doc-index.ts";

function emptyDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "doc-1",
		duration: 100,
		events: [],
	});
}

Deno.test("DOC_INDEX_EDGES covers all 12 (field × category) slots", () => {
	// 4 fields (rowOrder + 3 rowHidden variants) × 3 categories.
	assertEquals(DOC_INDEX_EDGES.length, 12);
});

Deno.test("docIndexesForTarget('peer') returns 4 edges", () => {
	const edges = docIndexesForTarget("peer");
	assertEquals(edges.length, 4);
	const names = edges.map((e) => e.pathName).sort();
	assertEquals(names, [
		"rowBodyHidden.peers",
		"rowHidden.peers",
		"rowLabelHidden.peers",
		"rowOrder.peers",
	]);
});

Deno.test("DocIndexEdge.read returns the list when present", () => {
	const doc: TimelineDocument = {
		...emptyDoc(),
		rowOrder: { peers: ["p1", "p2"] },
	};
	const edge = DOC_INDEX_EDGES.find((e) => e.pathName === "rowOrder.peers")!;
	assertEquals(edge.read(doc), ["p1", "p2"]);
});

Deno.test("DocIndexEdge.read returns undefined when absent", () => {
	const doc = emptyDoc();
	const edge = DOC_INDEX_EDGES.find((e) => e.pathName === "rowOrder.peers")!;
	assertEquals(edge.read(doc), undefined);
});

Deno.test("DocIndexEdge.replace with a new list produces an updated doc", () => {
	const doc: TimelineDocument = {
		...emptyDoc(),
		rowOrder: { peers: ["p1"] },
	};
	const edge = DOC_INDEX_EDGES.find((e) => e.pathName === "rowOrder.peers")!;
	const next = edge.replace(doc, ["p2", "p3"]);
	assertEquals(next.rowOrder?.peers, ["p2", "p3"]);
});

Deno.test("DocIndexEdge.replace with undefined removes the field", () => {
	const doc: TimelineDocument = {
		...emptyDoc(),
		rowOrder: { peers: ["p1"] },
	};
	const edge = DOC_INDEX_EDGES.find((e) => e.pathName === "rowOrder.peers")!;
	const next = edge.replace(doc, undefined);
	// No other category is set, so the whole rowOrder field should be gone.
	assertEquals(next.rowOrder, undefined);
});

Deno.test(
	"DocIndexEdge.replace preserves sibling categories",
	() => {
		const doc: TimelineDocument = {
			...emptyDoc(),
			rowOrder: { peers: ["p1"], sessions: ["s1"] },
		};
		const edge = DOC_INDEX_EDGES.find((e) => e.pathName === "rowOrder.peers")!;
		const next = edge.replace(doc, undefined);
		assertEquals(next.rowOrder?.peers, undefined);
		assertEquals(next.rowOrder?.sessions, ["s1"]);
	},
);
