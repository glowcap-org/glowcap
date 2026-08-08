/**
 * Hover-following ghost playhead, shared by Scrubber and Overview
 * so the two surfaces show one conceptual cursor.
 *
 * 1-px column of alternating fg/bg pixels at 50% alpha: contrast
 * survives any background (half the pixels disagree with it) and
 * reads as "subtle hint" rather than "marker".
 */

import type { Graphics } from "pixi.js";

export function drawGhostPlayhead(
  graphics: Graphics,
  x: number,
  y0: number,
  y1: number,
  fgColor: number,
  bgColor: number,
): void {
  const px = Math.round(x);
  const start = Math.round(y0);
  const end = Math.round(y1);
  for (let y = start; y < end; y += 2) {
    graphics.rect(px, y, 1, 1);
  }
  graphics.fill({ color: fgColor, alpha: 0.5 });
  for (let y = start + 1; y < end; y += 2) {
    graphics.rect(px, y, 1, 1);
  }
  graphics.fill({ color: bgColor, alpha: 0.5 });
}
