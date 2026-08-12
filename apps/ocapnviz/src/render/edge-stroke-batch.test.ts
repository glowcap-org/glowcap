import { assert, assertEquals } from "@std/assert";
import { installHeadlessCanvas } from "./headless-canvas.fixture.ts";
import { EdgeStrokeBatch } from "./edge-stroke-batch.ts";

installHeadlessCanvas();

const curve = {
  ax: 0,
  ay: 0,
  bx: 100,
  by: 0,
  cx: 50,
  cy: 40,
};

Deno.test("edge stroke batch uploads once for many dirty wires", () => {
  const batch = new EdgeStrokeBatch();
  try {
    batch.upsert("a", {
      curve,
      color: 0xff0000,
      width: 2,
      lineStyle: "solid",
    });
    batch.upsert("b", {
      curve: { ...curve, ay: 20, by: 20 },
      color: 0x00ff00,
      width: 4,
      lineStyle: "dashed",
    });
    batch.setOrder(["a", "b"]);
    batch.flush();
    assert(batch.gfx.getLocalBounds().width > 0, "stroked wires");

    // Idempotent: unchanged upserts leave the Graphics alone.
    const before = batch.gfx.context;
    batch.upsert("a", {
      curve,
      color: 0xff0000,
      width: 2,
      lineStyle: "solid",
    });
    batch.setOrder(["a", "b"]);
    batch.flush();
    assertEquals(
      batch.gfx.context,
      before,
      "a quiet frame must not clear and re-tessellate",
    );

    batch.remove("a");
    batch.remove("b");
    batch.setOrder([]);
    batch.flush();
    assertEquals(batch.gfx.getLocalBounds().width, 0, "cleared");

    // setOrder is authoritative: an upsert left off the order is dropped.
    batch.upsert("ghost", {
      curve,
      color: 1,
      width: 2,
      lineStyle: "solid",
    });
    batch.setOrder([]);
    batch.flush();
    assertEquals(
      batch.gfx.getLocalBounds().width,
      0,
      "orphan upserts do not survive setOrder",
    );
  } finally {
    batch.destroy();
  }
});
