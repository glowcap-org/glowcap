/**
 * Shared host the Scrubber pointer adapters read. Scrubber owns the
 * Pixi-facing refs. The hook fills the rest each render.
 */

import type { MutableRefObject, RefObject } from "react";
import type { MoveIntent, MoveSpanIntent } from "../../../engine/authoring/moves.ts";
import type { TimelineDocument, TimelineEvent } from "../../../engine/timeline.ts";
import type { EntityRefKey, SurfaceGestureCtx } from "../../../interactions/types.ts";
import type { SurfaceLease } from "../../../interactions/gesture-router.ts";
import type { SelectMode, StageSelection } from "../../../render/types.ts";
import type { DragMode } from "../scrubber-drag.ts";
import type { EventHitIndex } from "../event-hit-index.ts";
import type { RowDescriptor } from "../row-layout.ts";
import type { LaneKind, TimelineView } from "../state.ts";
import type { TimelineGesture } from "../timeline-cursor.ts";

export type OrderedEntities = Record<
	Exclude<LaneKind, "ruler">,
	readonly string[]
>;

/** Live snapshot the paint loop also writes. Pointer adapters only read it. */
export type ScrubberPointerLive = {
	view: TimelineView;
	events: readonly TimelineEvent[];
	doc: TimelineDocument;
	expandedLanes: ReadonlySet<LaneKind>;
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	rowHidden: TimelineDocument["rowHidden"];
	laneHeight: number;
	interactionRows: readonly RowDescriptor[];
	eventHitIndex: EventHitIndex;
};

export type ScrubberPointerHost = {
	surface: SurfaceLease;
	hostRef: RefObject<HTMLDivElement | null>;
	dragRef: MutableRefObject<DragMode>;
	inFlightRef: MutableRefObject<TimelineGesture | null>;
	gestureCtxRef: MutableRefObject<SurfaceGestureCtx>;
	selectionSetRef: MutableRefObject<ReadonlySet<EntityRefKey>>;
	lastHoverRef: MutableRefObject<{ px: number; py: number } | null>;
	rubberBandRef: MutableRefObject<
		{ x: number; y: number; width: number; height: number } | null
	>;
	snapLineRef: MutableRefObject<number | null>;
	hoverGutterRowRef: MutableRefObject<string | null>;
	scrollYRef: MutableRefObject<number>;
	scrollYMaxRef: MutableRefObject<number>;
	regionSizeRef: MutableRefObject<{ width: number; height: number }>;
	propsRef: { readonly current: ScrubberPointerLive };
	hoverTRef: { current: number | null };
	hostTitle: string;
	view: TimelineView;
	clockDuration: number;
	viewMaxWidth: number;
	viewPanMaxT: number;
	events: readonly TimelineEvent[];
	doc: TimelineDocument;
	expandedLanes: ReadonlySet<LaneKind>;
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	orderedEntities: OrderedEntities;
	rowHidden: TimelineDocument["rowHidden"];
	laneHeight: number;
	interactionRows: readonly RowDescriptor[];
	eventHitIndex: EventHitIndex;
	disabledScrub: boolean;
	onSetView: (
		next: TimelineView | ((current: TimelineView) => TimelineView),
	) => void;
	onSeek: (t: number) => void;
	onScrubStart: () => void;
	onScrubEnd: () => void;
	onSelectEvent?: ((selection: StageSelection) => void) | undefined;
	onFocusEvent?: ((eventId: string | null) => void) | undefined;
	onMoveEvent?: ((move: MoveIntent) => void) | undefined;
	onMoveEntitySpan?: ((move: MoveSpanIntent) => void) | undefined;
	beginEdit?: ((label: string) => void) | undefined;
	endEdit?: (() => void) | undefined;
	onEditSelection: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
	toggleCategory?:
		| ((category: Exclude<LaneKind, "ruler">) => void)
		| undefined;
	cycleRowVisibility?:
		| ((category: Exclude<LaneKind, "ruler">, entityId: string) => void)
		| undefined;
	cycleCategoryVisibility?:
		| ((category: Exclude<LaneKind, "ruler">) => void)
		| undefined;
	commitRowReorder?:
		| ((
			category: Exclude<LaneKind, "ruler">,
			order: string[],
		) => void)
		| undefined;
};
