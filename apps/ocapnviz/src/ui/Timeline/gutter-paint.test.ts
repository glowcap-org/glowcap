/**
 * The gutter's right edge.
 *
 * The row-label column ends at a divider the reader can drag, and the
 * plot's spans start on the other side of it. A label that measures short
 * lands ink over those spans, so what is asserted here is the arithmetic
 * that decides how much of a name is drawn.
 *
 * Two halves, and each was run against the defect it claims. Shrinking
 * the budget by dropping the right pad is caught by the width assertion.
 * Measuring a character at 5.4 px instead of 6, which is the defect that
 * put ink over the spans, is caught only by the advance assertion, the
 * width assertion measures with whatever number the code believes, so it
 * proves the arithmetic and never the number. Nothing here draws, so the
 * number itself came from a browser measuring the loaded face.
 */

import { assert, assertEquals } from "@std/assert";
import {
	eyeGlyphStatus,
	GUTTER_LABEL_RIGHT_PAD_PX,
	gutterLabelText,
	HEADER_EYEBALL_X,
	ROW_LABEL_X,
} from "./gutter-paint.ts";
import { monoAdvance } from "./label-layout.ts";
import { GUTTER_MAX_PX, GUTTER_MIN_PX } from "./state.ts";
import { SIZE } from "../tokens.ts";
import { intentLabel } from "../../engine/intent-labels.ts";

/** A name long enough that no gutter width can hold all of it. */
const LONG = "3c3c3c3c…3c3c3c3c · 3c3c3c3c…3c3c3c3c";

Deno.test("one character of the timeline's mono face is six pixels", () => {
	// Measured in a browser against the loaded face, not derived: Departure
	// Mono is drawn on a pixel grid, so its advance lands on a whole pixel
	// and 9 px of type is 6 px of character. The ratio alone would say
	// 5.625, and a row label ten characters long would then be measured
	// four pixels narrower than it draws.
	assertEquals(monoAdvance(SIZE.xs), 6);
});

Deno.test("eyeball hover status uses the same verbs as intent labels", () => {
	// The gutter comment claims a tooltip; the verbs must stay locked to
	// undo copy so the eye does not invent a second vocabulary.
	for (
		const mode of ["visible", "label", "body", "both"] as const
	) {
		assertEquals(
			eyeGlyphStatus(mode, { kind: "row" }),
			intentLabel({
				kind: "set-row-vis-mode",
				category: "peers",
				id: "x",
				mode,
			}),
		);
		assertEquals(
			eyeGlyphStatus(mode, { kind: "category", category: "sessions" }),
			intentLabel({
				kind: "set-category-vis-mode",
				category: "sessions",
				mode,
			}),
		);
		assertEquals(
			eyeGlyphStatus(mode, { kind: "all" }),
			intentLabel({ kind: "set-all-vis-mode", mode }),
		);
	}
});

Deno.test("a label stops inside the gutter at every width it can have", () => {
	for (let width = GUTTER_MIN_PX; width <= GUTTER_MAX_PX; width += 1) {
		for (const labelX of [HEADER_EYEBALL_X + 8, ROW_LABEL_X]) {
			const text = gutterLabelText(LONG, labelX, width);
			const right = labelX + text.length * monoAdvance(SIZE.xs);
			assert(
				right <= width - GUTTER_LABEL_RIGHT_PAD_PX,
				`at ${width}px the label reached ${right}px: ${text}`,
			);
		}
	}
});

Deno.test("a label that fits is left whole, and a longer one ends in an ellipsis", () => {
	assertEquals(
		gutterLabelText("sessions", HEADER_EYEBALL_X + 8, 320),
		"sessions",
	);
	const cut = gutterLabelText(LONG, ROW_LABEL_X, GUTTER_MIN_PX);
	assert(cut.endsWith("…"), `expected an ellipsis, got ${cut}`);
	assert(
		cut.length > 1,
		"the narrowest gutter still carries a few characters",
	);
});
