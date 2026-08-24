/**
 * How a Build-mode stage pointer becomes an engine intent or a selection.
 *
 * AppView owns the document, the tool, and the selection store. Stage reports
 * entity clicks, empty-canvas clicks, and node drags. This hook is the seam
 * between those: pan and Hand do not select, two-click tools advance through
 * `advanceTwoClick`, Add Peer / Open Session consume empty canvas, and a node
 * drag is one undo step.
 */

import { type Dispatch, useCallback } from "react";
import type { Engine } from "../engine/engine.ts";
import { asNodeRef } from "../interactions/gesture-resolver.ts";
import { isTwoClickTool, type SelectionAction } from "../interactions/types.ts";
import type { SelectMode, StageSelection } from "../render/types.ts";
import type { AppAction, AppMode, BuilderTool } from "../state/app-state.ts";
import type { ToolDraftStore } from "../ui/ToolOptionsBar.tsx";
import { advanceTwoClick, openSessionToNewEnd, twoClickAccepts } from "./two-click.ts";

export function useStageBuildGestures({
	engine,
	mode,
	tool,
	firstPickNodeId,
	spaceHeld,
	dispatch,
	dispatchSelection,
	onStoreSelect,
	toolDrafts,
}: {
	engine: Engine;
	mode: AppMode;
	tool: BuilderTool;
	firstPickNodeId: string | null;
	spaceHeld: boolean;
	dispatch: Dispatch<AppAction>;
	dispatchSelection: Dispatch<SelectionAction>;
	onStoreSelect: (
		selection: StageSelection,
		opts?: { mode?: SelectMode },
	) => void;
	toolDrafts: ToolDraftStore;
}): {
	handleSelect: (
		selection: StageSelection,
		opts?: { mode?: SelectMode },
	) => void;
	handleAddPeer: (worldX: number, worldY: number) => void;
	handleOpenSessionToNewEnd: (worldX: number, worldY: number) => void;
	handleNodeDrag: (
		kind: "peer" | "endpoint",
		nodeId: string,
		phase: "start" | "move" | "end",
		worldX: number,
		worldY: number,
		group?: ReadonlyArray<{
			kind: "peer" | "endpoint";
			id: string;
			x: number;
			y: number;
		}>,
	) => void;
} {
	const handleSelect = useCallback(
		(selection: StageSelection, opts?: { mode?: SelectMode }) => {
			// A pan affordance (space held, or the Hand tool) means
			// clicks mustn't change selection or advance a two-click
			// flow. Existing first-pick is preserved across the pan so
			// dropping the affordance puts the user back where they were.
			// (Sprites are already pointer-silent under a pan affordance;
			// this guard is the belt.)
			if (spaceHeld || tool === "hand") return;
			// In a two-click tool, only clicks on a stage NODE advance the flow —
			// a peer, or an end nothing has attributed, which Send Message can
			// name. A click on a message or a session is ignored rather than
			// treated as a flow-break: a message-in-flight resting at its sender at
			// t=0 occludes the peer underneath, so clicking "the peer" can actually
			// hit the message, and cancelling there would leave the user with a
			// stale armed first pick and no way to reach the second. Empty canvas
			// is not ignored under Open Session — `handleOpenSessionToNewEnd` runs
			// the session out to a new end standing where the click landed — and it
			// still clears the selection under every other tool. Escape cancels the
			// flow, switching tools cancels it, and re-clicking the armed node
			// cancels inside `advanceTwoClick`.
			const twoClickTool = mode === "build" && isTwoClickTool(tool) ? tool : null;
			if (twoClickTool !== null) {
				// Whether this tool takes this node is asked in one place, the same
				// one the cursor and the hover ring read. A refused node is inert
				// here: the pointer already read not-allowed on the way in, and a
				// click that armed it anyway would make the picture a liar.
				const node = asNodeRef(selection);
				if (
					node !== null &&
					twoClickAccepts(
							engine,
							twoClickTool,
							firstPickNodeId,
							node,
						) ===
						"takes"
				) {
					// Read at the click, never from a copy this callback
					// captured: the user picks the first peer, then edits a
					// field, then picks the second, and only the value in
					// front of them at that second click is the one they
					// meant.
					const drafts = toolDrafts.read();
					const parsedFlight = drafts.messageFlightMs.length > 0 ? Number(drafts.messageFlightMs) : NaN;
					advanceTwoClick(
						engine,
						twoClickTool,
						firstPickNodeId,
						node.id,
						dispatch,
						dispatchSelection,
						{
							codec: drafts.sessionCodec,
							captpVersion: drafts.sessionCaptpVersion,
							initialState: drafts.sessionInitialState,
							...(drafts.messageLabel.length > 0 ? { messageLabel: drafts.messageLabel } : {}),
							...(Number.isFinite(parsedFlight) ? { flightMs: parsedFlight } : {}),
						},
					);
				}
				return;
			}
			// Plain click replaces the selection with `[entity]`;
			// shift-click toggles in/out; empty click clears. The store's
			// `anchor` slot follows the latest entity, which is what the
			// Inspector reads.
			onStoreSelect(selection, opts);
		},
		[
			engine,
			mode,
			tool,
			firstPickNodeId,
			spaceHeld,
			dispatch,
			dispatchSelection,
			onStoreSelect,
			toolDrafts,
		],
	);

	// Builder mutations all flow through `engine.dispatch` so undo /
	// redo / future external-director piping has one funnel.
	const handleAddPeer = useCallback(
		(worldX: number, worldY: number) => {
			const drafts = toolDrafts.read();
			const typedId = drafts.peerId.trim();
			const typedLabel = drafts.peerLabel.trim();
			const newId = engine.dispatch({
				kind: "add-peer",
				profile: drafts.peerProfile,
				position: { x: worldX, y: worldY },
				...(typedId.length > 0 ? { id: typedId } : {}),
				...(typedLabel.length > 0 ? { label: typedLabel } : {}),
			});
			// On successful create with a user-typed id, clear the field
			// so the next drop doesn't double-fire the same id and trip
			// the collision check. (Empty → engine resumes peer-N
			// autogen on the next click.) Profile sticks because the
			// user often drops several of the same kind in a row.
			if (
				newId !== undefined &&
				(typedId.length > 0 || typedLabel.length > 0)
			) {
				toolDrafts.update({ peerId: "", peerLabel: "" });
			}
		},
		[engine, toolDrafts],
	);

	/** Second click of Open Session landing on empty canvas: run the session
	 *  out to an end nothing has attributed, standing where the click landed.
	 *  Only offered while a peer is armed, because a session needs somewhere
	 *  to run FROM; with nothing armed an empty click still clears. */
	const handleOpenSessionToNewEnd = useCallback(
		(worldX: number, worldY: number) => {
			const from = firstPickNodeId;
			if (from === null) return;
			const drafts = toolDrafts.read();
			openSessionToNewEnd(
				engine,
				from,
				{ x: worldX, y: worldY },
				dispatch,
				dispatchSelection,
				{
					codec: drafts.sessionCodec,
					captpVersion: drafts.sessionCaptpVersion,
					initialState: drafts.sessionInitialState,
				},
			);
		},
		[engine, firstPickNodeId, toolDrafts, dispatch, dispatchSelection],
	);

	// Node drag bracketed in an engine transaction so the many
	// pointermove snapshots collapse into a single undo step. A node is a
	// peer or a session end nothing has attributed; both take an authored
	// position. Multi-select arrives as one `group` and lands through
	// `repositionNodes` so the layout solves once per pointermove, not once
	// per selected node.
	const handleNodeDrag = useCallback(
		(
			kind: "peer" | "endpoint",
			nodeId: string,
			phase: "start" | "move" | "end",
			worldX: number,
			worldY: number,
			group?: ReadonlyArray<{
				kind: "peer" | "endpoint";
				id: string;
				x: number;
				y: number;
			}>,
		) => {
			if (phase === "end") {
				engine.endTransaction();
				return;
			}
			if (phase === "start") {
				engine.beginTransaction(
					group !== undefined && group.length > 1
						? "Move selection"
						: kind === "peer"
						? "Move peer"
						: "Move session end",
				);
			}
			const members = group ??
				[{ kind, id: nodeId, x: worldX, y: worldY }];
			engine.repositionNodes(
				members.map((m) => ({
					kind: m.kind,
					id: m.id,
					position: { x: m.x, y: m.y },
				})),
			);
		},
		[engine],
	);

	return {
		handleSelect,
		handleAddPeer,
		handleOpenSessionToNewEnd,
		handleNodeDrag,
	};
}
