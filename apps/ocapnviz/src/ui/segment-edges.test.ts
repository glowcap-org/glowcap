/**
 * The chosen segmented cell owns its own mark.
 *
 * The rule: a chosen cell's accent box is never affected by a neighbour, in any
 * state a neighbour can be in. Every segmented control comes through
 * `segmentCellClass`, so this holds for the mode switch, the timeline's lane
 * toggles, the payload viewer's view modes, the Reference's section picker, and
 * the stage's zoom controls at once — the last of which never has a chosen cell
 * and is here for the row rather than the mark.
 *
 * Why it is worth a test rather than a comment: the defect was invisible to
 * every other check. Cells drop their right border so two neighbours share one
 * line, and the chosen cell's right edge was therefore drawn by the cell after
 * it. That is fine until the neighbour is disabled — `:disabled` fades a control
 * to 40% and fades every part of it, including a border it was drawing on
 * somebody else's behalf — and then the chosen cell reads as cut open on one
 * side. Nothing about it is a stacking-order problem, so the block that exists
 * for paint order could not have fixed it: the pale line is not painted over the
 * mark, it IS the mark, drawn by a faded element.
 *
 * Validated by injection: putting the sibling-drawn edge back fails
 * "no rule hands a neighbour the accent edge", and dropping the chosen cell's
 * own border fails "the chosen cell declares its own right edge".
 */

import { assert, assertEquals } from "@std/assert";
import { segmentCellClass } from "./tokens.ts";

const CSS = await Deno.readTextFile(
	new URL("../controls.css", import.meta.url),
);

/**
 * The declarations of the rule whose selector list is exactly `selector`.
 *
 * Exactly, and that word is load-bearing. `.ocv-input.is-segment` is both a rule
 * of its own and the second line of another rule's selector list, so searching
 * for the text finds whichever comes first in the file — which is how the first
 * version of this read the shared rule's body and reported the field's own border
 * missing when it was there. Comparing the whole list tells the two apart.
 *
 * Whitespace-insensitive, so a caller may write a multi-line selector list the
 * way the stylesheet does.
 */
function ruleBody(selector: string): string | null {
	const want = selector.replace(/\s+/g, " ").trim();
	for (const block of CSS.split("}")) {
		const open = block.indexOf("{");
		if (open === -1) continue;
		const head = block.slice(0, open);
		// A rule is usually preceded by its comment; the list is whatever follows the
		// comment's end, or the whole head when there is no comment.
		const commentEnd = head.lastIndexOf("*/");
		const list = (commentEnd === -1 ? head : head.slice(commentEnd + 2))
			.replace(/\s+/g, " ")
			.trim();
		if (list === want) return block.slice(open + 1);
	}
	return null;
}

Deno.test("the chosen cell declares its own right edge", () => {
	// The side the sharing rule left to a neighbour, and so the only side that
	// could be taken away by one.
	const body = ruleBody(".ocv-btn.is-segment.is-active");
	assert(
		body !== null,
		"no rule styles a chosen segmented cell, so nothing here is being checked",
	);
	assert(
		/border-right:\s*1px\s+solid\s+var\(--ocv-accent\)/.test(body),
		`a chosen cell should draw its own accent right border; it declares: ${body.trim()}`,
	);
});

Deno.test("the cell after a chosen one contributes no edge", () => {
	// The other half of the same line: ownership moved rather than doubled, so
	// the row stays exactly as wide as it was.
	const body = ruleBody(
		".ocv-btn.is-segment.is-active + .ocv-btn.is-segment",
	);
	assert(
		body !== null,
		"the sibling rule is missing, so the edge is drawn twice",
	);
	assert(
		/border-left:\s*0/.test(body),
		`the cell after a chosen one should drop its left border; it declares: ${body.trim()}`,
	);
});

Deno.test("a field in a row draws its own right edge", () => {
	// The same ownership question at the other control family, and the answer has
	// to be the other way round. `.ocv-input:focus` lights the borders a field
	// OWNS, so a field that shared the button's way — dropping the right border and
	// letting the next cell draw it — lit three edges accent and left the fourth
	// grey. An accent box open on one side reads as a missing border.
	const body = ruleBody(".ocv-input.is-segment");
	assert(
		body !== null,
		"no rule styles a segmented field, so nothing here is being checked",
	);
	// The selector this asked for carries no `:focus`, which is the other half of
	// the claim: the edge is the field's in every state. A rule that only fired
	// while focused would hand the seam back and forth every time the reader looks
	// from the picture to the number, and each handover steps the line a pixel
	// sideways.
	assert(
		/border-right:\s*1px\s+solid\s+var\(--ocv-border\)/.test(body),
		`a segmented field should draw its own right border; it declares: ${body.trim()}`,
	);
});

Deno.test("the cell after a segmented field contributes no edge", () => {
	const body = ruleBody(
		".ocv-input.is-segment + .ocv-btn.is-segment,\n.ocv-input.is-segment + .ocv-input.is-segment",
	);
	assert(
		body !== null,
		"the sibling rule is missing, so the seam beside a field is drawn twice",
	);
	assert(
		/border-left:\s*0/.test(body),
		`the cell after a field should drop its left border; it declares: ${body.trim()}`,
	);
});

Deno.test("no rule hands a neighbour the accent edge", () => {
	// Stated as the class rather than as the one selector that did it: any rule
	// that reaches a sibling with `+` and paints the accent on it is a cell
	// drawing somebody else's mark, and inherits whatever state that sibling is
	// in.
	const offenders: string[] = [];
	for (const block of CSS.split("}")) {
		const open = block.indexOf("{");
		if (open === -1) continue;
		const selector = block.slice(0, open);
		const body = block.slice(open + 1);
		if (!selector.includes("+")) continue;
		if (/border-[a-z]*-?color:\s*var\(--ocv-accent\)/.test(body)) {
			offenders.push(selector.trim().replace(/\s+/g, " "));
		}
	}
	assertEquals(
		offenders,
		[],
		"these rules paint a chosen cell's accent onto a sibling, so the sibling's " +
			"own state decides how the mark looks",
	);
});

Deno.test("every segmented control comes through one class list", () => {
	// The reason one CSS fix covers all three controls. If a surface ever builds
	// its own class list, the rule above stops being about it.
	assertEquals(segmentCellClass(true), "ocv-btn is-segment is-active");
	assertEquals(segmentCellClass(false), "ocv-btn is-segment");
});
