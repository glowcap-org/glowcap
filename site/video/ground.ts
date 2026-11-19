/// <reference lib="dom" />
/**
 * The video's ground: the mycelium the home page grows under itself
 * (ui/mycelium/network.ts), grown at the video's size. It grows in from the
 * edges as the video opens, glowing at its front the way the home page
 * arrives, and then rests faint and still under the screens.
 *
 * `scene.ts` bundles this file for the scene page, and the page calls
 * `startGround` once and the returned function for every frame.
 */
import { firstBorn, grow, type Network } from "../../ui/mycelium/network.ts";
import { FRONT, LEVELS } from "../../ui/mycelium/light.ts";

/** How much of the ground shows in the middle of the frame, where the text
 * is, as the home page masks its own. */
const GROUND_MIDDLE = 0.3;
/** The ground's strength once it has arrived, against its strength while it
 * grows in, and how long it takes to settle there, in seconds. */
const GROUND_REST = 0.6;
const SETTLE = 1.2;

/** Put the ground on a canvas over the whole stage, under `screens`, and
 * return the function that draws it at a moment, in ms, growing in over the
 * video's first `arrive` seconds. It returns what it drew, so the renderer can tell two
 * frames that differ only here. */
export function startGround(
	stage: HTMLElement,
	screens: HTMLElement,
	arrive: number,
): (ms: number) => string {
	if (!stage.contains(screens)) throw new Error("video: the ground's screens are not on its stage");
	const W = stage.clientWidth;
	const H = stage.clientHeight;
	if (!(W > 0 && H > 0)) throw new Error("video: the ground's stage has no size");
	const canvas = document.createElement("canvas");
	const scale = devicePixelRatio;
	canvas.width = Math.round(W * scale);
	canvas.height = Math.round(H * scale);
	canvas.setAttribute("aria-hidden", "true");
	canvas.style.cssText = `position:absolute;inset:0;width:${W}px;height:${H}px;pointer-events:none`;
	canvas.style.maskImage = `radial-gradient(ellipse 62% 56% at 40% 48%, rgb(0 0 0 / ${GROUND_MIDDLE}), ` +
		`rgb(0 0 0 / ${GROUND_MIDDLE * 2}) 55%, #000 96%)`;
	screens.insertAdjacentElement("beforebegin", canvas);
	const ctx = canvas.getContext("2d");
	if (ctx == null) throw new Error("video: no 2d canvas for the mycelium");
	ctx.scale(scale, scale);
	ctx.lineCap = "round";
	const net = grow(W, H, true);
	const thread = tokenColor("--mycelium");
	const light = tokenColor("--mycelium-pulse");
	let drawn = "";
	return (ms) => {
		const s = ms / 1000;
		const step = Math.round(easeOut(clamp01(s / arrive)) * (net.steps + FRONT));
		const strength = 1 - (1 - GROUND_REST) * clamp01((s - arrive) / SETTLE);
		const key = `${step}:${strength.toFixed(2)}`;
		if (key !== drawn) {
			drawn = key;
			ctx.save();
			ctx.setTransform(1, 0, 0, 1, 0, 0);
			ctx.clearRect(0, 0, canvas.width, canvas.height);
			ctx.restore();
			threads(ctx, net, step, thread, strength);
			front(ctx, net, step, light);
		}
		return key;
	};
}

/** A token's color as the page computes it. A token that is not a color
 * leaves the probe the color it inherits, which is refused. */
function tokenColor(token: string): string {
	const holder = document.createElement("i");
	holder.style.color = "rgb(1, 2, 3)";
	const probe = document.createElement("i");
	probe.style.color = `var(${token})`;
	holder.append(probe);
	document.body.append(holder);
	const color = getComputedStyle(probe).color;
	holder.remove();
	if (color === "rgb(1, 2, 3)") throw new Error(`video: ${token} is not a color`);
	return color;
}

/** Every thread grown by `step`, hairs finest and faintest, the rest in
 * a few widths. */
function threads(ctx: CanvasRenderingContext2D, net: Network, step: number, color: string, alpha: number): void {
	const upTo = firstBorn(net, step + 1);
	const widths = [0.25, 0.5, 0.75, 1];
	ctx.strokeStyle = color;
	for (const w of widths) {
		ctx.beginPath();
		for (let i = 0; i < upTo; i++) {
			const p = net.parent[i];
			if (p < 0 || Math.min(1, Math.round(net.width[i] * 4) / 4) !== w) continue;
			ctx.moveTo(net.x[p], net.y[p]);
			ctx.lineTo(net.x[i], net.y[i]);
		}
		ctx.globalAlpha = alpha * (w === 0.25 ? 0.6 : 1);
		ctx.lineWidth = w;
		ctx.stroke();
	}
	ctx.globalAlpha = 1;
}

/** The growing front: the threads grown in the last `FRONT` steps before
 * `step`, brightest at the tip, in `LEVELS` bands, each a soft glow under a
 * fine core. */
function front(ctx: CanvasRenderingContext2D, net: Network, step: number, color: string): void {
	if (step <= 0 || step > net.steps + FRONT) return;
	ctx.strokeStyle = color;
	for (let level = 0; level < LEVELS; level++) {
		const from = firstBorn(net, step - (FRONT * (level + 1)) / LEVELS + 1);
		const to = firstBorn(net, step - (FRONT * level) / LEVELS + 1);
		ctx.beginPath();
		for (let i = from; i < to; i++) {
			const p = net.parent[i];
			if (p < 0 || net.hair[i]) continue;
			ctx.moveTo(net.x[p], net.y[p]);
			ctx.lineTo(net.x[i], net.y[i]);
		}
		for (const [width, strength] of [[5, 0.12], [0.9, 0.5]] as const) {
			ctx.globalAlpha = strength * (1 - level / LEVELS);
			ctx.lineWidth = width;
			ctx.stroke();
		}
	}
	ctx.globalAlpha = 1;
}

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
const easeOut = (v: number) => 1 - (1 - v) ** 2;
