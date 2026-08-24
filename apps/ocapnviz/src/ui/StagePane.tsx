/**
 * The stage slot: tool options, the Pixi stage, hints, and camera
 * controls.
 *
 * AppView owns the build gestures and the gesture context. This
 * module owns how those land on the stage — which click places a
 * peer, which drag moves a node, which tool paints the armed ring.
 */

import type { Engine } from "../engine/engine.ts";
import { armedNodeLabel } from "../builder/two-click.ts";
import type { EntityRefKey, SurfaceGestureCtx } from "../interactions/types.ts";
import { Stage } from "../render/Stage.tsx";
import type { SelectMode, StageSelection, StageVisibility } from "../render/types.ts";
import type { AppMode, BuilderTool } from "../state/app-state.ts";
import { centerPane, stageSlot } from "./app-shell.ts";
import { StageControls } from "./StageControls.tsx";
import { ToolHint } from "./ToolHint.tsx";
import { ToolDraftStore, ToolOptionsBar } from "./ToolOptionsBar.tsx";
import type { Theme } from "./tokens.ts";

export function StagePane({
	engine,
	mode,
	tool,
	firstPickNodeId,
	spaceHeld,
	theme,
	visibility,
	gestureCtx,
	selection,
	anchor,
	toolDrafts,
	onSelect,
	onAddPeer,
	onOpenSessionToNewEnd,
	onNodeDrag,
	onDeselect,
	onRubberBandCommit,
}: {
	engine: Engine;
	mode: AppMode;
	tool: BuilderTool;
	firstPickNodeId: string | null;
	spaceHeld: boolean;
	theme: Theme;
	visibility: StageVisibility;
	gestureCtx: SurfaceGestureCtx;
	selection: ReadonlySet<EntityRefKey>;
	anchor: StageSelection;
	toolDrafts: ToolDraftStore;
	onSelect: (sel: StageSelection, opts?: { mode?: SelectMode }) => void;
	onAddPeer: (worldX: number, worldY: number) => void;
	onOpenSessionToNewEnd: (worldX: number, worldY: number) => void;
	onNodeDrag: (
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
	onDeselect: () => void;
	onRubberBandCommit: (
		entities: ReadonlySet<EntityRefKey>,
		mode: "replace" | "add" | "remove",
	) => void;
}) {
	return (
		<section style={centerPane}>
			{
				/* Every mode gets the bar: it names the active tool and
          its gesture tip above the stage; the authoring option
          fields only exist for authoring tools, which only exist
          in Build. */
			}
			{engine && (
				<div style={{ pointerEvents: "auto" }}>
					<ToolOptionsBar
						tool={tool}
						engine={engine}
						drafts={toolDrafts}
						armedLabel={armedNodeLabel(engine, firstPickNodeId)}
						onCancelArmed={onDeselect}
					/>
				</div>
			)}
			<div style={stageSlot}>
				<Stage
					engine={engine}
					onSelect={onSelect}
					theme={theme}
					visibility={visibility}
					// An empty-canvas click means something to two tools. Add Peer
					// places one. Open Session, once a peer is armed, runs the
					// session out to an end nothing has attributed — the shape a
					// recording holds when a peer has dialed and nothing has yet
					// answered for who answered.
					onCanvasClick={mode !== "build" || spaceHeld
						? undefined
						: tool === "add-peer"
						? onAddPeer
						: tool === "open-session" && firstPickNodeId !== null
						? onOpenSessionToNewEnd
						: undefined}
					// Drag-to-reposition is a Select-tool gesture. With any
					// other build tool, a click that strays > 4px between
					// pointerdown and pointerup would otherwise convert into
					// a peer reposition, swallowing the two-click pick — a
					// surprisingly easy way to misfire when the cursor is
					// tracking marching ants. Keep peer drag scoped to Select.
					// Also gated on spacebar: hand-tool override beats peer
					// drag (Adobe convention), so a pan that starts on a peer
					// body actually pans the view instead of grabbing the
					// peer underneath.
					onNodeDrag={mode === "build" && tool === "select" &&
							!spaceHeld
						? onNodeDrag
						: undefined}
					armedNode={mode === "build" && firstPickNodeId &&
							(tool === "open-session" || tool === "send-message")
						? { nodeId: firstPickNodeId, tool }
						: undefined}
					// Single source for the resolver, the hover preview, the
					// canvas cursor, and layer pointer-events (§ 7): while a
					// pan affordance is active the whole stage goes
					// event-transparent so the FSM's pan verbs get the
					// pointerdown even on a peer body.
					//
					// The App's one gesture context — the Timeline's surfaces read
					// the same value, so the two agree by construction.
					gestureCtx={gestureCtx}
					selection={selection}
					anchor={anchor ? `${anchor.kind}:${anchor.id}` : null}
					onRubberBandCommit={onRubberBandCommit}
				/>
				{
					/* Every mode: the banner's pan notice follows Space,
            which pans over the stage everywhere; its two-click
            flow hints only speak for authoring tools, which only
            exist in Build. */
				}
				{engine && (
					<ToolHint
						tool={tool}
						armedNodeLabel={armedNodeLabel(engine, firstPickNodeId)}
						spaceHeld={spaceHeld}
					/>
				)}
				{
					/* Every mode: a camera is a camera whether the buffer came from a
            file, a recording, or the wire, and reading a crowded stage is
            exactly when Live wants a zoom out. Gated on `engine` only because
            with no buffer there is no stage to aim at. */
				}
				{engine && <StageControls />}
			</div>
		</section>
	);
}
