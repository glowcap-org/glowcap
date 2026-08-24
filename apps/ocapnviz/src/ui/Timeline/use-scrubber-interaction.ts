/** Cached document-shape snapshot for Scrubber pointer interaction. */

import { useMemo } from "react";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { buildEventHitIndex } from "./event-hit-index.ts";
import { iterateRows } from "./row-layout.ts";
import type { OrderedEntities } from "./scrubber-pointers/types.ts";
import type { LaneKind } from "./state.ts";

export function useScrubberInteraction(args: {
	doc: TimelineDocument;
	events: readonly TimelineEvent[];
	entities: TimelineDocument["entities"];
	expandedLanes: ReadonlySet<LaneKind>;
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	orderedEntities: OrderedEntities;
	rowHidden: TimelineDocument["rowHidden"];
	laneHeight: number;
}) {
	const interactionRows = useMemo(
		() => [...iterateRows(
			args.expandedLanes,
			args.expandedCategories,
			args.orderedEntities,
			args.rowHidden,
			args.laneHeight,
		)],
		[
			args.expandedLanes,
			args.expandedCategories,
			args.orderedEntities,
			args.rowHidden,
			args.laneHeight,
		],
	);
	const eventHitIndex = useMemo(
		() => buildEventHitIndex(args.doc, args.events),
		// Live appends may preserve the array identity. Entity-map identity and
		// event count are the shape inputs the index owns; effective times remain
		// live reads from `doc` during each hit.
		[args.doc, args.entities, args.events, args.events.length],
	);
	return { interactionRows, eventHitIndex };
}
