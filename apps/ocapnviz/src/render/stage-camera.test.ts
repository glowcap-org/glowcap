/**
 * The channel between the camera and the controls that drive it.
 *
 * Two things here are load-bearing and neither is obvious from reading the
 * class. A wheel gesture publishes the scale on every frame, so the store has to
 * stay quiet unless something a reader can SEE has changed, or the app
 * re-renders sixty times a second while nothing about it looks different. And
 * the snapshot has to be the same object across those quiet publishes, because
 * `useSyncExternalStore` compares by identity and a fresh object every frame
 * would defeat the silence.
 *
 * Validated by breaking both: publishing unconditionally, and rebuilding the
 * snapshot on every call, each turn the matching case below red.
 */

import { assert, assertEquals } from "@std/assert";
import { StageCamera } from "./stage-camera.ts";
import { formatStageZoom, MIN_STAGE_SCALE } from "./stage-view.ts";

function counted(camera: StageCamera): () => number {
  let woken = 0;
  camera.subscribe(() => {
    woken++;
  });
  return () => woken;
}

Deno.test("a scale that reads the same wakes nobody", () => {
  const camera = new StageCamera();
  const woken = counted(camera);
  // A drift of a thousandth of a percent, sixty times over: every frame of a
  // gesture that has not yet moved the number a reader can see.
  for (let i = 0; i < 60; i++) camera.publishZoom(1 + i * 1e-6);
  assertEquals(woken(), 0, "the readout woke on a change nobody could see");
});

Deno.test("the snapshot is one object while nothing changes", () => {
  const camera = new StageCamera();
  const first = camera.getReadout();
  for (let i = 0; i < 10; i++) camera.publishZoom(1 + i * 1e-6);
  assert(
    camera.getReadout() === first,
    "a fresh snapshot per publish would re-render every frame regardless",
  );
});

Deno.test("a scale that reads differently wakes once", () => {
  const camera = new StageCamera();
  const woken = counted(camera);
  camera.publishZoom(0.5);
  assertEquals(camera.getReadout().label, formatStageZoom(0.5));
  assertEquals(woken(), 1);
  // Landing on the same reading again is not a change.
  camera.publishZoom(0.5);
  assertEquals(woken(), 1);
});

Deno.test("reaching the floor wakes the readout even at one reading", () => {
  // Two things drive the controls and only one of them is the number. At the
  // floor the step-out button greys, and the scale can arrive there having
  // already read the same, so a store watching the label alone would leave a
  // live-looking button that does nothing.
  const camera = new StageCamera();
  camera.publishZoom(MIN_STAGE_SCALE * 1.0001);
  const before = camera.getReadout();
  assert(before.canZoomOut, "not yet at the floor");
  const woken = counted(camera);
  camera.publishZoom(MIN_STAGE_SCALE);
  assertEquals(camera.getReadout().label, before.label, "same reading");
  assertEquals(camera.getReadout().canZoomOut, false);
  assertEquals(woken(), 1, "the floor arrived without waking the button");
});

Deno.test("the settled view is published once per rest, not per frame", () => {
  // The document panel's Opens-at button compares against this to know whether
  // there is anything to record, so it has to be in the snapshot — and it is only
  // affordable there because the stage waits for the camera to stop first. A raw
  // per-frame view would wake the panel sixty times a second through a pan.
  const camera = new StageCamera();
  const woken = counted(camera);
  camera.publishSettledView({ zoom: 2, center: { x: 10, y: -4 } });
  assertEquals(camera.getReadout().settled, {
    zoom: 2,
    center: { x: 10, y: -4 },
  });
  assertEquals(woken(), 1);
  // Coming to rest in the same place is not news.
  camera.publishSettledView({ zoom: 2, center: { x: 10, y: -4 } });
  assertEquals(woken(), 1, "resting in the same place woke the panel again");
});

Deno.test("a scale published mid-gesture keeps the settled view", () => {
  // The two facts move at different paces and neither may clobber the other. A
  // `publishZoom` that rebuilt the whole readout would drop the settled view back
  // to its default on the first frame of a wheel gesture, so the button would go
  // inert for exactly as long as the reader was moving.
  const camera = new StageCamera();
  camera.publishSettledView({ zoom: 4, center: { x: 1, y: 2 } });
  camera.publishZoom(0.5);
  assertEquals(
    camera.getReadout().settled,
    { zoom: 4, center: { x: 1, y: 2 } },
    "a scale update overwrote where the camera had come to rest",
  );
  assertEquals(camera.getReadout().label, formatStageZoom(0.5));
});

Deno.test("a command with no camera attached is dropped", () => {
  // The controls exist before the viewport does and outlive it on teardown.
  const camera = new StageCamera();
  camera.send({ kind: "fit" });
});

Deno.test("commands reach the attached camera, and stop at detach", () => {
  const camera = new StageCamera();
  const seen: string[] = [];
  const detach = camera.attach({
    run: (c) => seen.push(c.kind),
    view: () => ({ zoom: 1, center: { x: 0, y: 0 } }),
  });
  camera.send({ kind: "zoom-in" });
  camera.send({ kind: "home" });
  assertEquals(seen, ["zoom-in", "home"]);
  detach();
  camera.send({ kind: "fit" });
  assertEquals(seen, ["zoom-in", "home"], "a detached camera still moved");
});

Deno.test("a stale detach cannot unhook the camera that replaced it", () => {
  // A stage that rebuilds attaches the new viewport before React runs the old
  // effect's cleanup, so the cleanups arrive out of order. The late one must be
  // a no-op rather than leaving the live stage with no camera.
  const camera = new StageCamera();
  const seen: string[] = [];
  const view = () => ({ zoom: 1, center: { x: 0, y: 0 } });
  const detachOld = camera.attach({ run: () => seen.push("old"), view });
  camera.attach({ run: () => seen.push("new"), view });
  detachOld();
  camera.send({ kind: "fit" });
  assertEquals(seen, ["new"], "the stale detach unhooked the live camera");
});

Deno.test("the view reads back through the same port", () => {
  // One port rather than a channel per direction, so a consumer cannot attach a
  // camera it can drive but not ask. With nothing attached there is no stage to
  // read, and null says so rather than a default worth saving.
  const camera = new StageCamera();
  assertEquals(camera.readView(), null);
  const detach = camera.attach({
    run: () => {},
    view: () => ({ zoom: 2.5, center: { x: 10, y: -20 } }),
  });
  assertEquals(camera.readView(), { zoom: 2.5, center: { x: 10, y: -20 } });
  detach();
  assertEquals(camera.readView(), null, "a detached camera still answered");
});

Deno.test("a zoom step does not disturb the settled view's identity", () => {
  // What the Opens-at row subscribes to. A subscriber is woken by every change
  // to the readout, and the percentage moves on most frames of a zoom, so a row
  // that took the whole readout re-rendered at the frame rate to show a value
  // that had not changed. `useSyncExternalStore` compares the snapshot it is
  // given, so handing it this reference is what stops the render.
  const camera = new StageCamera();
  const before = camera.getSettledView();
  camera.publishZoom(2);
  camera.publishZoom(3);
  camera.publishZoom(0.5);
  assert(
    camera.getSettledView() === before,
    "a zoom changed the settled snapshot",
  );
  camera.publishSettledView({ zoom: 2, center: { x: 10, y: 20 } });
  assert(
    camera.getSettledView() !== before,
    "coming to rest somewhere new left the snapshot alone",
  );
});

Deno.test("republishing the scale it already holds does no work", () => {
  // Called once per frame whether or not the camera moved, so the still case is
  // the common one: it must not format a percentage and build a readout to
  // discover both match what it holds.
  const camera = new StageCamera();
  camera.publishZoom(2);
  const held = camera.getReadout();
  let woke = 0;
  camera.subscribe(() => woke++);
  camera.publishZoom(2);
  camera.publishZoom(2);
  assertEquals(woke, 0);
  assert(camera.getReadout() === held, "the readout object was rebuilt");
});
