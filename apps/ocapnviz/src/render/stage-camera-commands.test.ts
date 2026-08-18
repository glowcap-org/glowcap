/**
 * Named camera commands and wheel effects against a fake viewport.
 *
 * Fit's arithmetic and empty-layer skip already live in `stage-view.test.ts`.
 * What this file holds is the mapping: a command holds the center it has,
 * Fit refuses to move when nothing is drawn, and a zoom whose pivot is
 * outside the Stage marker is somebody else's.
 */

import { assertEquals } from "@std/assert";
import {
  applyStageWheel,
  FIT_PADDING_PX,
  runStageCameraCommand,
  type StageCameraTarget,
  type StageFitLayer,
  type StageWheelTarget,
} from "./stage-camera-commands.ts";
import { DEFAULT_STAGE_VIEW, fitStageView, steppedStageZoom } from "./stage-view.ts";

function camera(
  init?: { zoom?: number; x?: number; y?: number; w?: number; h?: number },
): StageCameraTarget & { zoom: number; x: number; y: number } {
  const held = {
    zoom: init?.zoom ?? 1,
    x: init?.x ?? 0,
    y: init?.y ?? 0,
    screenWidth: init?.w ?? 800,
    screenHeight: init?.h ?? 600,
    get center() {
      return { x: held.x, y: held.y };
    },
    get scale() {
      return { x: held.zoom };
    },
    setZoom(zoom: number) {
      held.zoom = zoom;
    },
    moveCenter(x: number, y: number) {
      held.x = x;
      held.y = y;
    },
  };
  return held;
}

function layer(
  children: number,
  bounds: { x: number; y: number; width: number; height: number },
): StageFitLayer {
  return {
    children: { length: children },
    getLocalBounds: () => bounds,
  };
}

Deno.test("zoom-to holds the center it has", () => {
  const viewport = camera({ zoom: 1, x: 40, y: -10 });
  runStageCameraCommand(viewport, [], { kind: "zoom-to", zoom: 2 });
  assertEquals(viewport.zoom, 2);
  assertEquals(viewport.x, 40);
  assertEquals(viewport.y, -10);
});

Deno.test("a zoom step is about the viewport's center", () => {
  const viewport = camera({ zoom: 1, x: 12, y: 8 });
  runStageCameraCommand(viewport, [], { kind: "zoom-out" });
  assertEquals(viewport.zoom, steppedStageZoom(1, true));
  assertEquals(viewport.x, 12);
  assertEquals(viewport.y, 8);
});

Deno.test("home is the middle of the world at 1:1", () => {
  const viewport = camera({ zoom: 4, x: 99, y: -3 });
  runStageCameraCommand(viewport, [], { kind: "home" });
  assertEquals(viewport.zoom, DEFAULT_STAGE_VIEW.zoom);
  assertEquals(viewport.x, DEFAULT_STAGE_VIEW.center.x);
  assertEquals(viewport.y, DEFAULT_STAGE_VIEW.center.y);
});

Deno.test("go-to names a whole view", () => {
  const viewport = camera();
  runStageCameraCommand(viewport, [], {
    kind: "go-to",
    view: { zoom: 0.5, center: { x: 7, y: 9 } },
  });
  assertEquals(viewport.zoom, 0.5);
  assertEquals(viewport.x, 7);
  assertEquals(viewport.y, 9);
});

Deno.test("fit does not move when nothing is drawn", () => {
  const viewport = camera({ zoom: 2, x: 15, y: 20 });
  runStageCameraCommand(viewport, [
    layer(0, { x: 0, y: 0, width: 0, height: 0 }),
  ], { kind: "fit" });
  assertEquals(viewport.zoom, 2);
  assertEquals(viewport.x, 15);
  assertEquals(viewport.y, 20);
});

Deno.test("fit shows the drawn layers, not the world", () => {
  const viewport = camera({ w: 400, h: 300 });
  const content = { x: 100, y: 50, width: 80, height: 40 };
  runStageCameraCommand(viewport, [layer(1, content)], { kind: "fit" });
  const expected = fitStageView(
    content,
    { width: 400, height: 300 },
    FIT_PADDING_PX,
  );
  assertEquals(viewport.zoom, expected.zoom);
  assertEquals(viewport.x, expected.center.x);
  assertEquals(viewport.y, expected.center.y);
});

function wheelTarget(
  init?: { zoom?: number; px?: number; py?: number },
): StageWheelTarget & { zoom: number; px: number; py: number } {
  const held = {
    zoom: init?.zoom ?? 1,
    px: init?.px ?? 0,
    py: init?.py ?? 0,
    get scale() {
      return { x: held.zoom };
    },
    get position() {
      return {
        get x() {
          return held.px;
        },
        set x(v: number) {
          held.px = v;
        },
        get y() {
          return held.py;
        },
        set y(v: number) {
          held.py = v;
        },
      };
    },
    setZoom(zoom: number) {
      held.zoom = zoom;
    },
    toWorld(x: number, y: number) {
      return { x: x - held.px, y: y - held.py };
    },
    toScreen(x: number, y: number) {
      return { x: x + held.px, y: y + held.py };
    },
  };
  return held;
}

function marker(
  left: number,
  top: number,
  right: number,
  bottom: number,
): HTMLElement {
  return {
    getBoundingClientRect: () => ({ left, top, right, bottom }),
  } as HTMLElement;
}

Deno.test("a pan-step slides the viewport", () => {
  const viewport = wheelTarget({ px: 10, py: 4 });
  applyStageWheel(
    viewport,
    {
      kind: "pan-step",
      surface: "stage-empty",
      delta: { dx: 3, dy: -2 },
    },
    null,
    null,
  );
  assertEquals(viewport.px, 7);
  assertEquals(viewport.py, 6);
});

Deno.test("a zoom-step outside the Stage marker is ignored", () => {
  const viewport = wheelTarget({ zoom: 1, px: 0, py: 0 });
  const host = marker(0, 0, 100, 100);
  const canvas = marker(0, 0, 400, 400);
  applyStageWheel(
    viewport,
    {
      kind: "zoom-step",
      surface: "stage-empty",
      factor: 2,
      pivotX: 200,
      pivotY: 200,
    },
    host,
    canvas,
  );
  assertEquals(viewport.zoom, 1);
  assertEquals(viewport.px, 0);
  assertEquals(viewport.py, 0);
});

Deno.test("a zoom-step in the Stage marker scales about the cursor", () => {
  const viewport = wheelTarget({ zoom: 1, px: 0, py: 0 });
  const host = marker(0, 0, 400, 400);
  const canvas = marker(0, 0, 400, 400);
  applyStageWheel(
    viewport,
    {
      kind: "zoom-step",
      surface: "stage-empty",
      factor: 2,
      pivotX: 40,
      pivotY: 10,
    },
    host,
    canvas,
  );
  assertEquals(viewport.zoom, 2);
});
