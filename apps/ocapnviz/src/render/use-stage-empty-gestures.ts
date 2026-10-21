/**
 * Empty-stage gestures: rubber-band selection and spacebar-pan.
 *
 * `Stage.tsx` is the React host. `use-stage-scene.ts` owns the Pixi scene.
 * This hook owns the host-level pointer
 * adapter that runs on empty stage. The FSM hit producer, the marquee,
 * and the effects that pan or click the world. Sprite hits keep their
 * own Pixi listeners (`createStageNodeDrag` + onSelect).
 */

import { type MutableRefObject, type RefObject, useRef } from "react";
import { type Container, type Graphics, Point } from "pixi.js";
import type { Viewport } from "pixi-viewport";
import {
	type Effect,
	entityKey,
	type EntityRefKey,
	type Hit,
	type ResolvedGesture,
	type SurfaceGestureCtx,
} from "../interactions/types.ts";
import { type PointerMachineRef, useSurfacePointer } from "../interactions/use-surface-pointer.ts";
import { nodeKindOf } from "../schema/session-end.ts";
import type { Engine } from "../engine/engine.ts";
import { findNode } from "../engine/world.ts";
import { NODE_RADIUS } from "./draw-helpers.ts";
import { endpointBodyRadius } from "./sprites/endpoint.ts";
import { MESSAGE_RADIUS } from "./sprites/message.ts";
import {
	clampRectToBounds,
	paintMarchingAntsBand,
	rectCircleOverlap,
	rectFromCorners,
	rectSegmentOverlap,
} from "./geometry.ts";
import { type SelectMode, selectModeFromModifiers, type StageSelection } from "./types.ts";
import type { UnifiedCanvasContextValue } from "./UnifiedCanvas.tsx";

/** Shared empty-set sentinel so a cleared preview does not churn set identity. */
const EMPTY_ENTITY_SET: ReadonlySet<EntityRefKey> = new Set();

export type StageEmptyGestures = {
	rubberBandOverlayRef: MutableRefObject<Graphics | null>;
	rubberBandRef: MutableRefObject<
		{ startX: number; startY: number; curX: number; curY: number } | null
	>;
	previewSelectionRef: MutableRefObject<ReadonlySet<EntityRefKey>>;
	machineRef: PointerMachineRef;
	paintRubberBand: () => void;
};

export function useStageEmptyGestures(args: {
	canvas: HTMLCanvasElement | null;
	hostRef: RefObject<HTMLDivElement | null>;
	viewportRef: MutableRefObject<Viewport | null>;
	peerLayerRef: MutableRefObject<Container | null>;
	edgeLayerRef: MutableRefObject<Container | null>;
	messageLayerRef: MutableRefObject<Container | null>;
	engine: Engine;
	unifiedCanvasCtx: UnifiedCanvasContextValue | null;
	onCanvasClickRef: MutableRefObject<
		((worldX: number, worldY: number) => void) | undefined
	>;
	onSelectRef: MutableRefObject<
		| ((
			selection: StageSelection,
			opts?: { mode?: SelectMode },
		) => void)
		| undefined
	>;
	onRubberBandCommit:
		| ((
			entities: ReadonlySet<EntityRefKey>,
			mode: "replace" | "add" | "remove",
		) => void)
		| undefined;
	gestureCtx: SurfaceGestureCtx;
}): StageEmptyGestures {
	const {
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
	} = args;

	// Preview-selection: while a rubber-band drag is in flight, entities
	// inside the marquee paint a hover-like ring. Stored separately
	// from the committed selection because the commit only lands on drag-end.
	const previewSelectionRef = useRef<ReadonlySet<EntityRefKey>>(
		EMPTY_ENTITY_SET,
	);

	// ─── Empty-stage gestures (interaction model § 8.1) ────────────────
	//
	// The host-level pointer adapter handles rubber-band selection and
	// spacebar-pan; sprite hits keep firing their own Pixi listeners
	// (peer-drag + onSelect). `makeStageHit` consults Pixi's own
	// hit-test (see below) so the FSM doesn't double-fire for sprite
	// clicks, that's the single source of truth for "did this click
	// land on an interactive sprite".
	//
	// Rubber-band rect bounds in host coords; null when no band-drag is
	// in flight. Painted into `rubberBandOverlayRef`.
	const rubberBandRef = useRef<
		| { startX: number; startY: number; curX: number; curY: number }
		| null
	>(null);
	const rubberBandOverlayRef = useRef<Graphics | null>(null);
	const onRubberBandCommitRef = useRef(onRubberBandCommit);
	onRubberBandCommitRef.current = onRubberBandCommit;

	// Producer for the host-level FSM. Returns `null` when:
	//   - the event is outside the Stage's marker region (events on
	//     the same canvas in Timeline / Overview area), or
	//   - the click landed on an interactive Pixi sprite under one
	//     of our layers (so the FSM stays out, the sprite's own
	//     click / drag handler takes the gesture).
	// Otherwise returns `stage-empty`.
	//
	// We use Pixi's own hit-test (`rootBoundary.hitTest`) instead
	// of trying to observe bubbled pointerdowns at the layer level:
	// peer sprites `stopPropagation` to claim peer-drag, so the
	// layer never sees the event. Pixi's hit-test runs the same
	// logic Pixi uses internally to decide which sprite to dispatch
	// to, so it's the single source of truth for "is the click on
	// an interactive sprite".
	const scratchHitPoint = useRef(new Point(0, 0));
	const makeStageHit = (
		ev: { clientX: number; clientY: number; target: EventTarget | null },
	): (Hit & { surface: "stage-empty" }) | null => {
		const host = hostRef.current;
		if (host) {
			const r = host.getBoundingClientRect();
			if (
				ev.clientX < r.left || ev.clientX > r.right ||
				ev.clientY < r.top || ev.clientY > r.bottom
			) {
				return null;
			}
		}
		const app = unifiedCanvasCtx?.app;
		if (app && canvas) {
			const c = canvas.getBoundingClientRect();
			const p = scratchHitPoint.current;
			p.set(ev.clientX - c.left, ev.clientY - c.top);
			const target = app.renderer.events.rootBoundary.hitTest(p.x, p.y);
			if (isInteractiveSpriteHit(target)) return null;
		}
		return { surface: "stage-empty" };
	};

	// Walk up from a hit-test result to one of our interactive
	// entity layers. The viewport itself (and its non-interactive
	// children, grid, labels, overlay) doesn't count as a sprite
	// hit; only peer / edge / message sprites do.
	const isInteractiveSpriteHit = (target: Container | null): boolean => {
		if (!target) return false;
		let cur: Container | null = target;
		while (cur) {
			if (
				cur === peerLayerRef.current ||
				cur === edgeLayerRef.current ||
				cur === messageLayerRef.current
			) {
				return true;
			}
			cur = cur.parent;
		}
		return false;
	};

	// Convert a DOM client coord to viewport-world coords.
	//
	// `viewport.toWorld` delegates to PixiJS's `toLocal`, which
	// accepts a GLOBAL (canvas-local) point and walks the parent
	// chain, including `stageScene.position` (the sidebar/topbar
	// offset). The unified canvas is `position: fixed; inset: 0`,
	// so DOM clientX/Y already equals pixi global. Subtracting
	// `host.rect.left/top` here would double-subtract that offset
	// and place every world coord too far up-left by the
	// sidebar/topbar size, exactly the Add-Peer-lands-offset bug.
	const clientToWorld = (
		clientX: number,
		clientY: number,
	): { x: number; y: number } | null => {
		const viewport = viewportRef.current;
		if (!viewport) return null;
		const world = viewport.toWorld(clientX, clientY);
		return { x: world.x, y: world.y };
	};

	// Paint (or clear) the rubber-band overlay based on `rubberBandRef`.
	//
	// Marching-ants: 1px alternating fg/bg pixels around the rect
	// perimeter, with a `phase` offset advanced by the Pixi ticker so
	// the ants "march". The pattern is the perimeter analogue of the
	// ghost-playhead column (`ghostPlayhead.ts`): contrast survives
	// any background because half the pixels disagree with it, and
	// the 1-px scale reads as "tool affordance" rather than "marker".
	const paintRubberBand = () => {
		const overlay = rubberBandOverlayRef.current;
		if (!overlay) return;
		overlay.clear();
		const band = rubberBandRef.current;
		if (!band) return;
		const host = hostRef.current;
		if (!host) return;
		const rect = host.getBoundingClientRect();
		// Clamp the visible band to the Stage host bounds. The unified
		// pixi canvas spans the viewport with this overlay unmasked, so
		// an unclamped rect can bleed into sibling panels (Timeline,
		// Sidebar) when the pointer drags off the Stage region. Commit
		// (`entitiesInBand`) clamps to the same bounds so what you see
		// is what you select. Shared helper with the Scrubber marquee:
		// both surfaces define their own bounds and call
		// `clampRectToBounds`.
		const raw = rectFromCorners(
			band.startX - rect.left,
			band.startY - rect.top,
			band.curX - rect.left,
			band.curY - rect.top,
		);
		const clamped = clampRectToBounds(raw, {
			minX: 0,
			minY: 0,
			maxX: rect.width,
			maxY: rect.height,
		});
		paintMarchingAntsBand(
			overlay,
			Math.round(clamped.x),
			Math.round(clamped.y),
			Math.round(clamped.width),
			Math.round(clamped.height),
		);
	};

	// Latched modifier state for the in-flight rubber-band drag.
	// Each modifier is set the moment it's pressed during the
	// gesture and remains set for the rest of the drag (a brief
	// release doesn't flip the commit mode mid-stride). Photoshop /
	// Illustrator commit mode at drag-end:
	//   shift              → add captured to selection
	//   shift + option     → remove captured from selection
	//   neither            → replace selection with captured
	//   option alone       → reserved (no marquee meaning yet) status-allow: pending state or quoted runtime label
	const rubberBandModRef = useRef<{ shift: boolean; alt: boolean }>({
		shift: false,
		alt: false,
	});

	// Compute the set of entities (peers, sessions, messages) whose
	// visual bounds OVERLAP the current marquee rect (Adobe /
	// Figma convention: any pixel of the entity's visual shape
	// intersecting the rect counts). Used both for the live preview
	// (drag-move) and the commit (drag-end).
	//
	// Per entity kind:
	//   - peer:    bounding circle of radius NODE_RADIUS (screen-px)
	//              vs. rect, closest-point-on-rect-to-circle test.
	//   - endpoint: the same test at the radius that end is
	//              painted at (`endpointBodyRadius`), a claim is half a
	//              node wide, and measuring it as a peer would sweep in
	//              claims the marquee never visibly touched.
	//   - session: line segment between endpoint peers (screen-px)
	//              vs. rect, endpoint-in-rect OR segment crosses
	//              any of the four edges. Arced sessions are
	//              approximated as a straight segment; the user
	//              gets the same "did I touch this wire" answer.
	//   - message: small bounding circle (MESSAGE_RADIUS, screen-px)
	//              at the in-flight position vs. rect.
	//
	// Coordinate frame: band start/cur are DOM clientX/Y (== pixi
	// global, since canvas is `position: fixed; inset: 0`).
	// `viewport.toScreen` returns global too. Radii scale with
	// viewport zoom (NODE_RADIUS is in world units; multiply by
	// viewport.scale.x for screen-px).
	const entitiesInBand = (): Set<EntityRefKey> => {
		const band = rubberBandRef.current;
		const out = new Set<EntityRefKey>();
		if (!band) return out;
		const viewport = viewportRef.current;
		if (!viewport) return out;
		// Clamp the selection rect to the Stage host's client-space
		// bounds, same clamp the visible marquee paints with, so the
		// committed selection matches what the user saw. `band.startX/Y`
		// and `viewport.toScreen(...)` both live in client/global coords
		// (canvas is fixed/full-viewport); the host rect translates the
		// Stage region's edges into that same space.
		// Mirror paintRubberBand's hard guard, without a host rect we
		// can't clamp to the visible region, so selecting "the
		// unclamped raw band" would silently commit entities the user
		// never saw highlighted. Better to commit nothing.
		const host = hostRef.current;
		if (!host) return out;
		const hostRect = host.getBoundingClientRect();
		const clamped = clampRectToBounds(
			rectFromCorners(band.startX, band.startY, band.curX, band.curY),
			{
				minX: hostRect.left,
				minY: hostRect.top,
				maxX: hostRect.right,
				maxY: hostRect.bottom,
			},
		);
		const x0 = clamped.x;
		const x1 = clamped.x + clamped.width;
		const y0 = clamped.y;
		const y1 = clamped.y + clamped.height;
		const zoom = viewport.scale.x;
		const peerR = NODE_RADIUS * zoom;
		const msgR = MESSAGE_RADIUS * zoom;
		for (const peer of engine.queries.peers) {
			const pos = peer.position;
			if (!pos) continue;
			const s = viewport.toScreen(pos.x, pos.y);
			if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, peerR)) {
				out.add(entityKey({ kind: "peer", id: peer.peer.id }));
			}
		}
		// The same resolution the renderer draws these ends with, so the shape
		// the marquee measures is the shape the user saw.
		const claimsToward = engine.frameGeometry.claimsToward;
		for (const e of engine.queries.endpoints) {
			const s = viewport.toScreen(e.position.x, e.position.y);
			const r = endpointBodyRadius(e.endpoint.id, claimsToward) * zoom;
			if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, r)) {
				out.add(entityKey({ kind: "endpoint", id: e.endpoint.id }));
			}
		}
		for (const sess of engine.queries.sessions) {
			// `findNode`: an end the marquee has to reach may be a loose claim
			// rather than a peer, and a peer-only lookup skipped the whole edge.
			const a = findNode(engine.world, sess.endpoints.a);
			const b = findNode(engine.world, sess.endpoints.b);
			if (!a?.position || !b?.position) continue;
			const sa = viewport.toScreen(a.position.x, a.position.y);
			const sb = viewport.toScreen(b.position.x, b.position.y);
			if (rectSegmentOverlap(x0, y0, x1, y1, sa.x, sa.y, sb.x, sb.y)) {
				out.add(entityKey({ kind: "session", id: sess.session.id }));
			}
		}
		for (const m of engine.queries.messagesInFlight) {
			const pos = m.position;
			if (!pos) continue;
			const s = viewport.toScreen(pos.x, pos.y);
			if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, msgR)) {
				out.add(
					entityKey({ kind: "message", id: m.messageInFlight.id }),
				);
			}
		}
		return out;
	};

	const commitRubberBand = () => {
		const out = entitiesInBand();
		const m = rubberBandModRef.current;
		const mode: "replace" | "add" | "remove" = m.shift && m.alt ? "remove" : m.shift ? "add" : "replace";
		onRubberBandCommitRef.current?.(out, mode);
	};

	// The FSM's effect handler. Routes by `effect.kind` (and the
	// resolved verb's tier for clicks / drags). The FSM is per-host
	// (one instance lives inside `useSurfacePointer`); we just react
	// to the effects it emits.
	//
	// Two verb-tier "modes" of drag-move:
	//   - space-pan / hand-tool: pan the viewport by the per-frame
	//     pointer delta (carry the previous position to compute it).
	//   - rubber-band: update the band's curX/curY and repaint.
	// Pan also kicks in via `pan-step` when the user space-converts
	// mid-rubber-band (Figma-style). All three paths converge on the
	// same `viewport.position.x/y -=` mutation.
	const lastDragPosRef = useRef<{ x: number; y: number } | null>(null);
	const isPanVerb = (verb: ResolvedGesture): boolean => verb.tier === "space-pan" || verb.tier === "hand-tool";

	const handlePointerEffect = (effect: Effect) => {
		// Dev introspection, last few FSM effects for `__ocv.lastEffects`.
		// Cheap (ring buffer of stringified summaries); helpful when a
		// gesture goes somewhere unexpected.
		const g = globalThis as unknown as {
			__ocv?: { lastEffects?: string[] };
		};
		if (!g.__ocv) g.__ocv = {};
		const log = g.__ocv.lastEffects ?? [];
		const verbStr = "verb" in effect
			? effect.verb.tier === "tool-refuses" ? effect.verb.tier : `${effect.verb.tier}/${effect.verb.verb.kind}`
			: "";
		const mods = "at" in effect ? ` shift=${effect.at.modifiers.shift ? "1" : "0"}` : "";
		log.push(`${effect.kind} ${verbStr}${mods}`.trim());
		while (log.length > 40) log.shift();
		g.__ocv.lastEffects = log;
		switch (effect.kind) {
			case "drag-start": {
				if (isPanVerb(effect.verb)) {
					lastDragPosRef.current = {
						x: effect.at.clientX,
						y: effect.at.clientY,
					};
				} else if (
					effect.verb.tier === "default" &&
					effect.verb.verb.kind === "rubber-band"
				) {
					rubberBandRef.current = {
						startX: effect.at.clientX,
						startY: effect.at.clientY,
						curX: effect.at.clientX,
						curY: effect.at.clientY,
					};
					// Seed the latch with whatever modifiers are held;
					// subsequent moves can add more (one-way latch, see
					// drag-move). A brief release mid-drag won't flip the
					// commit mode.
					rubberBandModRef.current = {
						shift: effect.at.modifiers.shift,
						alt: effect.at.modifiers.alt,
					};
					previewSelectionRef.current = EMPTY_ENTITY_SET;
					paintRubberBand();
				}
				break;
			}
			case "drag-move": {
				if (isPanVerb(effect.verb)) {
					const last = lastDragPosRef.current;
					if (last) {
						const dx = effect.at.clientX - last.x;
						const dy = effect.at.clientY - last.y;
						const viewport = viewportRef.current;
						if (viewport) {
							viewport.position.x += dx;
							viewport.position.y += dy;
						}
					}
					lastDragPosRef.current = {
						x: effect.at.clientX,
						y: effect.at.clientY,
					};
				} else if (rubberBandRef.current) {
					rubberBandRef.current.curX = effect.at.clientX;
					rubberBandRef.current.curY = effect.at.clientY;
					// One-way latch: pressing a modifier mid-drag sets it
					// for the rest of the gesture, releasing it doesn't
					// clear. Keeps the commit mode predictable from the
					// user's intent at any point in the drag.
					if (effect.at.modifiers.shift) {
						rubberBandModRef.current.shift = true;
					}
					if (effect.at.modifiers.alt) {
						rubberBandModRef.current.alt = true;
					}
					// Live "would be selected" preview, recompute each
					// move. The set is small (only entities
					// enclosed) so allocation cost is bounded by the visible
					// scene complexity, which is what the user already pays
					// for in renderFrame.
					previewSelectionRef.current = entitiesInBand();
					paintRubberBand();
				}
				break;
			}
			case "drag-end": {
				if (isPanVerb(effect.verb)) {
					lastDragPosRef.current = null;
				} else if (rubberBandRef.current) {
					commitRubberBand();
					rubberBandRef.current = null;
					rubberBandModRef.current = { shift: false, alt: false };
					previewSelectionRef.current = EMPTY_ENTITY_SET;
					paintRubberBand();
				}
				break;
			}
			case "drag-cancel": {
				rubberBandRef.current = null;
				rubberBandModRef.current = { shift: false, alt: false };
				previewSelectionRef.current = EMPTY_ENTITY_SET;
				lastDragPosRef.current = null;
				paintRubberBand();
				break;
			}
			case "drag-pause": {
				// Marquee stays visible; pan-step translates its
				// coordinates so it appears anchored to the same world
				// position (the entities it covers stay covered as the
				// viewport pans). Seed lastDragPos so pan-step can
				// compute deltas.
				lastDragPosRef.current = {
					x: effect.at.clientX,
					y: effect.at.clientY,
				};
				break;
			}
			case "drag-resume": {
				// Marquee's start stays where it was translated to (it's
				// anchored to its world position); the cursor's current
				// screen position becomes the new endpoint so the user
				// picks up drawing from where the cursor is.
				// The carriedOrigin IS the cursor's post-pan screen
				// position (FSM § 5.3, re-emit drag-resume with the
				// current snapshot as carried origin).
				if (rubberBandRef.current) {
					rubberBandRef.current.curX = effect.carriedOrigin.clientX;
					rubberBandRef.current.curY = effect.carriedOrigin.clientY;
					previewSelectionRef.current = entitiesInBand();
					paintRubberBand();
				}
				lastDragPosRef.current = null;
				break;
			}
			case "pan-step": {
				// Paused-pan emits pan-step directly (FSM does the delta
				// math against panOrigin). Apply to the viewport AND
				// translate the in-flight marquee by the same delta so
				// it stays anchored to its world position. The user sees
				// the marquee slide with the world it's selecting.
				const viewport = viewportRef.current;
				if (viewport) {
					viewport.position.x += effect.delta.dx;
					viewport.position.y += effect.delta.dy;
				}
				if (rubberBandRef.current) {
					rubberBandRef.current.startX += effect.delta.dx;
					rubberBandRef.current.startY += effect.delta.dy;
					rubberBandRef.current.curX += effect.delta.dx;
					rubberBandRef.current.curY += effect.delta.dy;
					// Recompute preview: marquee translated AND entities'
					// screen positions moved (viewport panned); both inputs
					// changed, so the enclosed set may have shifted.
					previewSelectionRef.current = entitiesInBand();
					paintRubberBand();
				}
				break;
			}
			case "click": {
				// Tool-create verbs (§ 4.6): Add Peer's empty-stage click
				// routes to `onCanvasClick` (the host consults its clock
				// for `t`. The verb's t=0 is a sentinel); a two-click
				// pick routes through `onSelect` like a sprite click, so
				// the host's arm/commit flow is one path for both origins.
				if (effect.verb.tier === "tool-create") {
					const v = effect.verb.verb;
					if (v.kind === "create-peer-at") {
						const place = onCanvasClickRef.current;
						if (place) {
							const world = clientToWorld(
								effect.at.clientX,
								effect.at.clientY,
							);
							if (world) place(world.x, world.y);
						}
					} else {
						// The pick names a stage node, and the two kinds share one id
						// namespace, so the selection is spelled from the id itself.
						onSelectRef.current?.({
							kind: nodeKindOf(v.nodeId),
							id: v.nodeId,
						});
					}
					break;
				}
				// Click on empty stage: route to the existing onCanvasClick
				// (Add Peer mode) or to onSelect(null) (clear). Skip for
				// pan-tier verbs (clicks while space-held don't deselect).
				// The captured modifier mode flows through so an empty
				// click with shift / shift+option is a NO-OP, "add to
				// selection" and "remove from selection" both reduce to
				// "nothing to do" when there's no target. Only a plain
				// empty click clears.
				if (
					effect.verb.tier === "default" &&
					effect.verb.verb.kind === "rubber-band"
				) {
					const place = onCanvasClickRef.current;
					if (place) {
						const world = clientToWorld(
							effect.at.clientX,
							effect.at.clientY,
						);
						if (world) place(world.x, world.y);
						return;
					}
					onSelectRef.current?.(null, {
						mode: selectModeFromModifiers({
							shiftKey: effect.at.modifiers.shift,
							altKey: effect.at.modifiers.alt,
						}),
					});
				}
				break;
			}
		}
	};

	// The pointer FSM for this surface. Its state is the cursor's other input:
	// what the surface is DOING outranks what it offers, and only the machine
	// knows what a press resolved to.
	const machineRef = useSurfacePointer(
		canvas,
		makeStageHit,
		{ onEffect: handlePointerEffect },
		{
			spaceHeld: gestureCtx.spaceHeld,
			activeTool: gestureCtx.activeTool,
		},
		"stage",
	);

	return {
		rubberBandOverlayRef,
		rubberBandRef,
		previewSelectionRef,
		machineRef,
		paintRubberBand,
	};
}
