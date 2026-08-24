/** The complete input contract for the timeline detail strip. */

import type { RefObject } from "react";
import type { ClockSnapshot } from "../../engine/clock.ts";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/moves.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import type { SelectMode, StageSelection } from "../../render/types.ts";
import type { EntityRefKey, SurfaceGestureCtx } from "../../interactions/types.ts";
import type { LaneKind, TimelineView } from "./state.ts";

export type ScrubberProps = {
	view: TimelineView;
	clock: ClockSnapshot;
	/** The full doc — needed by the lane-bundle builder to resolve
	 *  `entity.timing` through the effective-range resolvers
	 *  (`peerEffective` / `sessionEffective` / `messageEffective`).
	 *  Replaces the pre-Behavior-layer flow where spans were derived
	 *  from observation `t` directly. */
	doc: TimelineDocument;
	events: readonly TimelineEvent[];
	/** Identity-side of the entity model — see
	 *  `doc.entities` in `timeline.ts`. Drives the gutter
	 *  rendering for eternal entities: peers / sessions present
	 *  here without a matching creation event in `events` get a
	 *  row with a span anchored to the cascade-resolved bounds
	 *  (peer → world; session → max-of-endpoints), instead of
	 *  being invisible in the timeline. */
	entities: TimelineDocument["entities"];
	/** Lane expansion set from `view.expandedLanes`. */
	expandedLanes: ReadonlySet<LaneKind>;
	/** Width hint for the marker div's CSS size; the actual paint
	 * width comes from the region rect each frame. */
	width: number;
	/** Dims the playhead during scrubbing. */
	scrubbing: boolean;
	/** Where the ghost playhead's time lives, shared with the
	 * Overview via `TimelinePanel`. A mutable box rather than a
	 * value, for the reason `rubberBandRef` and `snapLineRef` below
	 * are: both surfaces write it on every pointermove and the only
	 * reader is each surface's own Pixi ticker, so as state it
	 * re-rendered the whole timeline at pointer-event rate to move
	 * one number into two mutable slots. */
	hoverTRef: RefObject<number | null>;
	/** Literal view OR updater function (wheel handlers use the
	 * updater so multi-events-per-frame stack on fresh state). */
	onSetView: (
		next: TimelineView | ((current: TimelineView) => TimelineView),
	) => void;
	onSeek: (t: number) => void;
	onScrubStart: () => void;
	onScrubEnd: () => void;
	/** Current entity selection; rendered as a halo on matching
	 * spans / glyphs so the timeline highlights what's selected
	 * elsewhere (Stage, Inspector). */
	selection: StageSelection;
	/** Click an event pill / glyph to select its entity.
	 * `| undefined` is explicit so callers can wire it conditionally
	 * under `exactOptionalPropertyTypes`. */
	onSelectEvent?: ((selection: StageSelection) => void) | undefined;
	/** Sub-selection state machine (v1.5 #16). When the user clicks
	 *  a session-state-changed diamond, the Scrubber emits the
	 *  glyph's event id so the host can park "focus" on the
	 *  keyframe — distinct from entity selection, which sits on
	 *  the parent session. Clicks on span bodies / edges / empty
	 *  area emit `null`, clearing focus. Escape at the host clears
	 *  focus before entity selection so the state machine has a
	 *  predictable inner→outer unwind. */
	focusedEventId?: string | null;
	onFocusEvent?: ((eventId: string | null) => void) | undefined;
	/** Drag an event pill or edge handle to retime. The Scrubber
	 *  classifies the gesture (body translate or either edge resize)
	 *  at hit-test time and emits the matching
	 *  `MoveIntent` variant — no overload booleans, no optional
	 *  `arrivalT` that flips the meaning of the t argument. */
	onMoveEvent?: ((move: MoveIntent) => void) | undefined;
	/** Entity-addressed sibling of `onMoveEvent` for spans with no
	 *  anchor observation event (freshly authored peers/sessions);
	 *  dispatches the engine's `move-entity-span`. */
	onMoveEntitySpan?: ((move: MoveSpanIntent) => void) | undefined;
	/** Transaction bracket around a drag-retime burst so the many
	 * pointermove dispatches collapse into one undo step. */
	beginEdit?: ((label: string) => void) | undefined;
	endEdit?: (() => void) | undefined;
	/** Unified entity selection. Events owned by a member get the same halo as
	 *  the single-selection target. Empty set leaves that target alone.
	 * Reference identity drives the per-paint bail; callers MUST
	 * always create a new Set when membership changes, never
	 * mutate in place. Holds entity refs (peer / session / message
	 * keyed by `entityKey()`), not event ids — the Scrubber paints
	 * the multi-halo on every event whose owning entity is in the
	 * set, so the two ends of a pair light up together. */
	selectionSet: ReadonlySet<EntityRefKey>;
	/** Selection gesture (pill click or marquee) — forwarded with its
	 * modifier mode to the one interpreter (`selectionActionFor`), so
	 * this surface spells no set arithmetic of its own. */
	onEditSelection: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
	/** Reports the Scrubber's computed intrinsic height — the
	 * minimum pixels needed to render the current expansion
	 * state with compact rows. The parent panel adds its own
	 * chrome (control row + overview) and forwards an aggregated
	 * intrinsic to App so the bottom pane can Fit / auto-size. */
	onIntrinsicHeightChange?: ((px: number) => void) | undefined;
	/** Reports the collapsed-fit scrubber height (every category
	 *  collapsed, lanes as currently toggled). The parent uses this
	 *  — not the live intrinsic — as the drag floor. */
	onCollapsedHeightChange?: ((px: number) => void) | undefined;
	/** Flash-grade timeline — per-category row management. */
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	/** Doc-side row ordering override (read-through to the
	 * renderer). Undefined ⇒ default first-event-t order. */
	rowOrder: TimelineDocument["rowOrder"];
	/** Doc-side per-row visibility (read-through, 4-state model —
	 * visible / label / body / both — see engine's `setRowVisMode`).
	 * Undefined ⇒ all rows fully visible. */
	rowHidden: TimelineDocument["rowHidden"];
	rowLabelHidden: TimelineDocument["rowLabelHidden"];
	rowBodyHidden: TimelineDocument["rowBodyHidden"];
	/** Stored per-category visibility flag — drives the
	 *  category-header eyeball glyph. Stored independently of
	 *  per-entity / all flags; the cascade is composed at draw
	 *  time in the Stage, not surveyed here. */
	categoryVisMode: TimelineDocument["categoryVisMode"];
	/** Click a category chevron → toggle expand. Optional so
	 * callers can opt out of the gesture (Play / non-Build modes
	 * can leave it undefined and the chevron is decorative). */
	toggleCategory?:
		| ((category: Exclude<LaneKind, "ruler">) => void)
		| undefined;
	/** Click a row eyeball → cycle this entity's visibility mode
	 * (visible → label-hidden → body-hidden → both-hidden → visible).
	 * The engine owns the state machine; the UI just signals "next". */
	cycleRowVisibility?:
		| ((category: Exclude<LaneKind, "ruler">, entityId: string) => void)
		| undefined;
	/** Click the category-row eyeball → show-all / hide-all for the
	 * category (lossy by design — wipes per-entity overrides for
	 * the category). Engine handles the show ↔ hide toggle. */
	cycleCategoryVisibility?:
		| ((category: Exclude<LaneKind, "ruler">) => void)
		| undefined;
	/** Commit a row-drag-reorder gesture. Called on pointerup with
	 * the final ordered list of entity ids for the affected
	 * category. Wrap in a transaction at the caller. */
	commitRowReorder?:
		| ((
			category: Exclude<LaneKind, "ruler">,
			order: string[],
		) => void)
		| undefined;
	/** Suppress the scrub / seek gestures (click in ruler band,
	 *  click in empty scrub zone, drag-from-ruler). Used in Live
	 *  mode — the feed is forward-only, so seeking has no meaning.
	 *  Other gestures (wheel zoom / pan, marquee select, entity
	 *  click, gutter chevron / eyeball / row reorder, gutter-edge
	 *  resize) stay enabled. */
	disabledScrub?: boolean | undefined;
	/** The App's gesture context — Space, the active tool, and the keys held
	 * right now. The cursor is drawn from it, so a modifier press previews the
	 * select-mode cursor immediately, without waiting for the next pointer
	 * move, and an authoring tool keeps its cursor over this surface too. */
	gestureCtx: SurfaceGestureCtx;
	/** View-width ceiling (zoom-out floor). Defaults to
	 *  `clock.duration`. Live passes `MAX_LIVE_WINDOW_MS` (1 week)
	 *  so the user can zoom out past 1× and see week-of-context
	 *  ruler ticks. Shared with Overview via
	 *  `TimelinePanel` so both surfaces honor the same bounds. */
	viewMaxWidth?: number | undefined;
	/** Right-edge cap for pan. Defaults to `clock.duration`. Live
	 *  passes `Infinity` so pan-right is unbounded — the timeline
	 *  has no end. Shared with Overview. */
	viewPanMaxT?: number | undefined;
};
