/**
 * `applyRowOrder` is the id-only form of the engine's row-order walk.
 * The Timeline gutter reuses it so listed ids paint first.
 */

import { assertEquals } from "@std/assert";
import { applyRowOrder } from "./event-helpers.ts";

Deno.test("applyRowOrder: empty/undefined override returns insertion order", () => {
  assertEquals(applyRowOrder(["a", "b", "c"], undefined), ["a", "b", "c"]);
  assertEquals(applyRowOrder(["a", "b", "c"], []), ["a", "b", "c"]);
});

Deno.test("applyRowOrder: listed ids first, then unlisted by insertion order", () => {
  assertEquals(
    applyRowOrder(["a", "b", "c", "d"], ["c", "a"]),
    ["c", "a", "b", "d"],
  );
});

Deno.test("applyRowOrder: ids in override that don't exist are skipped", () => {
  // Stale rowOrder (entity deleted) shouldn't break rendering.
  assertEquals(
    applyRowOrder(["a", "b"], ["ghost", "a", "another-ghost"]),
    ["a", "b"],
  );
});
