/**
 * The Timeline's cursors, read the way the app reads them: a pointer
 * position becomes a `Hit`, and the hit becomes `cursorFor`'s answer.
 *
 * These pin the wiring rather than the rule — `interactions/cursor.test.ts`
 * owns the rule's own table. What can break here is the half this module
 * adds: a zone that names the wrong surface, a zone that names none, and the
 * precedence between them. Each case below was validated by breaking the
 * thing it names and watching it go red.
 */

import { assert, assertEquals } from "@std/assert";
import { projectFromObservations } from "../../engine/temporal/project-from-observations.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { iterateRows, type RowDescriptor, RULER_HEIGHT } from "./row-layout.ts";
import { type LaneKind, type TimelineView } from "./state.ts";
import { overviewHitAt, scrubberHoverAt, timelineCursor } from "./timeline-cursor.ts";
import type { BuilderTool, SurfaceGestureCtx } from "../../interactions/types.ts";

// Same geometry the Scrubber's own hit-test tests use: a 232 px host whose
// 104 px gutter and two 4 px pads leave a 120 px plot over t = [0, 1000].
const VIEW: TimelineView = {
	windowStart: 0,
	windowEnd: 1000,
	expandedLanes: new Set<LaneKind>(["peers", "sessions", "messages"]),
	expandedCategories: new Set(),
};
const SIZE = { width: 232, height: 118 };
const LANE_HEIGHT = 30;
const GUTTER = 104;

function makePeer(id: string, joinT: number, leftT?: number): TimelineEvent[] {
	const out: TimelineEvent[] = [{
		id: `${id}-joined`,
		kind: "peer-joined",
		t: joinT,
		peerId: id,
		profile: "pancake",
	}];
	if (leftT !== undefined) {
		out.push({ id: `${id}-left`, kind: "peer-left", t: leftT, peerId: id });
	}
	return out;
}

function docFor(
	events: readonly TimelineEvent[],
	entities?: TimelineDocument["entities"],
): TimelineDocument {
	return projectFromObservations({
		id: "timeline-cursor-test",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations: [...events],
			}],
		},
		...(entities ? { entities } : {}),
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
	});
}

/** One placeholder row per category, so a `py` lands in the lane a case
 *  means regardless of which events it supplies. */
function rowsFor(events: readonly TimelineEvent[]): RowDescriptor[] {
	const peers = new Set<string>(["_peer_placeholder"]);
	for (const ev of events) {
		if (ev.kind === "peer-joined" || ev.kind === "peer-left") {
			peers.add(ev.peerId);
		}
	}
	return [...iterateRows(
		VIEW.expandedLanes,
		VIEW.expandedCategories,
		{
			peers: [...peers],
			sessions: ["_session_placeholder"],
			messages: ["_message_placeholder"],
		},
		undefined,
		LANE_HEIGHT,
	)];
}

function hoverAt(
	px: number,
	py: number,
	over: {
		events?: readonly TimelineEvent[];
		doc?: TimelineDocument;
		rows?: readonly RowDescriptor[];
		disabledScrub?: boolean;
		scrollY?: number;
	} = {},
) {
	const events = over.events ?? [];
	return scrubberHoverAt({
		point: { px, py },
		size: SIZE,
		view: VIEW,
		scrollY: over.scrollY ?? 0,
		rows: over.rows ?? rowsFor(events),
		events,
		doc: over.doc ?? docFor(events),
		disabledScrub: over.disabledScrub ?? false,
	});
}

function cursorAt(
	px: number,
	py: number,
	over: Parameters<typeof hoverAt>[2] & {
		modifiers?: { shiftKey: boolean; altKey: boolean };
		tool?: BuilderTool;
		spaceHeld?: boolean;
	} = {},
): string {
	return timelineCursor({
		hit: hoverAt(px, py, over).hit,
		inFlight: null,
		gestureCtx: gestureCtx(over),
	});
}

/** The App's gesture context, as these surfaces now receive it. The Select
 *  tool with no Space is what the Timeline sees most of the time, so the
 *  helper defaults to it and each test names what it changes. */
function gestureCtx(
	over: {
		modifiers?: { shiftKey: boolean; altKey: boolean };
		tool?: BuilderTool;
		spaceHeld?: boolean;
	} = {},
): SurfaceGestureCtx {
	return {
		spaceHeld: over.spaceHeld ?? false,
		activeTool: over.tool ?? "select",
		modifiers: {
			shift: over.modifiers?.shiftKey ?? false,
			alt: over.modifiers?.altKey ?? false,
			cmd: false,
		},
	};
}

/** A row stack taller than the host, which is the only condition under which
 *  the fold exists. The shared helper collapses every category, so it yields
 *  three rows whatever the document holds; this expands `peers` so each one
 *  gets a row of its own. */
function tallRows(events: readonly TimelineEvent[]): RowDescriptor[] {
	const peers = new Set<string>();
	for (const ev of events) {
		if (ev.kind === "peer-joined" || ev.kind === "peer-left") {
			peers.add(ev.peerId);
		}
	}
	return [...iterateRows(
		VIEW.expandedLanes,
		new Set(["peers"]),
		{
			peers: [...peers],
			sessions: ["_session_placeholder"],
			messages: ["_message_placeholder"],
		},
		undefined,
		LANE_HEIGHT,
	)];
}

/** Eight peers, which at a 30 px lane is well past a 118 px host. */
const TALL_EVENTS: readonly TimelineEvent[] = [
	"a",
	"b",
	"c",
	"d",
	"e",
	"f",
	"g",
	"h",
].flatMap((id) => makePeer(id, 0, 1000));

Deno.test("a row scrolled into view is pointed at where it is drawn", () => {
	// The defect this pins: the row walk and the ruler-band test shared one `py`
	// while wanting different coordinate spaces, so any row whose LAYOUT y had
	// passed the host's ruler line was unreachable however far it was scrolled
	// into view. It took the cursor and the click together, because both come
	// through `hitTestEvents`, while marquee selection walked the rows itself and
	// kept working. That split is what made it visible.
	//
	// Enough peers that the stack is taller than the host, then the last one
	// scrolled to the top of the lanes.
	const events = TALL_EVENTS;
	const rows = tallRows(events);
	// The last row that carries event content, which a category header does not.
	const last = [...rows].reverse().find((r) => r.kind === "entity-row")!;
	assert(
		last.y >= SIZE.height - RULER_HEIGHT,
		"this document is not tall enough to reach past the fold, so the case is untested",
	);
	// The control: unscrolled, the first entity row is reachable. Row 0 is the
	// category header, which carries no event content, so this is row 1.
	const firstEntity = rows.find((r) => r.kind === "entity-row")!;
	const beforeScroll = hoverAt(152, firstEntity.y + 4, { events, rows });
	assertEquals(beforeScroll.hit?.surface, "timeline-lane-event");
	assert(
		firstEntity.y + 4 < SIZE.height - RULER_HEIGHT,
		"the control row is itself past the fold, so it proves nothing",
	);

	// Scrolled so the last row sits at the top of the lane area, a click there
	// has to reach it.
	const scrollY = last.y;
	const hovered = hoverAt(152, 4, { events, rows, scrollY });
	assertEquals(hovered.hit?.surface, "timeline-lane-event");
	assertEquals(
		hovered.hit?.surface === "timeline-lane-event" ? hovered.hit.entityRef.id : null,
		last.kind === "entity-row" ? last.entityId : null,
		"the row scrolled to the top of the lanes was not the row hit",
	);
	assertEquals(cursorAt(152, 4, { events, rows, scrollY }), "pointer");
});

Deno.test("the ruler band still scrubs when rows are scrolled under it", () => {
	// The other side of the same split. The ruler is drawn at the bottom of the
	// host, so a press there scrubs — and a scrolled row stack now has rows whose
	// layout y sits under that band. Answering the band test in layout space
	// would let one of them take the press.
	const events = TALL_EVENTS;
	const rows = tallRows(events);
	const inRuler = SIZE.height - Math.floor(RULER_HEIGHT / 2);
	const hit = hoverAt(152, inRuler, { events, rows, scrollY: rows[2]!.y });
	assertEquals(hit.hit?.surface, "timeline-ruler");
	assertEquals(
		cursorAt(152, inRuler, { events, rows, scrollY: rows[2]!.y }),
		"ew-resize",
	);
});

// ─────────────────────── The zones, in the order they win ──────────────

Deno.test("the gutter seam is its own surface, above the row it crosses", () => {
	const { hit, hoverKey } = hoverAt(GUTTER - 1, 10);
	assertEquals(hit?.surface, "timeline-gutter-edge");
	assertEquals(hoverKey, "edge");
	assertEquals(cursorAt(GUTTER - 1, 10), "col-resize");
});

Deno.test("the gutter's controls each name themselves", () => {
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
		{
			kind: "entity-row",
			category: "peers",
			entityId: "alice",
			y: 30,
			height: 30,
			hidden: false,
		},
	];
	// px=8 is the chevron, px=24 the category's own eyeball; on the entity row
	// px=24 is that row's eyeball and px=60 its label.
	assertEquals(
		hoverAt(8, 15, { rows }).hit?.surface,
		"timeline-gutter-chevron",
	);
	assertEquals(
		hoverAt(24, 15, { rows }).hit,
		{
			surface: "timeline-gutter-eyeball",
			scope: { kind: "category", category: "peers" },
		},
	);
	assertEquals(
		hoverAt(24, 45, { rows }).hit,
		{
			surface: "timeline-gutter-eyeball",
			scope: { kind: "row", category: "peers", entityId: "alice" },
		},
	);
	assertEquals(
		hoverAt(60, 45, { rows }).hit?.surface,
		"timeline-gutter-label",
	);
	// All four are "the click does something here".
	for (const [px, py] of [[8, 15], [24, 15], [24, 45], [60, 45]]) {
		assertEquals(cursorAt(px!, py!, { rows }), "pointer", `at ${px},${py}`);
	}
});

Deno.test("the gutter's row keys are what the paint pass fills", () => {
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
		{
			kind: "entity-row",
			category: "peers",
			entityId: "alice",
			y: 30,
			height: 30,
			hidden: false,
		},
	];
	assertEquals(hoverAt(8, 15, { rows }).hoverKey, "header:peers");
	assertEquals(hoverAt(24, 15, { rows }).hoverKey, "category-eye:peers");
	assertEquals(hoverAt(24, 45, { rows }).hoverKey, "entity:peers:alice");
	assertEquals(hoverAt(60, 45, { rows }).hoverKey, "entity:peers:alice");
});

Deno.test("gutter, but on no control: nothing to point at", () => {
	const rows: RowDescriptor[] = [];
	assertEquals(hoverAt(60, 15, { rows }).hit, null);
	assertEquals(cursorAt(60, 15, { rows }), "default");
});

Deno.test("the scrub zone is the ruler band and the dead space above it", () => {
	// RULER_HEIGHT is 22, so py=100 is the band itself.
	assertEquals(hoverAt(152, 100).hit?.surface, "timeline-ruler");
	assertEquals(cursorAt(152, 100), "ew-resize");
	// With one short row, everything below it and above the band is the dead
	// space that scrubs too — the same press, so the same cursor.
	const rows: RowDescriptor[] = [
		{ kind: "category-collapsed", category: "peers", y: 0, height: 30 },
	];
	assertEquals(hoverAt(152, 60, { rows }).hit?.surface, "timeline-ruler");
	assertEquals(cursorAt(152, 60, { rows }), "ew-resize");
});

Deno.test("in Live the scrub zone takes no click, so it points at nothing", () => {
	// The feed is forward-only and the press does nothing. A cursor promising
	// a seek would be the pointer lying about the next click.
	assertEquals(hoverAt(152, 100, { disabledScrub: true }).hit, null);
	assertEquals(cursorAt(152, 100, { disabledScrub: true }), "default");
});

Deno.test("empty lane: the ordinary arrow until a marquee is running", () => {
	// The lane answers the same way the empty stage does. A press here
	// starts a sweep, but hovering has started nothing, and the crosshair
	// is the sweep's own cursor rather than an advertisement for it.
	assertEquals(hoverAt(152, 10).hit?.surface, "timeline-lane-empty");
	assertEquals(cursorAt(152, 10), "default");
});

Deno.test("the Timeline draws Space and Hand, and no build tool", () => {
	// Space and the Hand tool are about getting around, which every surface has,
	// so they carry across the panel edge. The build tools do not: each of them
	// acts on the canvas and nothing any of them does lands here, so a cursor
	// naming one over a lane would promise a click no Timeline surface performs.
	assertEquals(hoverAt(152, 10).hit?.surface, "timeline-lane-empty");
	assertEquals(cursorAt(152, 10, { tool: "hand" }), "grab");
	assertEquals(cursorAt(152, 10, { spaceHeld: true }), "grab");
	// Each build tool reads as the lane's own answer, which over empty lane is
	// the plain arrow: a marquee is what a press and drag DOES rather than a
	// thing being aimed.
	for (const tool of ["add-peer", "open-session", "send-message"] as const) {
		assertEquals(
			cursorAt(152, 10, { tool }),
			"default",
			`${tool} leaked its own cursor onto an empty lane`,
		);
	}
	// And over a pill, the pill's answer rather than the tool's.
	const events = makePeer("alice", 0, 1000);
	assertEquals(
		hoverAt(152, 10, { events }).hit?.surface,
		"timeline-lane-event",
	);
	for (const tool of ["add-peer", "open-session", "send-message"] as const) {
		assertEquals(
			cursorAt(152, 10, { events, tool }),
			"pointer",
			`${tool} leaked its own cursor onto a pill`,
		);
	}
});

Deno.test("a modifier over a lane previews the same edit under any tool", () => {
	// The other half of the same defect. These hosts never read the active tool
	// on the way to a click, so a Shift-click on a pill adds to the selection
	// whichever tool is chosen — and the cursor has to say so. Gating the
	// preview on Select alone would leave the promise missing in Build mode,
	// which is the same disagreement between pointer and click read backwards.
	const events = makePeer("alice", 0, 1000);
	const shift = { modifiers: { shiftKey: true, altKey: false } };
	for (const tool of ["select", "add-peer", "send-message"] as const) {
		assertEquals(
			cursorAt(152, 10, { events, tool, ...shift }),
			"copy",
			`${tool} lost the add-to-selection preview over a pill`,
		);
	}
});

Deno.test("a pill reads pointer, and its edge handle reads col-resize", () => {
	const events = makePeer("alice", 0, 1000);
	const body = hoverAt(152, 10, { events });
	assertEquals(body.hit?.surface, "timeline-lane-event");
	assertEquals(
		body.hit?.surface === "timeline-lane-event" ? body.hit.eventId : null,
		"alice-joined",
	);
	assertEquals(cursorAt(152, 10, { events }), "pointer");

	const edge = hoverAt(222, 10, { events });
	assertEquals(edge.hit?.surface, "timeline-lane-event-edge");
	assertEquals(cursorAt(222, 10, { events }), "col-resize");
});

Deno.test("an authored span is a pill that no observation names", () => {
	// The engine retimes it by entity rather than by event, so the hit carries
	// no event id — and the pointer picks it exactly like any other pill.
	const doc = docFor([], {
		peers: {
			carol: {
				profile: "pancake",
				timing: {
					start: { value: 100, explicit: true },
					duration: { value: 500, explicit: true },
				},
			},
		},
	});
	const rows = [...iterateRows(
		VIEW.expandedLanes,
		VIEW.expandedCategories,
		{ peers: ["carol"], sessions: [], messages: [] },
		undefined,
		LANE_HEIGHT,
	)];
	const hit = hoverAt(152, 10, { doc, rows, events: [] }).hit;
	assertEquals(hit?.surface, "timeline-lane-event");
	assertEquals(
		hit?.surface === "timeline-lane-event" ? hit.eventId : "unset",
		null,
	);
	assertEquals(cursorAt(152, 10, { doc, rows, events: [] }), "pointer");
});

// ─────────────────────── What the rule adds on top ─────────────────────

Deno.test("a held Shift previews the selection edit over a pill", () => {
	const events = makePeer("alice", 0, 1000);
	assertEquals(
		cursorAt(152, 10, {
			events,
			modifiers: { shiftKey: true, altKey: false },
		}),
		"copy",
	);
	assertEquals(
		cursorAt(152, 10, {
			events,
			modifiers: { shiftKey: true, altKey: true },
		}),
		"no-drop",
	);
});

Deno.test("a gesture in flight outranks the surface under the pointer", () => {
	// A scrub that wanders into the gutter is still a scrub. Without this the
	// cursor would flip to the seam's or a control's answer mid-drag.
	assertEquals(
		timelineCursor({
			hit: { surface: "timeline-gutter-edge" },
			inFlight: {
				surface: "timeline-ruler",
				verb: { kind: "scrub" },
			},
			gestureCtx: gestureCtx(),
		}),
		"ew-resize",
	);
});

Deno.test("a row lifted out of the stack reads grabbing while it moves", () => {
	assertEquals(
		timelineCursor({
			hit: null,
			inFlight: {
				surface: "timeline-gutter-label",
				verb: {
					kind: "reorder-row",
					category: "peers",
					entityId: "alice",
				},
			},
			gestureCtx: gestureCtx(),
		}),
		"grabbing",
	);
});

// ─────────────────────── The Overview strip ────────────────────────────

const OVERVIEW_WIDTH = 400;

function overviewAt(px: number, over: { hasEye?: boolean } = {}) {
	return overviewHitAt({
		px,
		width: OVERVIEW_WIDTH,
		view: { ...VIEW, windowStart: 200, windowEnd: 600 },
		duration: 1000,
		hasAllRowsEyeball: over.hasEye ?? true,
	});
}

function overviewCursor(px: number, over: { hasEye?: boolean } = {}): string {
	return timelineCursor({
		hit: overviewAt(px, over),
		inFlight: null,
		gestureCtx: gestureCtx(),
	});
}

Deno.test("the overview's gutter holds one control, the all-rows eyeball", () => {
	assertEquals(overviewAt(24), {
		surface: "timeline-gutter-eyeball",
		scope: { kind: "all" },
	});
	assertEquals(overviewCursor(24), "pointer");
	// Beside it, and with no callback wired at all, there is nothing to point
	// at — an eyeball nobody painted must not answer for its pixels.
	assertEquals(overviewAt(60), null);
	assertEquals(overviewAt(24, { hasEye: false }), null);
	assertEquals(overviewCursor(60), "default");
});

Deno.test("the window's ends are grips, and the rest of the strip pans", () => {
	// Plot spans [108, 400): the window [200, 600) of a 1000 ms document puts
	// its start grip at 108 + 0.2·288 and its end at 108 + 0.6·288.
	const plotW = OVERVIEW_WIDTH - GUTTER - 8;
	const startPx = 108 + 0.2 * plotW;
	const endPx = 108 + 0.6 * plotW;
	assertEquals(overviewAt(startPx)?.surface, "timeline-overview-edge");
	assertEquals(overviewAt(endPx)?.surface, "timeline-overview-edge");
	assertEquals(overviewCursor(startPx), "ew-resize");
	assertEquals(overviewCursor(endPx), "ew-resize");

	// Inside the window, and outside it: one surface, because the press pans
	// the window either way — from outside it jumps there first.
	const inside = (startPx + endPx) / 2;
	const outside = endPx + 40;
	assertEquals(overviewAt(inside)?.surface, "timeline-overview");
	assertEquals(overviewAt(outside)?.surface, "timeline-overview");
	assertEquals(overviewCursor(inside), "grab");
	assertEquals(overviewCursor(outside), "grab");
});

Deno.test("an overview hit carries the t under the pointer", () => {
	const plotW = OVERVIEW_WIDTH - GUTTER - 8;
	const hit = overviewAt(108 + plotW / 2);
	assertEquals(hit?.surface, "timeline-overview");
	assertEquals(hit?.surface === "timeline-overview" ? hit.t : null, 500);
});
