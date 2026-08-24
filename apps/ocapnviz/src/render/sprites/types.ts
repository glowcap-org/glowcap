/**
 * Per-entity sprite shapes — the Pixi objects `renderFrame` maps
 * hold, and the drag closure both node kinds raise.
 *
 * An implementation detail of the projection: `Stage` allocates the
 * Maps but never reaches into a sprite's internals. Each kind's
 * create/update lives beside the type in this directory.
 */

import type { Container, Graphics, Text } from "pixi.js";
import type { CodecLineStyle, ThemedColors } from "../palette.ts";
import type { HaloTier, PeerActivity, SelectMode } from "../types.ts";

/** Hand a pointerdown on a node body to `createStageNodeDrag`. Declared
 *  once because two sprite kinds raise it and `RenderFrameArgs` carries it. */
export type StartNodeDrag = (
	kind: "peer" | "endpoint",
	nodeId: string,
	pointerId: number,
	screenX: number,
	screenY: number,
	nodeWorldX: number,
	nodeWorldY: number,
	modeAtDown: SelectMode,
) => void;

export type PeerSprite = {
	body: Container;
	bodyGfx: Graphics;
	haloGfx: Graphics;
	label: Container;
	labelBg: Graphics;
	labelText: Text;
	lastHalo: HaloTier;
	lastHovered: boolean;
	lastActivity: PeerActivity;
	lastColor: number;
	lastColors: ThemedColors | null;
	lastLabelText: string;
	/** The camera scale the selection mark was last painted at. A mark holds one
	 *  screen size, so its world geometry is a function of the zoom, and a sprite
	 *  whose other inputs are unchanged still owes a repaint when the camera
	 *  moves. Without it the compensation is inert: a stage's world geometry does
	 *  not change when you zoom, so nothing else here would ever trip. */
	lastScale: number;
};

/** A session end nobody has attributed. Same parts as a peer's sprite minus
 *  the profile color: nothing here names an implementation. It keeps the
 *  activity badge, because who this end is and whether bytes are moving
 *  through it are two separate questions, and only the first one is open. */
export type EndpointSprite = {
	body: Container;
	bodyGfx: Graphics;
	haloGfx: Graphics;
	label: Container;
	labelBg: Graphics;
	labelText: Text;
	lastHalo: HaloTier;
	lastHovered: boolean;
	lastActivity: PeerActivity;
	/** Whether the end was last drawn as a claim on a peer the stage draws,
	 *  which decides the body's weight and so has to be repainted when it
	 *  changes. */
	lastClaiming: boolean;
	lastColors: ThemedColors | null;
	lastLabelText: string;
	/** The camera scale the selection mark was last painted at. A mark holds one
	 *  screen size, so its world geometry is a function of the zoom, and a sprite
	 *  whose other inputs are unchanged still owes a repaint when the camera
	 *  moves. Without it the compensation is inert: a stage's world geometry does
	 *  not change when you zoom, so nothing else here would ever trip. */
	lastScale: number;
};

export type EdgeSprite = {
	hitArea: Container;
	haloGfx: Graphics;
	/** Wire pixels live on `edgeStrokeBatch`, not a per-edge Graphics. */
	label: Container;
	labelBg: Graphics;
	labelText: Text;
	lastAx: number;
	lastAy: number;
	lastBx: number;
	lastBy: number;
	lastCx: number;
	lastCy: number;
	lastHalo: HaloTier;
	lastHovered: boolean;
	lastColor: number;
	lastWidth: number;
	lastLineStyle: CodecLineStyle;
	lastColors: ThemedColors | null;
	lastLabelText: string;
	/** The camera scale the selection mark was last painted at. A mark holds one
	 *  screen size, so its world geometry is a function of the zoom, and a sprite
	 *  whose other inputs are unchanged still owes a repaint when the camera
	 *  moves. Without it the compensation is inert: a stage's world geometry does
	 *  not change when you zoom, so nothing else here would ever trip. */
	lastScale: number;
};

export type MessageSprite = {
	container: Container;
	body: Graphics;
	haloGfx: Graphics;
	label: Container;
	labelBg: Graphics;
	labelText: Text;
	lastHalo: HaloTier;
	lastHovered: boolean;
	lastColors: ThemedColors | null;
	lastLabelText: string;
	/** The camera scale the selection mark was last painted at. A mark holds one
	 *  screen size, so its world geometry is a function of the zoom, and a sprite
	 *  whose other inputs are unchanged still owes a repaint when the camera
	 *  moves. Without it the compensation is inert: a stage's world geometry does
	 *  not change when you zoom, so nothing else here would ever trip. */
	lastScale: number;
	/** True after `"body"` vis mode cleared the dot Graphics. Forces one body
	 *  redraw on unhide without making `lastColors` lie to the label path. */
	lastBodyCleared: boolean;
};
