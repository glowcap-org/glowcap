/**
 * The fitted panel height, held against the rows it has to cover.
 *
 * One authority decides which rows exist (`iterateRows`), and both the panel's
 * fitted height and the scroll clamp are derived from it. These tests pin that,
 * because the defect they exist for was three walks agreeing on the row pitch
 * and disagreeing about the rows: the fit and the clamp each skipped a category
 * that held nothing, the painter drew it anyway, and the reader got half a row
 * under the ruler with nothing to scroll to.
 *
 * Validated by injection: putting a `count === 0` skip back into
 * `rowStackHeight` fails "an empty category still takes the room its row
 * occupies", which is the shipped defect exactly.
 */

import { assert, assertEquals } from "@std/assert";
import {
	iterateRows,
	LANE_GAP,
	laneScrollMax,
	laneViewportHeight,
	MIN_LANE_HEIGHT,
	ROW_PITCH,
	rowStackHeight,
	RULER_HEIGHT,
	RULER_TOP_PAD,
	wholeRowsHeight,
} from "./row-layout.ts";
import type { LaneKind } from "./state.ts";
import { scrubberCollapsedHeight, scrubberHeight } from "./Scrubber.tsx";

const ALL_LANES = new Set<LaneKind>(["peers", "sessions", "messages"]);
const NONE = new Set<Exclude<LaneKind, "ruler">>();

function entities(
	peers: readonly string[] = [],
	sessions: readonly string[] = [],
	messages: readonly string[] = [],
) {
	return { peers, sessions, messages };
}

/** Every row the walk yields, so a test can talk about the last one. */
function rowsOf(
	expanded: ReadonlySet<LaneKind>,
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>,
	ordered: ReturnType<typeof entities>,
	laneHeight = MIN_LANE_HEIGHT,
) {
	return [
		...iterateRows(
			expanded,
			expandedCategories,
			ordered,
			undefined,
			laneHeight,
		),
	];
}

Deno.test("the stack height covers every row the walk yields", () => {
	// The property that makes a partial row unreachable: the height is the far
	// edge of the last row plus its half gap, so no row can extend past it.
	const cases: {
		ordered: ReturnType<typeof entities>;
		expanded: Set<Exclude<LaneKind, "ruler">>;
	}[] = [
		{ ordered: entities(), expanded: new Set() },
		{ ordered: entities(["a"]), expanded: new Set() },
		{ ordered: entities(["a", "b"]), expanded: new Set(["peers"]) },
		{
			ordered: entities(["a"], ["s1", "s2"], ["m1"]),
			expanded: new Set(["peers", "sessions", "messages"]),
		},
		// The case the defect lived in: two categories hold nothing while a third
		// holds rows, and the empty ones are drawn regardless.
		{
			ordered: entities(["a", "b", "c"], [], []),
			expanded: new Set(["peers"]),
		},
	];
	for (const { ordered, expanded } of cases) {
		const rows = rowsOf(ALL_LANES, expanded, ordered);
		const height = rowStackHeight(
			ALL_LANES,
			expanded,
			ordered,
			MIN_LANE_HEIGHT,
		);
		for (const row of rows) {
			assert(
				row.y + row.height <= height,
				`a ${row.kind} row reaches ${row.y + row.height}, past a stack of ${height}`,
			);
		}
		const last = rows[rows.length - 1];
		if (last !== undefined) {
			assertEquals(
				height,
				last.y + last.height + LANE_GAP / 2,
				"the height should land exactly on the last row's boundary",
			);
		}
	}
});

Deno.test("an empty category still takes the room its row occupies", () => {
	// `iterateRows` gives a category its row whether or not it holds anything,
	// and says why: chrome answers to the toggle the user set rather than to
	// content. A height that skipped those rows is what left one half-drawn.
	const emptyRows = rowsOf(ALL_LANES, NONE, entities());
	assertEquals(
		emptyRows.length,
		3,
		"three toggled-on lanes should be three rows",
	);
	const height = rowStackHeight(ALL_LANES, NONE, entities(), MIN_LANE_HEIGHT);
	assert(
		height > 0,
		"three drawn rows were given no height, so each one is clipped",
	);
	assertEquals(height, 3 * (MIN_LANE_HEIGHT + LANE_GAP));
});

Deno.test("a lane toggled off takes no room", () => {
	// The remedy for a lane a reader does not want is the toggle, not emptiness.
	const onlyPeers = new Set<LaneKind>(["peers"]);
	assertEquals(
		rowStackHeight(onlyPeers, NONE, entities(), MIN_LANE_HEIGHT),
		MIN_LANE_HEIGHT + LANE_GAP,
	);
	assertEquals(
		rowStackHeight(new Set<LaneKind>(), NONE, entities(), MIN_LANE_HEIGHT),
		0,
	);
});

Deno.test("the fitted panel height leaves the ruler its band", () => {
	// What the panel is actually sized to: the rows, plus the ruler and the pad
	// that keeps the bottom row off the tick labels.
	const ordered = entities(["a", "b"], ["s1"], []);
	const expanded = new Set<Exclude<LaneKind, "ruler">>(["peers"]);
	const fitted = scrubberHeight(ALL_LANES, {
		expandedCategories: expanded,
		orderedEntities: ordered,
	});
	const rows = rowStackHeight(ALL_LANES, expanded, ordered, MIN_LANE_HEIGHT);
	assertEquals(fitted, rows + RULER_HEIGHT + RULER_TOP_PAD);
	// And no row reaches into the ruler band at that height.
	const lanesMaxY = fitted - RULER_HEIGHT - RULER_TOP_PAD;
	for (const row of rowsOf(ALL_LANES, expanded, ordered)) {
		assert(
			row.y + row.height <= lanesMaxY,
			`a ${row.kind} row reaches into the ruler band`,
		);
	}
});

Deno.test("drag floor is collapsed-fit, below a live expansion", () => {
	// Expand a category and the live intrinsic rises; the drag floor stays at
	// every-category-collapsed. That gap is the range a hand can resize through.
	// Folding the live intrinsic into the floor made an expanded panel refuse
	// every downward drag — the defect this pins.
	const ordered = entities(["a", "b", "c"], ["s1", "s2"], ["m1"]);
	const collapsed = scrubberCollapsedHeight(ALL_LANES, ordered);
	const expanded = scrubberHeight(ALL_LANES, {
		expandedCategories: new Set(["peers", "sessions"]),
		orderedEntities: ordered,
	});
	assert(
		expanded > collapsed,
		`expanded ${expanded} should sit above collapsed-fit ${collapsed}`,
	);
	assertEquals(
		scrubberCollapsedHeight(ALL_LANES, ordered),
		scrubberHeight(ALL_LANES, {
			expandedCategories: new Set(),
			orderedEntities: ordered,
		}),
	);
});

Deno.test("a lane area of any height holds only whole rows", () => {
	// The panel is dragged to whatever height a hand stops at, so the fitted
	// rule alone does not cover it. Every height between one row and several has
	// to land on a boundary.
	for (let available = 0; available <= ROW_PITCH * 5; available++) {
		const usable = wholeRowsHeight(available);
		assertEquals(
			usable % ROW_PITCH,
			0,
			`${available}px of lane area gave ${usable}px, which is not whole rows`,
		);
		assert(
			usable <= available,
			"the usable height should never exceed what the panel gave it",
		);
		assert(
			available - usable < ROW_PITCH,
			"at most one row's worth should ever go unused",
		);
	}
});

Deno.test("every row a quantized lane area admits is drawn whole", () => {
	// The property stated the way the reader experiences it: pick any panel
	// height, and no row crosses the bottom of the lane area.
	const ordered = entities(["a", "b", "c", "d"], ["s1"], ["m1"]);
	const expanded = new Set<Exclude<LaneKind, "ruler">>(["peers"]);
	const rows = rowsOf(ALL_LANES, expanded, ordered);
	for (let panel = 0; panel <= 200; panel++) {
		const lanesMaxY = wholeRowsHeight(panel - RULER_HEIGHT - RULER_TOP_PAD);
		for (const row of rows) {
			const crosses = row.y < lanesMaxY && row.y + row.height > lanesMaxY;
			assert(
				!crosses,
				`a ${row.kind} row straddles the lane bottom at panel height ${panel}`,
			);
		}
	}
});

Deno.test("the last overflow row can scroll fully into every viewport", () => {
	const ordered = entities(["a", "b", "c", "d"], ["s1", "s2"], ["m1"]);
	const expanded = new Set<Exclude<LaneKind, "ruler">>([
		"peers",
		"sessions",
	]);
	const rows = rowsOf(ALL_LANES, expanded, ordered);
	const contentHeight = rowStackHeight(
		ALL_LANES,
		expanded,
		ordered,
		MIN_LANE_HEIGHT,
	);
	const last = rows.at(-1);
	assert(last !== undefined);

	// Exercise every sub-row remainder, including the heights where the raw
	// pixel viewport is larger than the row-aligned mask. The scroll ceiling
	// must use the mask's height or that remainder becomes unreachable travel.
	for (let panel = 0; panel <= 200; panel++) {
		const viewport = laneViewportHeight(panel);
		const scrollMax = laneScrollMax(contentHeight, panel);
		assertEquals(
			contentHeight - scrollMax,
			Math.min(contentHeight, viewport),
			`panel height ${panel} left an unreachable tail`,
		);
		assert(
			last.y + last.height - scrollMax <= viewport,
			`the last row remained clipped at panel height ${panel}`,
		);
	}
});
