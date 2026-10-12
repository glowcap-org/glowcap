/**
 * Mount the Pixi stage scene on the unified canvas and keep it alive.
 *
 * `Stage.tsx` is the React host: refs, wheel, empty-stage gestures, and
 * the marker div. This hook owns the scene graph, viewport, layers,
 * grid, camera port, node-drag, and the ticker that asks `tickStageFrame`
 * for each frame. Camera commands themselves live in
 * `stage-camera-commands.ts`.
 */

import { useEffect } from "react";
import { Container, Graphics, Rectangle } from "pixi.js";
import { Viewport } from "pixi-viewport";
import { type ToolWillPick } from "../interactions/cursor.ts";
import { nodeKindOf } from "../schema/session-end.ts";
import { type Hit, type PointerMachineState, stageHitFor } from "../interactions/types.ts";
import { EMPTY_FRAME_GEOMETRY } from "../engine/session-geometry.ts";
import { twoClickAccepts } from "../builder/two-click.ts";
import type { Theme } from "../ui/tokens.ts";
import { safeTick } from "./safeTick.ts";
import { type RenderFrameArgs } from "./render-frame.ts";
import { createStageNodeDrag } from "./stage-node-drag.ts";
import type { EdgeSprite, EndpointSprite, MessageSprite, PeerSprite } from "./sprites/types.ts";
import { EdgeStrokeBatch } from "./edge-stroke-batch.ts";
import { applyGridLod, paintGridTiers, WORLD_SIZE } from "./grid-lod.ts";
import { stageCamera } from "./stage-camera.ts";
import { runStageCameraCommand } from "./stage-camera-commands.ts";
import { type StageFrame, tickStageFrame } from "./stage-tick.ts";
import { initialStageView, MAX_STAGE_SCALE, MIN_STAGE_SCALE } from "./stage-view.ts";
import { themedColors } from "./palette.ts";
import { type PeerActivity, type SelectMode, type StageHover, type StageSelection } from "./types.ts";
import type { StageSceneRefs } from "./stage-scene-refs.ts";

export type { StageSceneRefs } from "./stage-scene-refs.ts";

export function useStageScene(args: StageSceneRefs): void {
	const {
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
	} = args;

	const stageHoverToHit = (h: StageHover): Hit | null => h === null ? null : stageHitFor(h);

	useEffect(() => {
		const host = hostRef.current;
		if (!host || !ctx) return;
		const { app, regions, setCursor } = ctx;

		const peerSprites = new Map<string, PeerSprite>();
		const endpointSprites = new Map<string, EndpointSprite>();
		const edgeSprites = new Map<string, EdgeSprite>();
		const messageSprites = new Map<string, MessageSprite>();
		// Per-tick scratch, owned here, reused each frame to avoid
		// per-frame Map/Set allocations in the hot path.
		const scratchActivity = new Map<string, PeerActivity>();
		const scratchPeerIds = new Set<string>();
		const scratchEndpointIds = new Set<string>();
		const scratchSessionIds = new Set<string>();
		const scratchMessageIds = new Set<string>();

		const cleanups: Array<() => void> = [];

		const stageScene = new Container();
		stageScene.eventMode = "static";
		stageScene.hitArea = new Rectangle(0, 0, 0, 0);
		// Cull handles fully-outside content (vertex work); the mask
		// clips partial-overlap content (edges across the boundary,
		// counter-scaled labels at low zoom) so it doesn't leak under
		// adjacent panels. Note: even for axis-aligned rects, Pixi v8.18
		// dispatches `container.mask` through `StencilMask` because no
		// `ScissorMaskPipe` is registered, scissor isn't an option.
		const stageMask = new Graphics();
		stageScene.addChild(stageMask);
		stageScene.mask = stageMask;
		app.stage.addChild(stageScene);

		{
			// Initial size from the host; the first region poll will sync
			// both position and size before the next paint.
			const initialW = host.clientWidth;
			const initialH = host.clientHeight;

			const viewport = new Viewport({
				screenWidth: initialW,
				screenHeight: initialH,
				worldWidth: WORLD_SIZE,
				worldHeight: WORLD_SIZE,
				events: app.renderer.events,
			});

			// Both `.drag()` (click-drag pan) and `.wheel()` are removed:
			// interaction-model § 4.5/8.2: click-drag on empty stage
			// = rubber-band selection (`use-stage-empty-gestures`); pan
			// requires Spacebar or the Hand tool; wheel = zoom (via
			// `useSurfaceWheel` above). `.pinch()` still handles touch
			// pinch-to-zoom; `.decelerate` is harmless without drag and
			// kept so a future re-introduction stays a one-line change.
			// `.clampZoom` constrains the zoom assigned by the wheel
			// handler, at both ends, and `render/stage-view.ts` argues each. It is the
			// same pair `clampStageZoom` holds, said to the plugin because the wheel
			// path assigns a scale through `setZoom` rather than through that function.
			viewport
				.pinch()
				.decelerate({ friction: 0.92 })
				.clampZoom({
					minScale: MIN_STAGE_SCALE,
					maxScale: MAX_STAGE_SCALE,
				});

			// Where this document asks to open. A document that stored nothing gets
			// the default, which is the middle of the world at 1:1.
			const opening = initialStageView(docInitialViewRef.current);
			viewport.setZoom(opening.zoom, true);
			viewport.moveCenter(opening.center.x, opening.center.y);
			stageScene.addChild(viewport);
			viewportRef.current = viewport;
			// The controls' end of `stage-camera.ts`. Every command lands on the
			// viewport here, because this is where the viewport is; the controls know
			// only the four things they can ask for.
			stageCamera.publishZoom(viewport.scale.x);
			cleanups.push(stageCamera.attach({
				view: () => ({
					zoom: viewport.scale.x,
					center: { x: viewport.center.x, y: viewport.center.y },
				}),
				run: (command) => {
					if (viewportRef.current !== viewport) return;
					runStageCameraCommand(
						viewport,
						[edgeLayer, peerLayer, messageLayer],
						command,
					);
				},
			}));
			// Test introspection: exposes the live viewport so probes
			// can convert peer world coords to screen coords without
			// re-implementing pixi-viewport's transform math.
			(globalThis as unknown as { __ocvViewport?: Viewport })
				.__ocvViewport = viewport;
			cleanups.push(() => {
				if (viewportRef.current === viewport) {
					viewportRef.current = null;
				}
			});

			// ── Affordance overlays ──────────────────────────────────
			//
			// Every non-interactive "what would happen / what's in
			// progress" graphic on the Stage lives under this header.
			// Two physical layers because the affordances split on
			// coordinate system:
			//
			//   `hostAffordanceLayer` (HOST coords, above viewport):
			//     rubber-band selection rect. Painted in screen pixels
			//     because the user drags screen pixels, converting
			//     to world coords would jitter the rect at zoom != 1.
			//
			//   `worldAffordanceLayer` (WORLD coords, inside viewport):
			//     armed-peer ring + wire preview. Painted in world
			//     coords because they anchor to peer positions which
			//     live in world space, re-anchoring per frame would
			//     duplicate viewport math the viewport already does.
			//
			// Both have `eventMode="none"` so they never intercept
			// pointer events; the FSM and per-sprite handlers own all
			// interaction. New affordance graphics (Adobe Pen tool
			// preview, alignment guides, …) belong here too.
			const hostAffordanceLayer = new Container();
			hostAffordanceLayer.eventMode = "none";
			const rubberBandOverlay = new Graphics();
			rubberBandOverlay.eventMode = "none";
			hostAffordanceLayer.addChild(rubberBandOverlay);
			stageScene.addChild(hostAffordanceLayer);
			rubberBandOverlayRef.current = rubberBandOverlay;
			cleanups.push(() => {
				if (rubberBandOverlayRef.current === rubberBandOverlay) {
					rubberBandOverlayRef.current = null;
				}
			});

			const cursorWorld = { x: 0, y: 0, hasValue: false };
			const { startNodeDrag, abortDrag } = createStageNodeDrag({
				app,
				engine,
				viewport,
				peerSprites,
				selectionRef,
				hoverRef,
				onSelectRef,
				onNodeDragRef,
				resolvedGestureCtxRef,
				cursor: cursorWorld,
				cleanups,
			});

			// Viewport stays interactive for the peer-drag handlers above
			// (`globalpointermove`, `pointerup*`). Click-on-empty-stage
			// (Add Peer placement / deselect) does not use
			// `viewport.on("clicked")`. With `.drag()` removed the FSM
			// owns that path: `use-stage-empty-gestures` emits
			// `click(rubber-band)` for no-drag pointerups on empty
			// stage, which it routes to onCanvasClick
			// or onSelect(null).
			viewport.eventMode = "static";

			// Three LOD tiers, each a Container of tile Graphics built
			// by `populateGridLOD`. Per-LOD alpha cascades from the
			// container; tiles cull individually against the marker rect.
			const gridLayer = new Container();
			const gridCoarse = new Container();
			const gridMedium = new Container();
			const gridFine = new Container();
			gridLayer.addChild(gridCoarse, gridMedium, gridFine);

			const edgeLayer = new Container();
			const edgeStrokeBatch = new EdgeStrokeBatch();
			edgeLayer.addChild(edgeStrokeBatch.gfx);
			const peerLayer = new Container();
			const messageLayer = new Container();
			// `labelLayer` is a parent container holding three per-
			// category sublayers. The split is so the label z-order
			// mirrors the entity z-order: peer labels at the bottom,
			// session labels in the middle, message labels on top.
			// Without the split, message labels could be drawn UNDER
			// peer labels even though message dots draw above peer
			// bodies, visually confusing. Each sublayer keeps its
			// own per-entity zIndex ordering inside its category.
			//
			// Labels are pure decoration, they overlap peer bodies
			// and session edges and would otherwise consume hit-tests
			// (rubber-band marquee would refuse to start over a label
			// rect). `eventMode: "none"` on the parent cascades to
			// every child label container + Text + Graphics.
			const labelLayer = new Container();
			labelLayer.eventMode = "none";
			const peerLabelLayer = new Container();
			const sessionLabelLayer = new Container();
			const messageLabelLayer = new Container();
			labelLayer.addChild(
				peerLabelLayer,
				sessionLabelLayer,
				messageLabelLayer,
			);
			// Per-entity z-ordering, Adobe / Flash convention: top of
			// the Timeline gutter row = on top of the Stage canvas.
			// `renderFrame` reads `doc.rowOrder` each frame and assigns
			// sprite.zIndex; Pixi's sortableChildren sort runs lazily
			// only when zIndex changes. Each label sublayer
			// sorts its own siblings; cross-category order comes from
			// the parent `labelLayer`'s addChild order above.
			edgeLayer.sortableChildren = true;
			peerLayer.sortableChildren = true;
			messageLayer.sortableChildren = true;
			peerLabelLayer.sortableChildren = true;
			sessionLabelLayer.sortableChildren = true;
			messageLabelLayer.sortableChildren = true;
			// Persistent refs so the small layer-eventMode effect below
			// can flip whole layers without depending on the heavy
			// scene-init. `peerLayerRef` enables the hand-tool override
			// (spaceHeld) to disable peer interaction outright, the
			// peer body's `pointerdown` stops propagation to claim its
			// own drag, so without this the viewport never sees the
			// event for pan when a gesture starts on a peer.
			messageLayerRef.current = messageLayer;
			edgeLayerRef.current = edgeLayer;
			peerLayerRef.current = peerLayer;
			cleanups.push(() => {
				if (messageLayerRef.current === messageLayer) {
					messageLayerRef.current = null;
				}
				if (edgeLayerRef.current === edgeLayer) {
					edgeLayerRef.current = null;
				}
				if (peerLayerRef.current === peerLayer) {
					peerLayerRef.current = null;
				}
				edgeStrokeBatch.destroy();
			});
			// Sprite-hit detection lives in `use-stage-empty-gestures`, which
			// consults Pixi's own hit-test (`rootBoundary.hitTest`), the
			// same logic Pixi uses internally to route pointer events.
			// No layer-level listeners needed: peer sprites stop
			// propagation to claim peer-drag, so a layer-level handler
			// would never see them anyway.
			// World-coord affordance layer (see "Affordance overlays"
			// block above): two-click tool feedback, the armed-peer
			// marching-ants ring + the wire preview from armed peer to
			// cursor. Sits above messages so the wire reads on top of
			// in-flight dots (it's the user's active focus); below
			// labels so peer names stay legible. Empty when no two-click
			// tool is active.
			const worldAffordanceLayer = new Container();
			worldAffordanceLayer.eventMode = "none";
			const armedRingGfx = new Graphics();
			armedRingGfx.eventMode = "none";
			const wirePreviewGfx = new Graphics();
			wirePreviewGfx.eventMode = "none";
			// The end the wire would land on if the click happened here: Open
			// Session run out to nobody. Drawn as the very shape the click makes,
			// through the same helper the real one is painted with, so the preview
			// cannot promise a body the stage would not draw. Positioned at the
			// cursor rather than drawn there, because the helper centers its shape
			// on its own origin.
			const ghostEndGfx = new Graphics();
			ghostEndGfx.eventMode = "none";
			worldAffordanceLayer.addChild(
				armedRingGfx,
				wirePreviewGfx,
				ghostEndGfx,
			);
			// Back-to-front; messages last so in-flight dots stay on top.
			viewport.addChild(
				gridLayer,
				edgeLayer,
				peerLayer,
				messageLayer,
				worldAffordanceLayer,
				labelLayer,
			);

			const gridLayers = [gridFine, gridMedium, gridCoarse] as const;
			const drawGrid = (theme: Theme) => {
				paintGridTiers(gridLayers, themedColors(theme).text);
			};
			drawGrid(themeRef.current);
			const updateGridLod = () => applyGridLod(gridLayers, viewport.scale.x);
			updateGridLod();

			// Region sync. Each frame the registry polls the marker rect;
			// when it changes we reposition the scene, resize the viewport,
			// and redraw the mask. Recenter on the world point that was
			// under the canvas center so panel drags don't
			// strand content. No `renderer.resize`. The unified canvas
			// owns the canvas, only this scene's sub-region changes.
			let lastSyncedW = 0;
			let lastSyncedH = 0;
			// View rect for the per-frame culler. Marker rect from the
			// region poll; default to full screen so frames before the
			// first poll don't cull everything.
			const cullView = new Rectangle(
				0,
				0,
				app.renderer.screen.width,
				app.renderer.screen.height,
			);
			const handleRegionRect = (
				rect: { x: number; y: number; width: number; height: number },
			) => {
				stageScene.position.set(rect.x, rect.y);
				stageScene.hitArea = new Rectangle(
					0,
					0,
					rect.width,
					rect.height,
				);
				cullView.x = rect.x;
				cullView.y = rect.y;
				cullView.width = rect.width;
				cullView.height = rect.height;
				if (rect.width !== lastSyncedW || rect.height !== lastSyncedH) {
					stageMask
						.clear()
						.rect(0, 0, rect.width, rect.height)
						.fill(0xffffff);
					// Bail any in-flight drag cleanly, world coords survive
					// a resize but the gesture's bookkeeping is brittle.
					// Use the bound handler captured at drag-start, not the
					// current ref, so a region-rect change concurrent with
					// a prop swap still closes the right transaction.
					abortDrag();
					if (rect.width > 0 && rect.height > 0) {
						const prevCenter = viewport.center;
						viewport.resize(rect.width, rect.height);
						viewport.moveCenter(prevCenter.x, prevCenter.y);
					}
					lastSyncedW = rect.width;
					lastSyncedH = rect.height;
				}
			};
			cleanups.push(regions.register("stage", host));
			cleanups.push(regions.subscribe("stage", handleRegionRect));

			// Cursor in viewport-world coords. Drives the wire-preview
			// overlay; the wire's tail end follows the cursor each tick.
			// Null until first pointermove (no overlay drawn until then).
			// `createStageNodeDrag` already allocated `cursorWorld` so a
			// captured drag can keep the preview tail moving.
			const onViewportPointerMove = (
				e: { global: { x: number; y: number } },
			) => {
				const local = viewport.toWorld(e.global.x, e.global.y);
				cursorWorld.x = local.x;
				cursorWorld.y = local.y;
				cursorWorld.hasValue = true;
			};
			// Viewport's `eventMode` was set "static" up top for the
			// drag handlers; just attach the cursor-tracking listener.
			viewport.on("pointermove", onViewportPointerMove);
			cleanups.push(() => viewport.off("pointermove", onViewportPointerMove));

			// Hover set/clear closed over `hoverRef`. `leaveHover` only
			// clears if WE are the recorded hover, avoids the race where
			// the new sibling's `pointerover` fires before the old one's
			// `pointerout` and the clear wipes the new hover.
			const enterHover = (h: StageHover) => {
				hoverRef.current = h;
			};
			const leaveHover = (
				kind: NonNullable<StageHover>["kind"],
				id: string,
			) => {
				const cur = hoverRef.current;
				if (cur && cur.kind === kind && cur.id === id) {
					hoverRef.current = null;
				}
			};

			/**
			 * Whether a two-click tool will take the node it is about to pick.
			 * `cursorFor` is pure over the gesture context and this is a fact about
			 * the document, so the cursor asks for it. The answer comes from the
			 * same `twoClickAccepts` the click path consults.
			 */
			const willPick: ToolWillPick = ({ tool, armedNodeId, nodeId }) =>
				twoClickAccepts(engine, tool, armedNodeId, {
					kind: nodeKindOf(nodeId),
					id: nodeId,
				}) === "takes";

			/**
			 * What the cursor asks about: the FSM's state, with the sprite hovers
			 * the FSM never sees folded in.
			 *
			 * The empty-stage hit producer returns null over a sprite so the
			 * FSM stays out of the gesture the sprite's own listeners take,
			 * which leaves `machine.hover` empty in exactly the places the
			 * pointer is over something. The Pixi hover is that same fact
			 * arriving by the other door, so the cursor reads both and prefers
			 * the nearer one.
			 */
			const cursorMachine = (): PointerMachineState => {
				const machine = machineRef.current;
				const spriteHit = stageHoverToHit(hoverRef.current);
				if (spriteHit === null) return machine;
				return {
					...machine,
					hover: { surface: spriteHit.surface, hit: spriteHit },
				};
			};

			// Stable args object, mutated each tick rather than
			// allocated, since `renderFrame` runs at 60 Hz. The
			// `selection` / `hover` / `colors` / `scale` / `counterScale`
			// fields are the only ones that change frame to frame.
			// Stable wrapper around the always-fresh `onSelectRef`.
			// Sprite listeners capture this once at sprite creation but
			// it dispatches through the ref, so React state updates in
			// App.handleSelect (e.g. firstPickNodeId churn during the
			// two-click tool flow) reach the listeners without needing
			// to rebuild the Pixi scene.
			const onSelectStable = (
				sel: StageSelection,
				opts?: { mode?: SelectMode },
			) => onSelectRef.current?.(sel, opts);
			const renderArgs: RenderFrameArgs = {
				engine,
				edgeLayer,
				peerLayer,
				messageLayer,
				peerLabelLayer,
				sessionLabelLayer,
				messageLabelLayer,
				peerSprites,
				endpointSprites,
				edgeSprites,
				edgeStrokeBatch,
				messageSprites,
				onSelect: onSelectStable,
				selection: selectionRef.current,
				anchor: anchorRef.current,
				previewSelection: previewSelectionRef.current,
				hover: hoverRef.current,
				enterHover,
				leaveHover,
				colors: themedColors(themeRef.current),
				counterScale: 1,
				scale: 1,
				startNodeDrag,
				claimsToward: EMPTY_FRAME_GEOMETRY.claimsToward,
				sessionCurves: EMPTY_FRAME_GEOMETRY.sessionCurves,
				scratchActivity,
				scratchPeerIds,
				scratchEndpointIds,
				scratchSessionIds,
				scratchMessageIds,
			};
			const frame: StageFrame = {
				lastWall: performance.now(),
				lastDrawnTheme: themeRef.current,
				marchOffsetPx: 0,
				overlayDirty: false,
				engine,
				viewport,
				stageScene,
				cullView,
				peerLayer,
				edgeLayer,
				messageLayer,
				labelLayer,
				themeRef,
				visibilityRef,
				selectionRef,
				anchorRef,
				previewSelectionRef,
				hoverRef,
				armedNodeRef,
				resolvedGestureCtxRef,
				rubberBandRef,
				setCursor,
				paintRubberBand,
				drawGrid,
				updateGridLod,
				renderArgs,
				stageHoverToHit,
				willPick,
				cursorMachine,
				armedRingGfx,
				wirePreviewGfx,
				ghostEndGfx,
				cursorWorld,
			};
			// Named so we can remove it on cleanup. The ticker outlives
			// this effect (it's the unified canvas's long-lived
			// Application); a leaked callback writes into destroyed
			// layers and can wedge the renderer.
			const tickCb = () => tickStageFrame(frame);
			const safeTickCb = safeTick(tickCb);
			app.ticker.add(safeTickCb);
			cleanups.push(() => app.ticker?.remove(safeTickCb));
		}

		return () => {
			for (const fn of cleanups) fn();
			// The scene that answered for the cursor is going away, so hand the
			// element back the plain arrow rather than leaving the last frame's
			// answer stamped on a canvas nothing is deriving one for.
			setCursor("default");
			app.stage?.removeChild(stageScene);
			if (!stageScene.destroyed) stageScene.destroy({ children: true });
		};
		// `onSelect` is NOT in this dep array, it's
		// read via `onSelectRef` so the entire Pixi scene doesn't
		// rebuild every time App.handleSelect's identity changes.
	}, [ctx, engine]);
}
