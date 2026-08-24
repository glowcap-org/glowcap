/**
 * What a segmented cell says it is.
 *
 * Each name in the class list is what a rule in controls.css matches on,
 * so dropping one changes how the cell is drawn without changing
 * anything a type checker can see. `ocv-btn` brings the box, the
 * surface and the focus ring from the control baseline; `is-segment`
 * joins the cell to its neighbours; `is-active` is chosen.
 */

import { assertEquals } from "@std/assert";
import { segmentCellClass } from "./tokens.ts";

Deno.test("a segmented cell is a button, joined into a row", () => {
	const classes = segmentCellClass(false).split(" ");
	assertEquals(classes.includes("ocv-btn"), true);
	assertEquals(classes.includes("is-segment"), true);
});

Deno.test("only the chosen cell carries the chosen class", () => {
	assertEquals(
		segmentCellClass(false).split(" ").includes("is-active"),
		false,
	);
	assertEquals(segmentCellClass(true).split(" ").includes("is-active"), true);
});

Deno.test("choosing a cell changes nothing else about it", () => {
	const unchosen = segmentCellClass(false).split(" ");
	const chosen = segmentCellClass(true).split(" ");
	assertEquals(chosen.filter((n) => n !== "is-active"), unchosen);
});
