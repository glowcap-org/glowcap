import { assertEquals } from "@std/assert";
import {
	type CSSCursor,
	type CursorContext,
	cursorFor,
	type ToolWillPick,
	verbArmsForTool,
	verbIsPan,
	verbSelectsEntity,
} from "./cursor.ts";
import { ALL_SURFACES, dummyHit } from "./gesture-resolver-test/harness.ts";
import type { Hit, SurfaceId } from "./surface-hit.ts";
import { IDLE_MACHINE, type PointerMachineState } from "./pointer-machine.ts";
import { NO_MODIFIERS } from "./pointer-input.ts";
import type { ResolvedGesture } from "./gesture-resolver.ts";

function ctx(over: Partial<CursorContext> = {}): CursorContext {
	return {
		modifiers: NO_MODIFIERS,
		spaceHeld: false,
		activeTool: "select",
		toolState: null,
		...over,
	};
}

function pressed(verb: ResolvedGesture): PointerMachineState {
	// Construct a `dragging` state with a known resolved verb. Only
	// fsm.kind=dragging and fsm.resolved matter to cursorFor.
	return {
		fsm: {
			kind: "dragging",
			surface: "stage-empty",
			resolved: verb,
			start: {
				clientX: 0,
				clientY: 0,
				buttons: 1,
				modifiers: NO_MODIFIERS,
				timestampMs: 0,
			},
			current: {
				clientX: 10,
				clientY: 10,
				buttons: 1,
				modifiers: NO_MODIFIERS,
				timestampMs: 100,
			},
		},
		hover: null,
	};
}

function withHover(hit: Hit): PointerMachineState {
	return {
		fsm: { kind: "idle" },
		hover: { surface: hit.surface, hit },
	};
}

// ─────────────────────── Pan tier wins everything ─────────────────────

Deno.test("a paused pan shows the grabbing cursor", () => {
	const fsm: PointerMachineState = {
		fsm: {
			kind: "paused-pan",
			resume: {
				surface: "stage-empty",
				resolved: {
					tier: "default",
					verb: { kind: "rubber-band", mode: "replace" },
				},
				start: {
					clientX: 0,
					clientY: 0,
					buttons: 1,
					modifiers: NO_MODIFIERS,
					timestampMs: 0,
				},
			},
			panOrigin: {
				clientX: 0,
				clientY: 0,
				buttons: 1,
				modifiers: NO_MODIFIERS,
				timestampMs: 0,
			},
			current: {
				clientX: 10,
				clientY: 10,
				buttons: 1,
				modifiers: NO_MODIFIERS,
				timestampMs: 100,
			},
		},
		hover: null,
	};
	assertEquals(cursorFor(ctx(), fsm), "grabbing" as CSSCursor);
});

Deno.test("dragging with the space-pan tier shows the grabbing cursor", () => {
	const fsm = pressed({ tier: "space-pan", verb: { kind: "pan-surface" } });
	assertEquals(cursorFor(ctx(), fsm), "grabbing");
});

Deno.test("spaceHeld with no fsm activity shows the grab cursor", () => {
	assertEquals(
		cursorFor(ctx({ spaceHeld: true }), withHover(dummyHit("stage-peer"))),
		"grab",
	);
});

Deno.test("an active hand tool shows the grab cursor", () => {
	assertEquals(
		cursorFor(
			ctx({ activeTool: "hand" }),
			withHover(dummyHit("stage-peer")),
		),
		"grab",
	);
});

// ─────────────────────── Tool cursors ─────────────────────────────────

Deno.test("Add Peer with a hover shows the crosshair cursor", () => {
	assertEquals(
		cursorFor(
			ctx({ activeTool: "add-peer" }),
			withHover(dummyHit("stage-empty")),
		),
		"crosshair",
	);
});

Deno.test("Open Session keeps its own cursor over a peer it will take", () => {
	// cursor.md step 5 before step 6: the tool's cursor outranks the verb's. The node
	// the tool is about to act on is the last place to stop saying which tool is
	// active, otherwise every authoring tool reads the same at the moment of
	// aiming, and the palette's distinction ends where it matters.
	assertEquals(
		cursorFor(
			ctx({ activeTool: "open-session" }),
			withHover(dummyHit("stage-peer")),
		),
		"cell",
	);
});

// ─────────────────────── Verb-resolved cursors (Select tool) ──────────

Deno.test("hovering a peer with Select shows the pointer cursor", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("stage-peer"))),
		"pointer",
	);
});

Deno.test("hovering the ruler with Select shows the ew-resize scrub cursor", () => {
	// A scrub moves the playhead along time; it does not resize anything. The
	// `col-resize` handle cursor belongs to the two seams that do, an event
	// pill's edge and the gutter's, and the two gestures must not read alike.
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-ruler", { t: 100 }))),
		"ew-resize",
	);
});

Deno.test("hovering the gutter seam with Select shows the col-resize cursor", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-gutter-edge"))),
		"col-resize",
	);
});

Deno.test("hovering an overview window grip with Select shows the ew-resize cursor", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-overview-edge"))),
		"ew-resize",
	);
});

Deno.test("hovering the right-edge handle with Select shows the col-resize cursor", () => {
	assertEquals(
		cursorFor(
			ctx(),
			withHover(dummyHit("timeline-lane-event-edge")),
		),
		"col-resize",
	);
});

Deno.test("hovering the overview with Select shows the grab pan-view cursor", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-overview", { t: 0 }))),
		"grab",
	);
});

// Empty space under Select is the ordinary arrow, not the marquee's
// crosshair. Nothing has been started, and a crosshair standing over
// every empty pixel announces a gesture that is not running. The
// crosshair belongs to the sweep itself, which the in-flight tests below
// pin.
Deno.test("hovering the empty stage with Select shows the default cursor because the marquee has not started", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("stage-empty"))),
		"default",
	);
});

Deno.test("hovering an empty lane with Select shows the default cursor because the marquee has not started", () => {
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-lane-empty"))),
		"default",
	);
});

Deno.test("hovering a gutter label with Select shows the pointer cursor", () => {
	// The label's click selects the row's entity and its drag reorders the
	// stack. `pointer` is the half that is true of a click, and the reorder is
	// a discovered affordance; a resize cursor would describe neither.
	assertEquals(
		cursorFor(ctx(), withHover(dummyHit("timeline-gutter-label"))),
		"pointer",
	);
});

Deno.test("a row lifted out of the stack reads grabbing", () => {
	// In flight, the reorder IS what is happening, and it is a move, the same
	// "you are carrying this" a pan shows.
	const fsm = pressed({
		tier: "default",
		verb: { kind: "reorder-row", category: "peers", entityId: "alice" },
	});
	assertEquals(cursorFor(ctx(), fsm), "grabbing");
});

// ─────────────────────── Off-canvas ───────────────────────────────────

Deno.test("no hover, no tool, and no flag shows the default cursor", () => {
	assertEquals(cursorFor(ctx(), IDLE_MACHINE), "default");
});

// ─────────────────────── Drag-in-flight verb cursors ──────────────────

Deno.test("dragging a peer shows the move cursor", () => {
	const fsm = pressed({
		tier: "default",
		verb: {
			kind: "select-or-drag-peer",
			peerId: "p",
			entityRef: { kind: "peer", id: "p" },
		},
	});
	assertEquals(cursorFor(ctx(), fsm), "move");
});

Deno.test("dragging an event shows the ew-resize cursor", () => {
	const fsm = pressed({
		tier: "default",
		verb: {
			kind: "select-or-drag-event",
			eventId: "e",
			entityRef: { kind: "peer", id: "p" },
		},
	});
	assertEquals(cursorFor(ctx(), fsm), "ew-resize");
});

Deno.test("dragging a rubber band shows the crosshair cursor", () => {
	const fsm = pressed({
		tier: "default",
		verb: { kind: "rubber-band", mode: "replace" },
	});
	assertEquals(cursorFor(ctx(), fsm), "crosshair");
});

// ─────────────────── Per-surface cursors, one table ───────────────────

Deno.test("the Select tool answers for every surface there is", () => {
	// Totality, so a surface added to the hit table cannot ship without a
	// cursor. The values are what the surface's own verb does on click.
	const table: Record<SurfaceId, CSSCursor> = {
		"stage-empty": "default",
		"stage-peer": "pointer",
		"stage-endpoint": "pointer",
		"stage-edge": "pointer",
		"stage-message": "pointer",
		"timeline-overview": "grab",
		"timeline-overview-edge": "ew-resize",
		"timeline-ruler": "ew-resize",
		"timeline-lane-empty": "default",
		"timeline-lane-event": "pointer",
		"timeline-lane-event-edge": "col-resize",
		"timeline-gutter-edge": "col-resize",
		"timeline-gutter-chevron": "pointer",
		"timeline-gutter-eyeball": "pointer",
		"timeline-gutter-label": "pointer",
	};
	assertEquals(
		new Set(Object.keys(table)).size,
		ALL_SURFACES.size,
		"a surface is missing from the cursor table",
	);
	for (const surface of ALL_SURFACES) {
		assertEquals(
			cursorFor(ctx(), withHover(dummyHit(surface))),
			table[surface],
			`cursor over ${surface}`,
		);
	}
});

// ─────────────────── What a tool refuses, before the click ────────────

Deno.test("Open Session over an end nothing attributed shows the not-allowed cursor", () => {
	// The resolver's own refusal: a new session mints its own two ends, so an
	// end that already belongs to one has nothing to be here. No document
	// question is involved, so no injection is needed to say so.
	assertEquals(
		cursorFor(
			ctx({ activeTool: "open-session" }),
			withHover(dummyHit("stage-endpoint")),
		),
		"not-allowed",
	);
});

Deno.test("with a pick armed, a node the click refuses reads not-allowed", () => {
	// The half the resolver cannot see. `willPick` is the host's answer, from
	// the same `twoClickAccepts` the click path consults.
	const armed = ctx({
		activeTool: "send-message",
		toolState: { tool: "send-message", nodeId: "s1::b" },
	});
	const hover = withHover(dummyHit("stage-peer", { peerId: "alice" }));
	assertEquals(cursorFor(armed, hover, () => false), "not-allowed");
	// Accepted. It is the tool's own cursor again. The refusal is the only
	// thing that outranks it.
	assertEquals(cursorFor(armed, hover, () => true), "copy");
});

Deno.test("the refusal is asked about the armed pick and the node hovered", () => {
	const asked: Parameters<ToolWillPick>[0][] = [];
	const willPick: ToolWillPick = (pick) => {
		asked.push(pick);
		return true;
	};
	cursorFor(
		ctx({
			activeTool: "send-message",
			toolState: { tool: "send-message", nodeId: "s1::b" },
		}),
		withHover(dummyHit("stage-peer", { peerId: "alice" })),
		willPick,
	);
	assertEquals(asked, [{
		tool: "send-message",
		armedNodeId: "s1::b",
		nodeId: "alice",
	}]);
});

Deno.test("a pick another tool armed is no partner for this one", () => {
	// Tools do not inherit each other's picks. The app clears the armed slot
	// on a tool change, and the cursor must not read a stale one as a partner.
	const asked: Parameters<ToolWillPick>[0][] = [];
	cursorFor(
		ctx({
			activeTool: "send-message",
			toolState: { tool: "open-session", nodeId: "carol" },
		}),
		withHover(dummyHit("stage-peer", { peerId: "alice" })),
		(pick) => {
			asked.push(pick);
			return true;
		},
	);
	assertEquals(asked[0]?.armedNodeId, null);
});

Deno.test("uninjected, the cursor answers the half the resolver can see", () => {
	// The whole answer until a pick is armed, and what the table tests above
	// rely on: Send Message takes either kind of node, so an end nothing has
	// attributed reads the tool's cursor rather than a refusal.
	assertEquals(
		cursorFor(
			ctx({ activeTool: "send-message" }),
			withHover(dummyHit("stage-endpoint")),
		),
		"copy",
	);
});

// ─────────────────── Authoring tools' own cursors ─────────────────────

Deno.test("an authoring tool holds its cursor where it does not act", () => {
	// The tool is the active verb dictionary, and saying so across the whole
	// canvas is what keeps the affordance from blinking out as the pointer
	// crosses an edge it has no verb for.
	for (
		const [tool, want] of [
			["add-peer", "crosshair"],
			["open-session", "cell"],
			["send-message", "copy"],
		] as const
	) {
		assertEquals(
			cursorFor(
				ctx({ activeTool: tool }),
				withHover(dummyHit("stage-edge")),
			),
			want,
			`${tool} over a session edge`,
		);
	}
});

Deno.test("a tool reads the same over what it acts on as elsewhere", () => {
	// The tool's cursor is its statement of which tool is active, and it does
	// not blink to something else the instant the pointer finds a target. Add
	// Peer rests on `crosshair` anyway, so only the two-click tools show the
	// difference.
	for (
		const [tool, cursor] of [
			["send-message", "copy"],
			["open-session", "cell"],
			["add-peer", "crosshair"],
		] as const
	) {
		assertEquals(
			cursorFor(
				ctx({ activeTool: tool }),
				withHover(dummyHit("stage-peer")),
			),
			cursor,
			`${tool} over a peer`,
		);
	}
	assertEquals(
		cursorFor(
			ctx({ activeTool: "add-peer" }),
			withHover(dummyHit("stage-empty")),
		),
		"crosshair",
	);
});

// ─────────────────── Selection previews under a modifier ──────────────

Deno.test("Shift previews add, Shift+Option previews remove", () => {
	const shift = { shift: true, cmd: false, alt: false };
	const shiftAlt = { shift: true, cmd: false, alt: true };
	// Every surface whose press commits into the selection, which is what a
	// preview speaks about. The empty lane is one of them: the Scrubber sweeps
	// a marquee there, the same gesture the empty stage starts.
	for (
		const hit of [
			dummyHit("stage-empty"),
			dummyHit("stage-peer"),
			dummyHit("timeline-lane-empty"),
		]
	) {
		assertEquals(
			cursorFor(ctx({ modifiers: shift }), withHover(hit)),
			"copy",
			`shift over ${hit.surface}`,
		);
		assertEquals(
			cursorFor(ctx({ modifiers: shiftAlt }), withHover(hit)),
			"no-drop",
			`shift+alt over ${hit.surface}`,
		);
	}
});

Deno.test("Option alone previews nothing because it is reserved", () => {
	// Unchanged from no modifier at all: the empty stage's ordinary arrow.
	assertEquals(
		cursorFor(
			ctx({ modifiers: { shift: false, cmd: false, alt: true } }),
			withHover(dummyHit("stage-empty")),
		),
		"default",
	);
});

Deno.test("a preview speaks only where the click would select", () => {
	// The ruler scrubs and the gutter label reorders rows; neither touches the
	// selection, so a held Shift says nothing about them.
	const shift = { shift: true, cmd: false, alt: false };
	assertEquals(
		cursorFor(
			ctx({ modifiers: shift }),
			withHover(dummyHit("timeline-ruler")),
		),
		"ew-resize",
	);
	assertEquals(
		cursorFor(
			ctx({ modifiers: shift }),
			withHover(dummyHit("timeline-gutter-label")),
		),
		"pointer",
	);
});

Deno.test("only a selecting tool previews modifiers", () => {
	// Add Peer binds its unmodified click; a modifier held over it means
	// nothing, so the tool keeps its own cursor.
	assertEquals(
		cursorFor(
			ctx({
				activeTool: "add-peer",
				modifiers: { shift: true, cmd: false, alt: false },
			}),
			withHover(dummyHit("stage-empty")),
		),
		"crosshair",
	);
});

// ─────────────────────── Affordance predicates ────────────────────────

Deno.test("verbSelectsEntity is true for select-or-drag-peer", () => {
	assertEquals(
		verbSelectsEntity({
			tier: "default",
			verb: {
				kind: "select-or-drag-peer",
				peerId: "p",
				entityRef: { kind: "peer", id: "p" },
			},
		}),
		true,
	);
});

Deno.test("verbSelectsEntity is false for pan-surface", () => {
	assertEquals(
		verbSelectsEntity({
			tier: "space-pan",
			verb: { kind: "pan-surface" },
		}),
		false,
	);
});

Deno.test("verbSelectsEntity is false for tool-create (Add Peer)", () => {
	assertEquals(
		verbSelectsEntity({
			tier: "tool-create",
			verb: { kind: "create-peer-at", t: 0 },
		}),
		false,
	);
});

Deno.test("verbSelectsEntity is false for rubber-band because it selects no entity", () => {
	assertEquals(
		verbSelectsEntity({
			tier: "default",
			verb: { kind: "rubber-band", mode: "replace" },
		}),
		false,
	);
});

Deno.test("verbArmsForTool is true for two-click-pick", () => {
	assertEquals(
		verbArmsForTool({
			tier: "tool-create",
			verb: {
				kind: "two-click-pick",
				tool: "open-session",
				nodeId: "p",
			},
		}),
		true,
	);
});

Deno.test("verbArmsForTool is false for the select verb", () => {
	assertEquals(
		verbArmsForTool({
			tier: "default",
			verb: {
				kind: "select-or-drag-peer",
				peerId: "p",
				entityRef: { kind: "peer", id: "p" },
			},
		}),
		false,
	);
});

Deno.test("verbIsPan is true for space-pan", () => {
	assertEquals(
		verbIsPan({ tier: "space-pan", verb: { kind: "pan-surface" } }),
		true,
	);
});

Deno.test("verbIsPan is true for hand-tool", () => {
	assertEquals(
		verbIsPan({ tier: "hand-tool", verb: { kind: "pan-surface" } }),
		true,
	);
});

Deno.test("verbIsPan is false for the select verb", () => {
	assertEquals(
		verbIsPan({
			tier: "default",
			verb: {
				kind: "select-or-drag-peer",
				peerId: "p",
				entityRef: { kind: "peer", id: "p" },
			},
		}),
		false,
	);
});
