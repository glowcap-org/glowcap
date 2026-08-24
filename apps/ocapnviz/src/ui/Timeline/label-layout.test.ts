/**
 * Lane-label layout: sticky-header packing and truncation.
 *
 * `layoutLaneLabels` decides which labels survive a dense cluster and
 * where they paint.
 */

import { assertEquals } from "@std/assert";
import {
	LABEL_GAP_PX,
	LABEL_MIN_PX,
	type LaneLabelInput,
	layoutLaneLabels,
	monoAdvance,
	truncateToWidth,
} from "./label-layout.ts";

// Same advance the Scrubber renders at (mono font, SIZE.xs = 9 px).
const ADVANCE = monoAdvance(9);

function input(
	partial: Pick<LaneLabelInput, "id" | "startT" | "label" | "pillLeft"> & {
		pillRight?: number;
	},
): LaneLabelInput {
	return {
		id: partial.id,
		startT: partial.startT,
		label: partial.label,
		pillLeft: partial.pillLeft,
		// Default the pill to "wide enough not to clip"; tests that
		// care about per-pill bounds set this explicitly.
		pillRight: partial.pillRight ?? partial.pillLeft + 5000,
	};
}

Deno.test("layoutLaneLabels: single label fits at natural position", () => {
	const placed = layoutLaneLabels(
		[input({ id: "a", startT: 0, label: "hello", pillLeft: 100 })],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 1);
	assertEquals(placed[0]!.id, "a");
	assertEquals(placed[0]!.label, "hello");
	// pillLeft (100) + LABEL_INSET_PX (5) = 105
	assertEquals(placed[0]!.x, 105);
});

Deno.test("layoutLaneLabels: non-overlapping labels both at natural", () => {
	// Two labels far apart in time → both fit at their pill anchors.
	const placed = layoutLaneLabels(
		[
			input({ id: "a", startT: 0, label: "alpha", pillLeft: 100 }),
			input({ id: "b", startT: 1000, label: "beta", pillLeft: 500 }),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 2);
	assertEquals(placed[0]!.x, 105);
	assertEquals(placed[1]!.x, 505);
	assertEquals(placed[0]!.label, "alpha");
	assertEquals(placed[1]!.label, "beta");
});

Deno.test("layoutLaneLabels: later wins, earlier shifts left to keep full label", () => {
	// Earlier label "hello" (5 chars) at pillLeft=100. Natural [105, 105+5*ADVANCE].
	// Later label "x" at pillLeft=120 (1 char). Natural [125, 125+ADVANCE].
	// Earlier's natural right (~132) overlaps later's natural left (125).
	// Later wins → placed at 125. Earlier's rightLimit = 125 - GAP = 121.
	// Earlier full width = 5*ADVANCE ≈ 27 → shiftedX = 121 - 27 ≈ 94.
	// 94 < earlier's leftAnchor (105) → can't shift while pill-anchored → truncate.
	const placed = layoutLaneLabels(
		[
			input({ id: "a", startT: 0, label: "hello", pillLeft: 100 }),
			input({ id: "b", startT: 10, label: "x", pillLeft: 120 }),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 2);
	// Earlier placed first in output (paint order = left-to-right).
	assertEquals(placed[0]!.id, "a");
	assertEquals(placed[0]!.x, 105);
	assertEquals(placed[0]!.label.endsWith("…"), true);
	assertEquals(placed[1]!.id, "b");
	assertEquals(placed[1]!.x, 125);
	assertEquals(placed[1]!.label, "x");
});

Deno.test("layoutLaneLabels: earlier full label fits when neighbor leaves room", () => {
	// Pill A starts at 100 (anchor 105) with a 5-char label (~27 px
	// natural). Pill B's label starts at 155. A's available range is
	// [105, 151] = 46 px. 27 ≤ 46 → A keeps its full label.
	const placed = layoutLaneLabels(
		[
			input({
				id: "a",
				startT: 0,
				label: "hello",
				pillLeft: 100,
				pillRight: 400,
			}),
			input({ id: "b", startT: 10, label: "x", pillLeft: 150 }),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 2);
	assertEquals(placed[0]!.id, "a");
	assertEquals(placed[0]!.label, "hello");
	// Labels stay anchored to their pill — A at 105, B at 155.
	assertEquals(placed[0]!.x, 105);
	assertEquals(placed[1]!.x, 155);
});

Deno.test("layoutLaneLabels: drops label when no room for even ellipsis", () => {
	// Two labels at virtually the same x — earlier has no room.
	const placed = layoutLaneLabels(
		[
			input({ id: "a", startT: 0, label: "alice", pillLeft: 100 }),
			input({ id: "b", startT: 1, label: "bob", pillLeft: 101 }),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	// Only the later survives — the earlier's available width is
	// (101 - GAP) - 105 < 0 → dropped.
	assertEquals(placed.length, 1);
	assertEquals(placed[0]!.id, "b");
});

Deno.test("layoutLaneLabels: cascade — three overlapping spans, later wins each step", () => {
	// All three pills start near t=0; same overlap problem cascading.
	// Carol (latest) gets full label. Bob then has tiny available
	// width vs Carol → drops or shrinks. Alice has even less → drops.
	const placed = layoutLaneLabels(
		[
			input({
				id: "alice",
				startT: 0,
				label: "alice (gifter)",
				pillLeft: 100,
			}),
			input({
				id: "bob",
				startT: 5,
				label: "bob (receiver)",
				pillLeft: 103,
			}),
			input({
				id: "carol",
				startT: 10,
				label: "Carol (exporter)",
				pillLeft: 106,
			}),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	// Carol always present, full label.
	const carol = placed.find((p) => p.id === "carol");
	assertEquals(carol !== undefined, true);
	assertEquals(carol!.label, "Carol (exporter)");
	assertEquals(carol!.x, 111);
	// Earlier ones are either truncated heavily or dropped — both are
	// acceptable per variation 1; the invariant is that no surviving
	// label's right edge passes any later label's left edge.
	let prevLeft = Number.POSITIVE_INFINITY;
	// Walk right-to-left checking the non-overlap invariant.
	for (let i = placed.length - 1; i >= 0; i--) {
		const p = placed[i]!;
		const right = p.x + p.label.length * ADVANCE;
		if (i < placed.length - 1) {
			// right edge of this label ≤ left of the next placed label
			assertEquals(right <= prevLeft + 1e-6, true);
		}
		prevLeft = p.x;
	}
});

Deno.test("layoutLaneLabels: per-pill clip prevents overflow past pill.right", () => {
	// Single narrow pill with a long label — should truncate to fit
	// INSIDE its own pill bounds even without any neighbor pressure.
	const placed = layoutLaneLabels(
		[
			input({
				id: "a",
				startT: 0,
				label: "op:start-session",
				pillLeft: 100,
				pillRight: 130, // 30 px wide pill
			}),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 1);
	const p = placed[0]!;
	// Right edge must not exceed pillRight - LABEL_INSET_PX = 125.
	const rightEdge = p.x + p.label.length * ADVANCE;
	assertEquals(rightEdge <= 125 + 1e-6, true);
	assertEquals(p.label.endsWith("…"), true);
});

Deno.test("layoutLaneLabels: stable ordering for same input set", () => {
	// Same logical set in two different input orders → same outputs.
	const a = input({ id: "a", startT: 0, label: "alpha", pillLeft: 100 });
	const b = input({ id: "b", startT: 0, label: "beta", pillLeft: 100 });
	const c = input({ id: "c", startT: 5, label: "gamma", pillLeft: 200 });
	const r1 = layoutLaneLabels([a, b, c], ADVANCE, LABEL_GAP_PX, LABEL_MIN_PX);
	const r2 = layoutLaneLabels([c, b, a], ADVANCE, LABEL_GAP_PX, LABEL_MIN_PX);
	assertEquals(r1, r2);
});

Deno.test("layoutLaneLabels: skips inputs with undefined label", () => {
	const placed = layoutLaneLabels(
		[
			input({ id: "a", startT: 0, label: undefined, pillLeft: 100 }),
			input({ id: "b", startT: 10, label: "beta", pillLeft: 200 }),
		],
		ADVANCE,
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	assertEquals(placed.length, 1);
	assertEquals(placed[0]!.id, "b");
});

Deno.test("truncateToWidth: returns label unchanged when it fits", () => {
	// 5 chars × ADVANCE = 30 px; allow 50 → fits whole.
	assertEquals(truncateToWidth("hello", 50, ADVANCE), "hello");
});

Deno.test("truncateToWidth: truncates with ellipsis when wider than max", () => {
	// 10 chars natural = 60 px; allow 30 px → ellipsis + (30/ADVANCE - 1) chars.
	const out = truncateToWidth("abcdefghij", 30, ADVANCE);
	assertEquals(out.endsWith("…"), true);
	// Result must fit in max width.
	assertEquals(out.length * ADVANCE <= 30 + 1e-6, true);
});

Deno.test("truncateToWidth: returns ellipsis only when no char room", () => {
	// 1 char of room after the ellipsis would mean 6 px each; if we
	// allow only the ellipsis width plus a tiny slop, no char fits.
	const out = truncateToWidth("abcdef", ADVANCE + 0.5, ADVANCE);
	assertEquals(out, "…");
});

Deno.test("truncateToWidth: returns empty when ellipsis itself doesn't fit", () => {
	// Less than one advance worth of pixels → no room for even the
	// ellipsis glyph; caller should drop.
	assertEquals(truncateToWidth("abc", ADVANCE - 1, ADVANCE), "");
});
