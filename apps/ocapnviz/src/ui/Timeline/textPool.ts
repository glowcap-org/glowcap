/**
 * Recyclable pool of PixiJS `Text` objects, indexed by call order.
 * Per-frame: `beginFrame()`, `acquire(...)` for each visible label,
 * `endFrame()` to hide any untouched slots.
 *
 * What the pool buys, always: no `Text` is constructed or destroyed
 * per frame. A frame that draws forty labels allocates nothing
 * after the first one that drew forty.
 *
 * What it buys only sometimes: a slot whose label is unchanged
 * skips re-rasterizing. That holds while the *number of acquires
 * before it* is unchanged, because a slot is a position in the
 * call order and nothing else.
 *
 * The scrubber's `lanesLabels` pool does not hold it. Per visible
 * row, `drawRowGutter` acquires the row's name behind an `if (text)`
 * that a narrowed gutter empties, and then `drawLaneSpans`
 * acquires one label per pill wide enough to carry one, which
 * changes as the user zooms and pans. So one row label winking out
 * on a gutter drag, or one pill growing past the width that earns
 * a label, shifts every label after it one slot along — and each
 * shifted slot rewrites `.text`, which is the re-rasterization
 * this pool exists to avoid. The outer `labelPool` holds only the
 * ruler ticks, and their count changes only when a tick pans off
 * the plot, on a frame where the tick labels were all changing
 * anyway.
 *
 * Keying slots by what the label IS (entity id plus role) rather
 * than by when it was asked for would close that, and it is a
 * change to every `acquire` call site, not to this file.
 */

import { Container, Text, type TextStyleOptions } from "pixi.js";

export interface TextStyleSpec {
  fontFamily: string;
  fontSize: number;
  fill: number | string;
  /** "left" anchors at (x, y); "right" subtracts the rendered width. */
  align: "left" | "right";
  /** "alphabetic" matches Canvas 2D's text-baseline default. */
  baseline: "top" | "middle" | "alphabetic";
  alpha?: number;
}

export class TextPool {
  #parent: Container;
  #items: Text[] = [];
  #cursor = 0;

  constructor(parent: Container) {
    this.#parent = parent;
  }

  beginFrame(): void {
    this.#cursor = 0;
  }

  /** Reserve the next pool slot at (x, y) with the given text +
   * style. Slots are indexed by call order, so a call site reuses
   * the same `Text` instance for exactly as long as the number of
   * acquires before it stays the same — see the header for which
   * of this pool's callers hold that and which do not. */
  acquire(label: string, style: TextStyleSpec, x: number, y: number): void {
    const index = this.#cursor++;
    let text = this.#items[index];
    if (!text) {
      text = new Text({ text: label, style: toPixiStyle(style) });
      this.#items[index] = text;
      this.#parent.addChild(text);
    } else {
      // Mutate in place — Pixi only re-rasterizes when style
      // actually differs. Stable-style labels (gutter, ruler) hit
      // the cheap path of only writing `.text`.
      if (text.text !== label) text.text = label;
      const cur = text.style;
      if (
        cur.fontFamily !== style.fontFamily ||
        cur.fontSize !== style.fontSize ||
        cur.fill !== style.fill
      ) {
        text.style = toPixiStyle(style);
      }
    }
    text.visible = true;
    text.alpha = style.alpha ?? 1;
    // Canvas 2D's "alphabetic" baseline ≈ anchor.y 0.85 in Pixi.
    text.anchor.set(
      style.align === "right" ? 1 : 0,
      style.baseline === "middle"
        ? 0.5
        : style.baseline === "alphabetic"
        ? 0.85
        : 0,
    );
    text.position.set(x, y);
  }

  /** Hide any slots not `acquire`'d this frame. */
  endFrame(): void {
    for (let i = this.#cursor; i < this.#items.length; i += 1) {
      const text = this.#items[i];
      if (text && text.visible) text.visible = false;
    }
  }

  destroy(): void {
    for (const text of this.#items) {
      text.destroy();
    }
    this.#items.length = 0;
  }
}

function toPixiStyle(s: TextStyleSpec): TextStyleOptions {
  return {
    fontFamily: s.fontFamily,
    fontSize: s.fontSize,
    fill: s.fill,
  };
}
