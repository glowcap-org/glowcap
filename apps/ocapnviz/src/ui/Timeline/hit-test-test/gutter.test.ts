/**
 * `hitTestGutter`, chevron, eyeball, category-eyeball, and row-drag
 * in the lane-label column. These cases construct row descriptors
 * directly. They do not need the plot-area fixture.
 */

import { assertEquals } from "@std/assert";
import { hitTestGutter } from "../hit-test.ts";
import type { RowDescriptor } from "../row-layout.ts";

Deno.test("hitTestGutter: chevron click on a collapsed category header", () => {
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
	];
	// px=8 (HEADER_CHEVRON_X), py=15 (mid-row).
	const hit = hitTestGutter(8, 15, rows);
	assertEquals(hit?.kind, "chevron");
	if (hit?.kind === "chevron") assertEquals(hit.category, "peers");
});

Deno.test("hitTestGutter: eyeball click on per-entity row", () => {
	const rows: RowDescriptor[] = [
		{
			kind: "entity-row",
			category: "peers",
			entityId: "alice",
			y: 0,
			height: 30,
			hidden: false,
		},
	];
	// px=24, py=15, inside the per-entity eyeball hit zone
	// [ROW_EYEBALL_X - 8, ROW_EYEBALL_X + 8) where ROW_EYEBALL_X
	// is HEADER_EYEBALL_X + ROW_INDENT_PX (24 + 6 = 30). The
	// 16-px hit zone still covers 24, so the test point survived
	// the indent. Per-entity rows nest under the category header
	// visually; hit-test stays generous so a 6 px shift doesn't
	// make the click target awkward.
	const hit = hitTestGutter(24, 15, rows);
	assertEquals(hit?.kind, "eyeball");
	if (hit?.kind === "eyeball") {
		assertEquals(hit.category, "peers");
		assertEquals(hit.entityId, "alice");
	}
});

Deno.test("hitTestGutter: category-eyeball click on header row", () => {
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
	];
	// px=24 (HEADER_EYEBALL_X), py=15, inside the category-eyeball
	// hit zone, so wins over the rest of the header's chevron toggle.
	const hit = hitTestGutter(24, 15, rows);
	assertEquals(hit?.kind, "category-eyeball");
	if (hit?.kind === "category-eyeball") {
		assertEquals(hit.category, "peers");
	}
});

Deno.test(
	"hitTestGutter: chevron click outside category-eyeball still toggles",
	() => {
		const rows: RowDescriptor[] = [
			{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
		];
		// px=50 (well past HEADER_EYEBALL_X + 8 = 32), header
		// chevron branch.
		const hit = hitTestGutter(50, 15, rows);
		assertEquals(hit?.kind, "chevron");
	},
);

Deno.test("hitTestGutter: row-drag handle on entity-row label area", () => {
	const rows: RowDescriptor[] = [
		{
			kind: "entity-row",
			category: "peers",
			entityId: "alice",
			y: 0,
			height: 30,
			hidden: false,
		},
	];
	// px=40 (in label area, right of eyeball hit-zone), py=15.
	const hit = hitTestGutter(40, 15, rows);
	assertEquals(hit?.kind, "row-drag");
});

Deno.test("hitTestGutter: hidden-on-stage rows keep drag + eyeball", () => {
	// Now that the eyeball gates STAGE rendering instead of timeline
	// geometry, the row stays at full height and stays fully
	// interactive, reorder + tap-to-select work whether or not the
	// entity is currently hidden on the stage.
	const rows: RowDescriptor[] = [
		{
			kind: "entity-row",
			category: "peers",
			entityId: "alice",
			y: 0,
			height: 30,
			hidden: true,
		},
	];
	const hitDrag = hitTestGutter(40, 15, rows);
	assertEquals(hitDrag?.kind, "row-drag");
	const hitEye = hitTestGutter(24, 15, rows);
	assertEquals(hitEye?.kind, "eyeball");
});

Deno.test("hitTestGutter: clicks outside the gutter return null", () => {
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
	];
	// px=120 is past LANE_LABEL_WIDTH (104) → not the gutter.
	const hit = hitTestGutter(120, 15, rows);
	assertEquals(hit, null);
});
