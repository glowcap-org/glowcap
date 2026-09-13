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

Deno.test("edge stroke batch restrokes once for many dirty wires and never for a quiet frame", () => {
	const batch = new EdgeStrokeBatch();
	let clears = 0;
	const clear = batch.gfx.clear.bind(batch.gfx);
	batch.gfx.clear = () => {
		clears += 1;
		return clear();
	};
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
		assertEquals(clears, 0, "upserts do not rebuild the shared stroke");
		batch.flush();
		assertEquals(clears, 1, "one rebuild serves every dirty wire");
		assert(batch.gfx.getLocalBounds().width > 0, "stroked wires");

		// Idempotent: unchanged upserts leave the Graphics alone.
		batch.upsert("a", {
			curve,
			color: 0xff0000,
			width: 2,
			lineStyle: "solid",
		});
		batch.setOrder(["a", "b"]);
		batch.flush();
		assertEquals(
			clears,
			1,
			"a quiet frame must not clear and re-tessellate",
		);
		batch.upsert("a", { curve: { ...curve, cx: 80 }, color: 0xff0000, width: 2, lineStyle: "solid" });
		batch.upsert("b", { curve: { ...curve, cy: 80 }, color: 0x00ff00, width: 4, lineStyle: "dashed" });
		batch.setOrder(["a", "b"]);
		batch.flush();
		assertEquals(clears, 2, "moving both retained wires still rebuilds only once");

		// Membership can change without changing the count or the paint order.
		batch.remove("a");
		batch.upsert("ghost", { curve, color: 1, width: 2, lineStyle: "solid" });
		batch.setOrder(["a", "b"]);
		batch.setOrder(["ghost"]);
		batch.flush();
		assertEquals(batch.gfx.getLocalBounds().width, 0, "pruned entries cannot reappear through order alone");

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
