/**
 * UnifiedCanvas. The single full-viewport PixiJS canvas behind
 * every React UI panel. One canvas, one Application, one ticker.
 * Scenes (Stage, Timeline) attach to `app.stage` as sub-containers
 * and read their layout from a shared `RegionRegistry`.
 *
 * Architecture (Figma / Sketch / AE viewer pattern):
 *
 *   <body>
 *     <canvas id="ocv-pixi" />     ← position: fixed; inset: 0; z-index: 0
 *     <div class="app-grid">       ← React panels above, opaque bg
 *       <section ref={hostRef} />  ← Stage marker
 *       <div ref={hostRef} />      ← Timeline markers
 *     </div>
 *   </body>
 *
 * Panels overlay the canvas. The canvas is visually visible only
 * where panels don't cover it. Each scene's marker tells the
 * registry where to paint.
 *
 * StrictMode-safe: the canvas's WebGL context outlives React
 * mounts (only one WebGL context per canvas, ever).
 */

import { createContext, type ReactNode, useCallback, useContext, useEffect, useRef, useState } from "react";
import { Application } from "pixi.js";
import { RegionRegistry } from "./RegionRegistry.ts";
import { themedColors } from "./palette.ts";
import type { Theme } from "../ui/tokens.ts";
import { safeListener, safeTick } from "./safeTick.ts";
import { pushError } from "../ui/error/error-bus.ts";
import { importError } from "../engine/errors.ts";

/** DOM id of the one Pixi canvas. Exported so hover checks (e.g.
 * "is the pointer over the stage") can identify the element the
 * gesture pipeline binds to without reaching into Pixi. */
export const CANVAS_ELEMENT_ID = "ocv-pixi";

export interface UnifiedCanvasContextValue {
	app: Application;
	regions: RegionRegistry;
	/** Write the canvas cursor. The scene that owns the gesture pipeline (the
	 *  Stage) calls this once per frame with `cursorFor`'s answer. This element
	 *  has exactly one writer, and the scene is it. Repeats are free, the DOM
	 *  is touched only when the value changes. */
	setCursor: (cursor: string) => void;
}

/** `null` until `app.init()` resolves. Callers bail their effect
 * on null. The effect reruns when context populates. */
const Ctx = createContext<UnifiedCanvasContextValue | null>(null);

export function useUnifiedCanvas(): UnifiedCanvasContextValue | null {
	return useContext(Ctx);
}

export interface UnifiedCanvasProps {
	theme: Theme;
	children: ReactNode;
}

export function UnifiedCanvas(
	{ theme, children }: UnifiedCanvasProps,
) {
	const canvasRef = useRef<HTMLCanvasElement | null>(null);
	const appRef = useRef<Application | null>(null);
	const [ctxValue, setCtxValue] = useState<UnifiedCanvasContextValue | null>(
		null,
	);

	// The cursor currently stamped on the canvas element, and the one function
	// that stamps it. Both the scene's per-frame write and the Pixi intercept below
	// go through this pair, so the element never has two writers.
	const desiredCursorRef = useRef<string>("default");
	const setCursor = useCallback((next: string) => {
		if (desiredCursorRef.current === next) return;
		desiredCursorRef.current = next;
		const canvas = canvasRef.current;
		if (canvas) canvas.style.cursor = next;
	}, []);

	useEffect(() => {
		const canvas = canvasRef.current;
		if (!canvas) return;

		// StrictMode + Pixi v8: dev double-mount races the async
		// `app.init`. Browsers only ever give a canvas ONE WebGL
		// context, so destroying-and-recreating the Application on the
		// first mount's disposed branch would brick the second mount.
		// Stash the Application + RegionRegistry + the init promise on
		// the canvas DOM element so every remount finds the same one.
		// The app outlives React mounts; the browser page-unload tears
		// it down.
		type Stash = {
			app: Application;
			regions: RegionRegistry;
			ready: Promise<void>;
		};
		const stashKey = "__ocvPixi";
		const stashed = canvas as unknown as Record<string, Stash | undefined>;
		let stash = stashed[stashKey];

		if (!stash) {
			const app = new Application();
			const regions = new RegionRegistry();
			const dpr = globalThis.devicePixelRatio || 1;
			const ready = app.init({
				canvas,
				background: themedColors(theme).canvas,
				antialias: true,
				autoDensity: true,
				resolution: dpr,
				width: globalThis.innerWidth,
				height: globalThis.innerHeight,
			}).then(() => {
				// Per-frame region polling keeps scenes synced to React
				// layout (panel drags, window resize) without per-scene
				// observers. `safeTick` so a per-frame throw in `regions.poll`
				// surfaces once instead of escaping into Pixi's rAF loop.
				app.ticker.add(safeTick(() => regions.poll()));
			}).catch((caught) => {
				// Renderer init failure is fatal-but-recoverable: the user
				// needs to know (modal) and reloading typically succeeds.
				pushError({
					error: importError(
						`PixiJS failed to initialize: ${caught instanceof Error ? caught.message : String(caught)}`,
						"Reload the page. If it keeps happening, your browser may not support WebGL.",
					),
					source: "engine",
				});
			});
			stash = { app, regions, ready };
			stashed[stashKey] = stash;
			globalThis.addEventListener(
				"resize",
				safeListener(() => {
					if (app.renderer) {
						app.renderer.resize(
							globalThis.innerWidth,
							globalThis.innerHeight,
						);
					}
				}),
			);
		}

		let cancelled = false;
		const localStash = stash;
		localStash.ready.then(() => {
			if (cancelled) return;
			appRef.current = localStash.app;
			setCtxValue({
				app: localStash.app,
				regions: localStash.regions,
				setCursor,
			});
		});

		return () => {
			cancelled = true;
		};
		// Empty deps: init runs once. Theme updates land via the effect below.
	}, []);

	useEffect(() => {
		const app = appRef.current;
		if (!app) return;
		app.renderer.background.color = themedColors(theme).canvas;
	}, [theme]);

	// Keep the app's answer in place by intercepting Pixi's
	// `cursorStyles.default` callback. Pixi writes the canvas cursor itself on
	// every pointer event: it runs `setCursor(rootBoundary.cursor)`, which falls
	// back to `cursorStyles.default` when the hit-test found no sprite with a
	// cursor of its own, and no sprite has one, because the cursor is derived
	// once per frame from the gesture pipeline (`cursorFor`) rather than
	// attached to sprites. By making `default` a function instead of a string,
	// Pixi's write lands on the value the scene last asked for instead of a
	// literal `"default"`. That reset was the "Space-held, hover off peer →
	// cursor reverts to an arrow" bug. Doc cursor.md (single cursor authority).
	useEffect(() => {
		const app = appRef.current;
		if (!app) return;
		const events = app.renderer.events;
		const dom = events.domElement as HTMLElement | undefined;
		if (!dom) return;
		// Stamp the standing answer once, so the element carries an explicit
		// cursor from the moment it exists rather than inheriting one.
		dom.style.cursor = desiredCursorRef.current;
		events.cursorStyles.default = () => {
			dom.style.cursor = desiredCursorRef.current;
		};
		return () => {
			events.cursorStyles.default = "default";
		};
	}, [ctxValue]);

	return (
		<>
			<canvas
				ref={canvasRef}
				id={CANVAS_ELEMENT_ID}
				// Suppress the browser's right-click menu on the canvas.
				// Reason isn't "menus are bad", it's that an accidental
				// right-click DURING an in-flight drag (peer drag, row
				// reorder, scrub, marquee) corrupts the pointer event
				// stream: the browser eats focus, the contextmenu event
				// can swallow the pending pointermove/up, and the drag
				// gets "stuck" because we never see the gesture finish.
				// Editor convention (Photoshop / Figma / Adobe / Flash):
				// the canvas never shows a browser context menu. Cheap
				// and defensible, sidebar inputs / dropdowns still get
				// their native menus since this only binds to the
				// canvas element.
				onContextMenu={(e) => e.preventDefault()}
				style={{
					position: "fixed",
					inset: 0,
					width: "100vw",
					height: "100vh",
					// Panels at z-index ≥ 1 with opaque backgrounds hide the
					// canvas via DOM stacking; the visible canvas regions are
					// exactly the gaps.
					zIndex: 0,
					display: "block",
					// Pre-color the canvas element to match Pixi's clear
					// color (`--ocv-canvas` = `themedColors(theme).canvas`).
					// Without this, the few hundred ms between React mounting
					// the canvas and `app.init()` resolving shows the body's
					// `--ocv-bg` through the still-transparent canvas, a
					// visible "darker strip" in dark mode where the body bg
					// is a notch darker than the canvas color
					// (canvas is the focal workspace, chrome is the frame).
					// Pixi's first paint takes over identically; no visible
					// transition. Inline `background` instead of a CSS rule
					// keeps the canvas element's contract local to where it
					// mounts.
					background: "var(--ocv-canvas)",
				}}
			/>
			<Ctx.Provider value={ctxValue}>{children}</Ctx.Provider>
		</>
	);
}
