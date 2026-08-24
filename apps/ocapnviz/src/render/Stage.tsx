import { useEffect, useRef } from "react";
import { Container } from "pixi.js";
import { Viewport } from "pixi-viewport";
import { layerInteractivity } from "../interactions/layer-interactivity.ts";
import { isTextInputTarget } from "../interactions/text-input-target.ts";
import { type EntityRefKey, type SurfaceGestureCtx } from "../interactions/types.ts";
import { useSurfaceWheel } from "../interactions/use-surface-wheel.ts";
import type { Engine } from "../engine/engine.ts";
import { type Theme } from "../ui/tokens.ts";
import { useUnifiedCanvas } from "./UnifiedCanvas.tsx";
import { useStageEmptyGestures } from "./use-stage-empty-gestures.ts";
import { useStageScene } from "./use-stage-scene.ts";
import { applyStageWheel } from "./stage-camera-commands.ts";

// Stage's pure data types live in `./types.ts` so consumers that only need a
// `StageSelection` shape don't drag in Pixi + React. Imported from there, not
// re-exported from here: a second door onto one type is a second name for it.
import { type SelectMode, type StageHover, type StageSelection, type StageVisibility } from "./types.ts";

/**
 * Stage scene — a sub-container of the unified PixiJS canvas, bound
 * to a DOM region marker for layout. The scene tracks the marker's
 * `getBoundingClientRect()` each frame via the `RegionRegistry`.
 *
 *   app.stage
 *   └── stageScene (positioned to marker rect, masked + cullable)
 *       └── Viewport (pixi-viewport: pan / pinch / wheel / decelerate)
 *           ├── gridLayer    (world-space dot grid, three LOD tiers, tiled)
 *           ├── edgeLayer
 *           ├── peerLayer
 *           ├── labelLayer
 *           └── messageLayer (drawn last so in-flight dots stay on top)
 *
 * Node-body drag lives in `stage-node-drag.ts`. Empty-stage rubber-band
 * and spacebar-pan live in `use-stage-empty-gestures.ts`. The Pixi scene
 * itself lives in `use-stage-scene.ts`; each frame is `stage-tick.ts`.
 */

export type StageProps = {
	engine: Engine;
	/** Click on a Stage entity (or `null` for empty stage). `opts.mode`
	 * carries the modifier-derived intent (see {@link SelectMode}).
	 * Defaulting to "replace" matches the no-modifier behavior. */
	onSelect?: (
		selection: StageSelection,
		opts?: { mode?: SelectMode },
	) => void;
	theme: Theme;
	visibility: StageVisibility;
	/**
	 * Fires on a click of empty viewport space. World-space coords
	 * (post-viewport-transform). When set, an empty-canvas click does
	 * NOT also call `onSelect(null)` — the assumption is the builder
	 * tool is consuming the click. The `| undefined` is for
	 * `exactOptionalPropertyTypes`: callers pass `cond ? fn : undefined`.
	 */
	onCanvasClick?: ((worldX: number, worldY: number) => void) | undefined;
	/**
	 * Node-body drag lifecycle, phases:
	 *   `"start"` — cursor world coords at pointerdown.
	 *   `"move"`  — target node position (cursor + pickup offset).
	 *   `"end"`   — last known target position.
	 *
	 * When set, node bodies become draggable; when undefined, they're
	 * click-only. A node is a peer or an unattributed session end: both
	 * hold a place on the stage and both take an authored position, and the
	 * `kind` says which table the host writes that position to.
	 *
	 * On `"start"` and `"move"`, `group` lists every node in the gesture
	 * (lead first, then multi-select siblings) at their target positions.
	 * The host applies the whole group in one placement pass; `"end"` has
	 * no group — it only closes the transaction.
	 */
	onNodeDrag?:
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
		| undefined;
	/** First-picked peer waiting for its partner in a two-click
	 * tool. Drives the node-editor "wire preview" overlay: a marching
	 * dashed ring on the armed peer and a dashed line from its edge
	 * to the cursor. `tool` colors the overlay (session vs message).
	 */
	armedNode?:
		| { nodeId: string; tool: "open-session" | "send-message" }
		| undefined;
	/** Single source of truth for the gesture pipeline: the resolver,
	 * the hover-halo preview, the canvas cursor, and layer
	 * pointer-events (interaction model § 7, via `layerInteractivity`)
	 * all read this. While `spaceHeld` is true or the active tool is
	 * `hand`, every sprite layer falls pointer-silent so the FSM's pan
	 * verbs receive the gesture.
	 *
	 * `modifiers` are the keys held right now, from the app's one
	 * keyboard listener rather than from a pointer event, because a
	 * modifier pressed while the pointer sits still still changes what
	 * the next click would do and the cursor has to say so. */
	gestureCtx: SurfaceGestureCtx;
	/** Called when the user finishes a rubber-band drag on empty
	 * stage. `entities` is the set of entity keys that overlapped
	 * the rect at drag-end; `mode` reflects the modifiers latched
	 * during the gesture:
	 *   "replace" — no modifier; replace selection.
	 *   "add"     — shift; add captured to selection.
	 *   "remove"  — shift+option; remove captured from selection.
	 * App routes to the selection-store. */
	onRubberBandCommit?: (
		entities: ReadonlySet<EntityRefKey>,
		mode: "replace" | "add" | "remove",
	) => void;
	/** THE selection — the set of entities (peers / sessions /
	 * messages) the user has selected. SOLE source of truth for
	 * which Stage entities paint their selected halo. Single-click
	 * on an entity replaces this set with `[that entity]`; shift-
	 * click toggles in/out; a marquee replaces (or shift-marquee
	 * unions). Inspector follows the store's `anchor` slot, which
	 * the same store reducer keeps consistent with this set. */
	selection?: ReadonlySet<EntityRefKey>;
	/** Anchor — the Inspector-follow entity, always also in
	 * `selection` when set. Stage paints an additional inner
	 * ring on the anchor's halo so the user can see WHICH
	 * selected entity the Inspector tracks under multi-select. */
	anchor?: EntityRefKey | null;
};

// Sprite shapes and their per-entity sync live in `./sprites/`; `renderFrame`
// in `./render-frame.ts` is the tick that calls them. Empty-stage gestures
// (rubber-band, spacebar-pan, empty clicks) live in `./use-stage-empty-gestures.ts`.
// Pure-data render types (`PeerActivity`, `StageSelection`) live in `./types.ts`.
// `use-stage-scene.ts` owns scene wiring (viewport, drag, layer creation).

/** Shared empty-set sentinel for the `selection` / `previewSelection`
 * refs so the no-selection case doesn't churn set identity. */
const EMPTY_ENTITY_SET: ReadonlySet<EntityRefKey> = new Set();

export function Stage(
	{
		engine,
		onSelect,
		theme,
		visibility,
		onCanvasClick,
		onNodeDrag,
		armedNode,
		gestureCtx,
		onRubberBandCommit,
		selection,
		anchor,
	}: StageProps,
) {
	const hostRef = useRef<HTMLDivElement | null>(null);
	// Refs let the long-lived Pixi ticker read current prop values
	// without remounting the scene each time a prop changes.
	const themeRef = useRef<Theme>(theme);
	themeRef.current = theme;
	// The view this document asks to open at, read once when the scene mounts.
	// Through a ref like everything else the scene effect needs: it must not be
	// an effect dependency, or saving a new opening view would tear the whole
	// Pixi scene down and rebuild it.
	const docInitialViewRef = useRef(engine.doc.initialView);
	docInitialViewRef.current = engine.doc.initialView;
	// Selection ref: the ticker reads the current set without
	// remounting the scene when it shifts. Entity-keyed so a single
	// ref serves all three sprite kinds (peer / session / message).
	const selectionRef = useRef<ReadonlySet<EntityRefKey>>(
		selection ?? EMPTY_ENTITY_SET,
	);
	selectionRef.current = selection ?? EMPTY_ENTITY_SET;
	// Anchor ref: same pattern as selectionRef. The per-tick paint
	// reads `.current` so anchor changes don't tear down the scene.
	const anchorRef = useRef<EntityRefKey | null>(anchor ?? null);
	anchorRef.current = anchor ?? null;
	const onCanvasClickRef = useRef(onCanvasClick);
	onCanvasClickRef.current = onCanvasClick;
	const onNodeDragRef = useRef(onNodeDrag);
	onNodeDragRef.current = onNodeDrag;
	// `onSelect` is held via ref so a fresh `handleSelect` closure
	// (which changes whenever App state.firstPickNodeId / tool /
	// mode changes) doesn't tear down and rebuild the Pixi scene.
	// Sprite pointer listeners read `onSelectRef.current` so they
	// always see the latest. Without this, the scene-init effect's
	// `[ctx, engine, onSelect]` deps cause a full rebuild on every
	// selection-state change — and pointer events landing during
	// the rebuild are silently dropped (loses two-click commits).
	const onSelectRef = useRef(onSelect);
	onSelectRef.current = onSelect;
	const visibilityRef = useRef<StageVisibility>(visibility);
	visibilityRef.current = visibility;
	// Captured from inside the scene-init effect so the smaller
	// panEnabled effect below can pause/resume the drag plugin
	// without depending on the heavy init.
	const viewportRef = useRef<Viewport | null>(null);
	const messageLayerRef = useRef<Container | null>(null);
	const edgeLayerRef = useRef<Container | null>(null);
	const peerLayerRef = useRef<Container | null>(null);
	const armedNodeRef = useRef(armedNode);
	armedNodeRef.current = armedNode;

	// Gesture context for the resolver, cursor, and node-drag — the ticker
	// and event handlers read the latest value without re-mounting.
	const resolvedGestureCtxRef = useRef<StageProps["gestureCtx"]>(gestureCtx);
	resolvedGestureCtxRef.current = gestureCtx;

	// The PixiJS canvas (shared with Timeline / Overview / Scrubber via
	// the unified-canvas architecture) is the real event target — the
	// Stage's marker div sits OVER it with `pointer-events: none` so
	// Pixi's sprite hit-testing works. Hooks attach to the canvas; a
	// marker-rect bounds check in `use-stage-empty-gestures` keeps stage-only
	// interactions from firing for events in the Timeline / Overview
	// regions of the same canvas.
	const unifiedCanvasCtx = useUnifiedCanvas();
	const canvas = (unifiedCanvasCtx?.app.canvas as HTMLCanvasElement | null) ??
		null;

	// Wheel pipeline (interaction model § 8.2). Replaces pixi-viewport's
	// `.wheel()` plugin. The hook fires a `WheelEffect` per wheel event
	// (zoom-step or pan-step); we apply it to the viewport in place.
	useSurfaceWheel(canvas, "stage-empty", "spatial", {
		onEffect: (effect) => {
			const viewport = viewportRef.current;
			if (!viewport) return;
			applyStageWheel(viewport, effect, hostRef.current, canvas);
		},
	});

	/**
	 * A press on the stage hands the keyboard back to the stage.
	 *
	 * The canvas is deliberately not focusable, and the stage's own pointer
	 * handling refuses the default that would move focus, so a click here does not
	 * blur whatever had it. That is right for a button — the reader keeps their
	 * shortcuts — and wrong for a TEXT FIELD, because every keyboard pipeline steps
	 * aside while one is focused (`isTextInputTarget`). A reader who typed a title,
	 * clicked the stage and pressed Space got a space in the title instead of a pan,
	 * and nothing on screen said why.
	 *
	 * Only a text surface is blurred. A focused button is left alone, since it
	 * swallows nothing and taking its focus would undo the ring a keyboard user is
	 * navigating by.
	 *
	 * Capture phase, because the stage's own handlers call `preventDefault` on the
	 * way down and this has to run before they do.
	 */
	useEffect(() => {
		if (!canvas) return;
		const handOverKeyboard = () => {
			const active = globalThis.document?.activeElement;
			if (isTextInputTarget(active)) (active as HTMLElement).blur();
		};
		canvas.addEventListener("pointerdown", handOverKeyboard, {
			capture: true,
		});
		return () =>
			canvas.removeEventListener("pointerdown", handOverKeyboard, {
				capture: true,
			});
	}, [canvas]);

	const {
		rubberBandOverlayRef,
		rubberBandRef,
		previewSelectionRef,
		machineRef,
		paintRubberBand,
	} = useStageEmptyGestures({
		canvas,
		hostRef,
		viewportRef,
		peerLayerRef,
		edgeLayerRef,
		messageLayerRef,
		engine,
		unifiedCanvasCtx,
		onCanvasClickRef,
		onSelectRef,
		onRubberBandCommit,
		gestureCtx,
	});

	// Ref (not state) — hover changes shouldn't re-reconcile React;
	// the Pixi ticker observes the change on its next paint.
	const hoverRef = useRef<StageHover>(null);

	// `null` until UnifiedCanvas finishes async init; the scene hook
	// re-runs once the context populates.
	const ctx = unifiedCanvasCtx;

	useStageScene({
		hostRef,
		engine,
		ctx,
		themeRef,
		docInitialViewRef,
		selectionRef,
		anchorRef,
		onSelectRef,
		onNodeDragRef,
		visibilityRef,
		viewportRef,
		messageLayerRef,
		edgeLayerRef,
		peerLayerRef,
		armedNodeRef,
		resolvedGestureCtxRef,
		rubberBandOverlayRef,
		rubberBandRef,
		previewSelectionRef,
		hoverRef,
		machineRef,
		paintRubberBand,
	});

	// pixi-viewport's drag plugin pauses cleanly; pinch / wheel /
	// decelerate stay live so trackpad zoom and momentum still work
	// when only mouse-drag pan is suppressed.
	// Layer-level event gating. Single source of truth: § 7 of the
	// interaction-model doc, encoded in `layerInteractivity(ctx)`.
	// Setting `eventMode` on the parent container cascades to every
	// current AND future child sprite, so one flip here governs
	// every peer / session / message in the lane at once.
	useEffect(() => {
		const peerLayer = peerLayerRef.current;
		const messageLayer = messageLayerRef.current;
		const edgeLayer = edgeLayerRef.current;
		const modes = layerInteractivity(gestureCtx);
		if (peerLayer) peerLayer.eventMode = modes.peers;
		if (messageLayer) messageLayer.eventMode = modes.messages;
		if (edgeLayer) edgeLayer.eventMode = modes.edges;
	}, [gestureCtx, ctx]);

	return (
		<div
			ref={hostRef}
			style={{
				width: "100%",
				height: "100%",
				position: "relative",
				// Marker is layout-only; PixiJS receives events on the
				// canvas behind it. `auto` would intercept and starve PixiJS.
				pointerEvents: "none",
			}}
		/>
	);
}
