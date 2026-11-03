/** References shared between the React stage host and its persistent Pixi scene. */

import type { MutableRefObject, RefObject } from "react";
import type { Container, Graphics } from "pixi.js";
import type { Viewport } from "pixi-viewport";
import type { Engine } from "../engine/engine.ts";
import type { EntityRefKey } from "../interactions/entity-ref.ts";
import type { SurfaceGestureCtx } from "../interactions/gesture-resolver.ts";
import type { PointerMachineRef } from "../interactions/use-surface-pointer.ts";
import type { Theme } from "../ui/tokens.ts";
import type { SelectMode } from "../interactions/select-mode.ts";
import type { StageHover, StageSelection } from "./stage-selection.ts";
import type { StageVisibility } from "./stage-visibility.ts";
import type { UnifiedCanvasContextValue } from "./UnifiedCanvas.tsx";

export type StageSceneRefs = {
	hostRef: RefObject<HTMLDivElement | null>;
	engine: Engine;
	ctx: UnifiedCanvasContextValue | null;
	themeRef: MutableRefObject<Theme>;
	docInitialViewRef: MutableRefObject<
		{ zoom: number; center: { x: number; y: number } } | undefined
	>;
	selectionRef: MutableRefObject<ReadonlySet<EntityRefKey>>;
	anchorRef: MutableRefObject<EntityRefKey | null>;
	onSelectRef: MutableRefObject<
		| ((
			selection: StageSelection,
			opts?: { mode?: SelectMode },
		) => void)
		| undefined
	>;
	onNodeDragRef: MutableRefObject<
		| ((
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
		) => void)
		| undefined
	>;
	visibilityRef: MutableRefObject<StageVisibility>;
	viewportRef: MutableRefObject<Viewport | null>;
	messageLayerRef: MutableRefObject<Container | null>;
	edgeLayerRef: MutableRefObject<Container | null>;
	peerLayerRef: MutableRefObject<Container | null>;
	armedNodeRef: MutableRefObject<
		{ nodeId: string; tool: "open-session" | "send-message" } | undefined
	>;
	resolvedGestureCtxRef: MutableRefObject<SurfaceGestureCtx>;
	rubberBandOverlayRef: MutableRefObject<Graphics | null>;
	rubberBandRef: MutableRefObject<
		{ startX: number; startY: number; curX: number; curY: number } | null
	>;
	previewSelectionRef: MutableRefObject<ReadonlySet<EntityRefKey>>;
	hoverRef: MutableRefObject<StageHover>;
	machineRef: PointerMachineRef;
	paintRubberBand: () => void;
};
