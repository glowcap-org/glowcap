/**
 * A region's row belongs to the registration that made it.
 *
 * Registering and disposing are the add and the remove of a table that lives
 * as long as the canvas does, so they have to be the same test: the disposer
 * removes what its own registration put there, and nothing else. A remount can
 * put the replacement element in before it tears the old one out, and a
 * disposer that removed the name outright would leave the region unpolled
 * while its element is still on screen.
 *
 * Validated by breaking the code it covers: a disposer that deletes the name
 * without checking who owns it turns the re-registration case below red.
 */

import { assertEquals } from "@std/assert";
import { type Rect, RegionRegistry } from "./RegionRegistry.ts";

/** An element that reports the rect it is told to, so a test can move it. */
function elementAt(rect: Rect): HTMLElement {
  const at = { ...rect };
  return {
    getBoundingClientRect: () => ({
      left: at.x,
      top: at.y,
      width: at.width,
      height: at.height,
    }),
    moveTo(x: number, y: number) {
      at.x = x;
      at.y = y;
    },
  } as unknown as HTMLElement & { moveTo(x: number, y: number): void };
}

const at = (x: number, y: number): Rect => ({ x, y, width: 10, height: 10 });

Deno.test("a region's rect follows its element", () => {
  const regions = new RegionRegistry();
  const el = elementAt(at(1, 2)) as HTMLElement & {
    moveTo(x: number, y: number): void;
  };
  const seen: Rect[] = [];
  const dispose = regions.register("stage", el);
  const unsubscribe = regions.subscribe("stage", (rect) => seen.push(rect));
  assertEquals(seen, [at(1, 2)], "a subscriber hears the rect it attached to");

  regions.poll();
  assertEquals(seen.length, 1, "an unmoved region woke its subscriber");

  el.moveTo(30, 40);
  regions.poll();
  assertEquals(seen.at(-1), at(30, 40));

  unsubscribe();
  dispose();
  assertEquals(regions.get("stage"), null);
});

Deno.test("a replaced element keeps the region, and the old disposer takes nothing", () => {
  const regions = new RegionRegistry();
  const first = elementAt(at(1, 1));
  const second = elementAt(at(5, 5));

  const disposeFirst = regions.register("stage", first);
  regions.register("stage", second);
  assertEquals(regions.get("stage"), at(5, 5), "the replacement owns the row");

  // The element that left now tears down, after the one that replaced it
  // arrived. It has nothing here any more, so it removes nothing.
  disposeFirst();
  assertEquals(
    regions.get("stage"),
    at(5, 5),
    "a departing element took the live one's row with it",
  );
  regions.poll();
  assertEquals(
    regions.get("stage"),
    at(5, 5),
    "the region stopped being polled while its element was still on screen",
  );
});

Deno.test("a layout that has not moved is not rebuilt", () => {
  // `poll` runs on every frame of every scene and the usual answer is that
  // nothing changed, so the unchanged case must cost nothing: it used to build a
  // rect per region per frame in order to compare it, and throw it away. Holding
  // the same object is the observable form of that.
  const regions = new RegionRegistry();
  const el = elementAt(at(1, 2)) as HTMLElement & {
    moveTo(x: number, y: number): void;
  };
  regions.register("stage", el);
  const first = regions.get("stage");
  regions.poll();
  regions.poll();
  assertEquals(regions.get("stage") === first, true, "the rect was rebuilt");
  // And a real move still lands.
  el.moveTo(5, 6);
  regions.poll();
  assertEquals(regions.get("stage"), at(5, 6));
});
