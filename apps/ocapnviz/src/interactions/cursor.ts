/**
 * Cursor derivation, implements `docs/cursor.md`.
 *
 * THE cursor authority. Pure. No DOM access. Nothing else in the app decides
 * what the pointer looks like.
 *
 * Three elements can carry a cursor, because the Timeline's two DOM hosts sit
 * above the canvas and take the pointer where they overlap it. Each has exactly
 * one writer and each writes this function's answer: the Stage asks once per
 * frame and hands the answer to `UnifiedCanvas`'s `setCursor`, and the Scrubber
 * and Overview ask on every pointer move through
 * `ui/Timeline/timeline-cursor.ts`.
 *
 * The cursor is the tool's contract with the user: it shows what the NEXT
 * click will do. So it is derived from the same `resolveGesture` that click
 * goes through, and from the same `PointerMachineState` that runs it. A second
 * spelling of the rule would be a second answer, and the two drift, a node
 * reading as a target while the click declines it is the shape that drift
 * takes, and this module exists so there is nowhere for it to happen.
 *
 * The ladder mirrors § 4.2 ordering: gesture in flight, Space, Hand tool,
 * then, over a hovered surface, refusal, selection preview, the tool's own
 * cursor, and finally the resolved verb's.
 *
 * Two of those rungs speak about build tools, and build tools act only on the
 * Stage. Both are therefore scoped to the surface under the pointer rather than
 * offered to every host that shares the ladder: the tool-create tier can only
 * arise from a Stage hit because `resolveGesture` only mints it there, and
 * `restingCursorOver` refuses to answer for any surface outside
 * `STAGE_SURFACES`. Sharing the ladder is the point of this module. Sharing a
 * rung that means nothing on the asking surface was the defect.
 */

import { resolveGesture } from "./gesture-resolver.ts";
import { inFlightGesture } from "./pointer-machine.ts";
import {
	type BuilderTool,
	isStageSurface,
	type PointerMachineState,
	type ResolvedGesture,
	selectModeFromModifiers,
	type SurfaceGestureCtx,
	type SurfaceId,
	type ToolState,
} from "./types.ts";

/** Subset of valid `cursor` CSS values we actually emit. */
export type CSSCursor =
	| "default"
	| "pointer"
	| "grab"
	| "grabbing"
	| "crosshair"
	/** A handle that resizes something's extent: either event-pill edge,
	 *  the gutter's seam. */
	| "col-resize"
	/** A drag that moves along time: the playhead under a scrub, an event
	 *  retimed, the overview window's ends. */
	| "ew-resize"
	| "move"
	/** Open Session's resting cursor. The spreadsheet-style pick. */
	| "cell"
	/** A click or marquee would ADD to the selection (Shift), and Send
	 *  Message's resting cursor. */
	| "copy"
	/** A click or marquee would REMOVE from the selection (Shift+Option). */
	| "no-drop"
	/** The active tool cannot act on the node under the pointer. Says so
	 *  before the click, rather than an error saying so after it. */
	| "not-allowed";

/**
 * The gesture context a cursor is drawn from: what every surface carries,
 * plus the pick a two-click tool is holding.
 *
 * `toolState` is here and not in `GestureContext` because the resolver does
 * not read it. A pick resolves from the tool and the node under the pointer
 * alone. The cursor is the one reader: with a pick armed, whether the node
 * ahead is a legal partner is a question about the document, and
 * {@link ToolWillPick} answers it from the armed node. The host supplies it
 * at paint time (the Stage from its `armedNode` prop), because a pick can arm
 * with no pointer event to snapshot it.
 */
export type CursorContext = SurfaceGestureCtx & {
	toolState: ToolState | null;
};

/**
 * Whether a two-click tool will act on the node it is about to pick.
 *
 * Injected because it is a fact about the DOCUMENT, and this module is pure
 * over `GestureContext`. With a pick already armed, the legal partners depend
 * on the sessions those two nodes are on, which no gesture context can see.
 * The host supplies `builder/two-click.ts`'s `twoClickAccepts`, the same
 * statement the click path consults, so the pointer refuses exactly what the
 * click refuses.
 *
 * Omitted, the cursor answers with the half the resolver can see: the tool and
 * the kind of node, which is the whole answer until a pick is armed.
 */
export type ToolWillPick = (pick: {
	tool: "open-session" | "send-message";
	/** The node already picked and waiting for its partner. Null on a first
	 *  pick, when there is no partner to be wrong for. */
	armedNodeId: string | null;
	/** The node under the pointer. */
	nodeId: string;
}) => boolean;

export function cursorFor(
	ctx: CursorContext,
	fsmState: PointerMachineState,
	willPick: ToolWillPick = () => true,
): CSSCursor {
	// A gesture the FSM holds is what is HAPPENING; the rest of the ladder
	// only offers. The FSM is the authority on which one, because only it knows
	// what the press resolved to: releasing Space during a pan leaves a pan
	// running, and releasing it during a marquee that Space interrupted puts the
	// marquee back. Same key event, two outcomes.
	const running = inFlightGesture(fsmState);
	if (running !== null) return cursorForGestureInFlight(running);
	// Space held → grab (Adobe convention: Space temporarily activates the Hand
	// tool's cursor).
	if (ctx.spaceHeld) return "grab";
	if (ctx.activeTool === "hand") return "grab";
	// Hover is the cursor's reason to exist: off every surface there is no next
	// click to describe.
	if (fsmState.hover === null) return "default";
	// Resolve first, because a tool's own cursor is what it says when it CAN
	// act. Over a node it has declined, the answer is that it cannot, and
	// returning the tool's cursor before asking would show a pick cursor over
	// a node no click will do anything to.
	const resolved = resolveGesture({ ...ctx, hit: fsmState.hover.hit });
	if (resolved.tier === "tool-refuses") return "not-allowed";
	if (resolved.tier === "tool-create") {
		if (resolved.verb.kind === "two-click-pick") {
			// The resolver took this node on the tool and the kind alone. Whether
			// the pick already armed leaves it a legal partner is the document's
			// answer, and only the host has that.
			const armed = ctx.toolState !== null &&
					ctx.toolState.tool === resolved.verb.tool
				? ctx.toolState.nodeId
				: null;
			if (
				!willPick({
					tool: resolved.verb.tool,
					armedNodeId: armed,
					nodeId: resolved.verb.nodeId,
				})
			) {
				return "not-allowed";
			}
		}
		// The tool's own cursor outranks the verb here, cursor.md step 5 before step
		// 6. The tool is what the user chose, and the node it is about to act on
		// is the last place to stop saying which tool that is: every authoring
		// tool would otherwise read `crosshair` at the exact moment of aiming.
		// Only the two refusals above override it, because a refusal is the tool
		// NOT acting.
		return restingCursor(ctx.activeTool) ??
			cursorForResolvedHover(resolved);
	}
	const preview = selectionPreview(ctx, resolved);
	if (preview !== null) return preview;
	const toolCursor = restingCursorOver(fsmState.hover.hit.surface, ctx);
	if (toolCursor !== null) return toolCursor;
	return cursorForResolvedHover(resolved);
}

/**
 * A build tool's resting cursor, but only over a surface the tool can act on.
 *
 * This rung is where the one cursor authority leaked. Sharing the ladder across
 * the Stage and the Timeline is right, and `cursor.ts` exists so there is one
 * answer. What was missing is that a rung meaning something on one surface
 * family was not scoped to it. The Timeline asks the same `cursorFor` through
 * `ui/Timeline/timeline-cursor.ts`, so it inherited `crosshair` over a lane and
 * `cell` over the gutter. A promise about the next click that no Timeline
 * surface can keep, because no build tool acts there.
 *
 * Scoped by the surface under the pointer rather than by which host is asking.
 * The fact that decides it is where the tool can act, and the hit already
 * carries that, so a third host wiring itself to this ladder gets the right
 * answer without knowing the rule exists. Asking the caller instead would put
 * the answer in the one place that can get it wrong.
 */
function restingCursorOver(
	surface: SurfaceId,
	ctx: CursorContext,
): CSSCursor | null {
	if (!isStageSurface(surface)) return null;
	return restingCursor(ctx.activeTool);
}

/**
 * What a click or marquee would do to the selection, previewed under the
 * modifier that would do it. Two conditions, and both are needed: only the
 * Select tool has a selection to preview into, and only over a surface whose
 * verb commits into that selection. The ruler scrubs and the gutter toggles
 * rows, so a modifier held over either says nothing about them and they keep
 * their own cursors.
 *
 * The modifier grammar has one home (`selectModeFromModifiers`), so this maps
 * its verdict rather than re-reading the keys.
 */
function selectionPreview(
	ctx: CursorContext,
	resolved: ResolvedGesture,
): CSSCursor | null {
	if (ctx.activeTool !== "select") return null;
	if (!verbTouchesSelection(resolved)) return null;
	switch (
		selectModeFromModifiers({
			shiftKey: ctx.modifiers.shift,
			altKey: ctx.modifiers.alt,
		})
	) {
		case "add":
			return "copy";
		case "remove":
			return "no-drop";
		case "replace":
			return null;
	}
}

/** Whether the resolved gesture would commit into the selection. The marquee
 *  and the range extension join {@link verbSelectsEntity}'s single-entity
 *  picks, because all three are what a Shift preview speaks about. */
function verbTouchesSelection(verb: ResolvedGesture): boolean {
	if (verb.tier !== "default") return false;
	switch (verb.verb.kind) {
		case "rubber-band":
			return true;
		default:
			return verbSelectsEntity(verb);
	}
}

/**
 * The cursor a tool shows over a surface it has no verb for. Its statement of
 * which tool is active, held across the whole canvas so the affordance does
 * not blink out the instant the pointer crosses something.
 *
 * Select and Hand have none: Select's answer is the surface's own verb, and
 * Hand never reaches this rung. Where an authoring tool DOES act, the verb
 * answers instead (a pick is a crosshair, because a pick is aimed).
 *
 * The tools these name exist only in Build. The app-state reducer refuses them
 * in any other mode, so the tool implies the mode and neither the resolver nor
 * this function has to read one.
 */
function restingCursor(tool: BuilderTool): CSSCursor | null {
	switch (tool) {
		case "select":
		case "hand":
			return null;
		case "add-peer":
			return "crosshair";
		case "open-session":
			return "cell";
		case "send-message":
			return "copy";
		default:
			return assertNever(tool);
	}
}

/** Cursor for a verb resolved at a HOVER hit (no press yet), what the next
 *  click on this surface would do. */
function cursorForResolvedHover(
	verb: ResolvedGesture,
): CSSCursor {
	if (verb.tier === "space-pan" || verb.tier === "hand-tool") return "grab";
	if (verb.tier === "tool-create") return "crosshair";
	if (verb.tier === "tool-refuses") return "not-allowed";
	const v = verb.verb;
	switch (v.kind) {
		case "select-or-drag-peer":
		case "select-or-drag-endpoint":
		case "select-edge":
		case "select-message":
		case "select-or-drag-event":
		case "toggle-category":
		case "toggle-row-visibility":
		// A row label's click selects that row's entity and its drag reorders the
		// rows. Both are "the click does something here", which is what `pointer`
		// says; the reorder is a discovered affordance, and a resize cursor over a
		// control whose click selects would describe neither half.
		case "reorder-row":
			return "pointer";
		case "drag-event-edge":
		case "resize-gutter":
			return "col-resize";
		case "scrub":
		case "resize-time-window":
			return "ew-resize";
		case "pan-view":
			return "grab";
		// Empty space, pointer up, Select in hand: the ordinary arrow. A
		// marquee is what a press and drag here DOES, not a thing being
		// aimed, and a crosshair standing over every empty pixel advertises
		// a gesture nobody has started. It appears once the sweep is
		// running, which `cursorForGestureInFlight` answers.
		case "rubber-band":
			return "default";
		default:
			return assertNever(v);
	}
}

// ─────────────────────── Affordance predicates ───────────────────────
//
// The render layer asks: "for the entity the user is hovering, what
// affordance should be drawn?" The answer is derived from the SAME
// `resolveGesture` the click pipeline uses, guaranteeing the
// preview matches the action. New tools change behavior here only
// by virtue of changing what `resolveGesture` returns.

/** True when the resolved verb would, on click, select the entity
 *  hovered (single-select or drag-on-press). Drives the "hover
 *  ring" affordance on Stage and pill highlight on Timeline. */
export function verbSelectsEntity(verb: ResolvedGesture): boolean {
	if (verb.tier !== "default") return false;
	const k = verb.verb.kind;
	return k === "select-or-drag-peer" ||
		k === "select-or-drag-endpoint" ||
		k === "select-edge" ||
		k === "select-message" ||
		k === "select-or-drag-event";
}

/** True when the resolved verb is a two-click-pick (Open Session /
 *  Send Message arming the first or completing the second click).
 *  Drives the marching-ants affordance on candidate peers. */
export function verbArmsForTool(verb: ResolvedGesture): boolean {
	return verb.tier === "tool-create" && verb.verb.kind === "two-click-pick";
}

/** True when the resolved verb is a pan (Hand tool active OR Space
 *  held). Affordances that respond to pointer (hover rings,
 *  marching ants, etc.) suppress themselves. */
export function verbIsPan(verb: ResolvedGesture): boolean {
	return verb.tier === "space-pan" || verb.tier === "hand-tool";
}

/** Cursor while `verb` is in flight. A press the FSM has resolved, the drag
 *  it became, or a pan that interrupted one. */
function cursorForGestureInFlight(
	verb: ResolvedGesture,
): CSSCursor {
	if (verb.tier === "space-pan" || verb.tier === "hand-tool") {
		return "grabbing";
	}
	if (verb.tier === "tool-create") return "crosshair";
	// A refused node never starts a drag, so this is unreachable in practice;
	// answering it keeps the mapping total over the tiers.
	if (verb.tier === "tool-refuses") return "not-allowed";
	const v = verb.verb;
	switch (v.kind) {
		case "select-or-drag-peer":
		case "select-or-drag-endpoint":
			return "move";
		case "select-or-drag-event":
			return "ew-resize"; // event drag = retime (horizontal)
		case "drag-event-edge":
		case "resize-gutter":
			return "col-resize";
		case "scrub":
		case "resize-time-window":
			return "ew-resize";
		case "pan-view":
			return "grabbing";
		case "rubber-band":
			return "crosshair";
		// A row lifted out of its stack, the same "you are carrying this" the pan
		// shows. It is a move, not a resize.
		case "reorder-row":
			return "grabbing";
		default:
			// Catch-all for verbs that shouldn't appear during drag
			// (clicks-only verbs); return default to be safe.
			return "default";
	}
}

function assertNever(x: never): never {
	throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}
