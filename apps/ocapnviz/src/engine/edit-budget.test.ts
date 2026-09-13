/** Bulk editing must pay for one layout pass per gesture, independent of how
 * many members the user selects. The corpus is the document that exposed the
 * original cost, parsed through the same document schema as the file picker. */
import { assertEquals } from "@std/assert";
import { Engine } from "./engine.ts";
import { TimelineDocument } from "./timeline.ts";

const source = JSON.parse(
	await Deno.readTextFile(new URL("../../test-data/the-kids-masterpiece.json", import.meta.url)),
);

Deno.test("masterpiece bulk move and unpin each pay for one layout pass", () => {
	const engine = new Engine(TimelineDocument.parse(source));
	let placements = 0;
	let recomputes = 0;
	const placement = engine.layout.recomputeForPlacement.bind(engine.layout);
	const recompute = engine.layout.recompute.bind(engine.layout);
	engine.layout.recomputeForPlacement = () => {
		placements += 1;
		placement();
	};
	engine.layout.recompute = () => {
		recomputes += 1;
		recompute();
	};
	const peers = Object.keys(engine.doc.entities?.peers ?? {});
	assertEquals(peers.length, 31, "the complete reporting corpus is loaded");
	engine.beginTransaction("Move all");
	engine.repositionNodes(peers.map((id, index) => ({ kind: "peer", id, position: { x: index * 10, y: 0 } })));
	engine.endTransaction();
	assertEquals(placements, 1);
	assertEquals(recomputes, 0);

	engine.beginTransaction("Unpin all");
	for (const id of peers) engine.clearPeerPosition(id);
	assertEquals(recomputes, 0, "unpin defers layout until the transaction closes");
	engine.endTransaction();
	assertEquals(recomputes, 1, "one full layout serves all unpinned peers");
});
